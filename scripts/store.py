#!/usr/bin/env python3
"""CasaVPN's App Store Connect settings, as code. Dry-run by default.

Every command that can write shows what it would change and writes only with --apply.

    scripts/store.py lint                 # offline: validate app/store/ (no credentials)
    scripts/store.py check                # what is still missing before "Submit for Review"
    scripts/store.py availability         # territories: every one but China mainland
    scripts/store.py listing              # metadata files -> app info and the editable version
    scripts/store.py review               # review notes + contact -> App Review information
    scripts/store.py age-rating           # the age-rating questionnaire, all "none"

Add --apply to availability, listing, review or age-rating to write.

Why CHN is off (POLICY section 15): VPN-related management apps need a licence from
China's regulator and any app there needs an ICP filing, which needs a Chinese entity.
CasaVPN is an admin console, not a VPN client, but we do not ask a reviewer to draw that
line for a storefront we cannot serve. Re-including China is the owner's call. The
setting is app-wide.

Inputs, all under app/store/:
    metadata/en-US/*.txt      name, subtitle, promotional_text, description, keywords,
                              release_notes, support_url, privacy_url, marketing_url
    review_notes.txt          the App Review notes
    contact.local.json        the reviewer contact (untracked; see contact.example.json)

Credentials and REST calls come from ~/ops/bin/testflight (the App Store Connect API key
in ~/.appstoreconnect/); this script never reads the key itself.
"""
import argparse
import importlib.machinery
import importlib.util
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORE = Path(os.environ.get("CASAVPN_STORE_DIR", ROOT / "app" / "store"))
LOCALE = "en-US"

BUNDLE_ID = "com.casavpn.CasaVPN"
EXCLUDED = {"CHN"}  # China mainland: licence and ICP filing (see above)
CATEGORY = "UTILITIES"
# An admin console shows nothing that belongs to somebody else.
CONTENT_RIGHTS = "DOES_NOT_USE_THIRD_PARTY_CONTENT"

# Version states in which the metadata can still be edited.
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
            "INVALID_BINARY", "WAITING_FOR_REVIEW"}

# field -> (file, limit). A limit of 0 means "no limit that matters here".
VERSION_FIELDS = {
    "description": ("description.txt", 4000),
    "keywords": ("keywords.txt", 100),
    "promotionalText": ("promotional_text.txt", 170),
    "supportUrl": ("support_url.txt", 0),
    "marketingUrl": ("marketing_url.txt", 0),
}
INFO_FIELDS = {"name": ("name.txt", 30), "subtitle": ("subtitle.txt", 30),
               "privacyPolicyUrl": ("privacy_url.txt", 0)}
WHATS_NEW = ("release_notes.txt", 4000)
REVIEW_NOTES_LIMIT = 4000

# Model providers stay out of the listing (POLICY section 15).
PROVIDERS = re.compile(r"openai|chatgpt|\bgpt|claude|anthropic|gemini|grok", re.I)
# Third-party project names: out of the name, subtitle and keywords; once at most in the
# description, as compatibility.
THIRD_PARTY = re.compile(r"3x-?ui|xray", re.I)

# The age-rating questionnaire, every answer "none". Enum answers are NONE /
# INFREQUENT_OR_MILD / FREQUENT_OR_INTENSE; the yes/no ones are booleans. The first block
# was verified against the API on 2026-09-08 (Wine Cave). `socialMedia` is newer and its
# type is a guess: a 409 on --apply names the field if it is wrong. Only fields the API
# returns for this app are sent.
AGE_RATING_NONE = {
    "contests": "NONE", "gamblingSimulated": "NONE", "medicalOrTreatmentInformation": "NONE",
    "profanityOrCrudeHumor": "NONE", "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE", "horrorOrFearThemes": "NONE",
    "matureOrSuggestiveThemes": "NONE", "violenceCartoonOrFantasy": "NONE",
    "violenceRealistic": "NONE", "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    "gunsOrOtherWeapons": "NONE", "alcoholTobaccoOrDrugUseOrReferences": "NONE",
    "healthOrWellnessTopics": False, "gambling": False, "unrestrictedWebAccess": False,
    "lootBox": False, "advertising": False, "parentalControls": False, "ageAssurance": False,
    "messagingAndChat": False, "userGeneratedContent": False, "socialMedia": False,
}

# Screenshot display types per required slot. The 6.9" slot accepts either type name: the
# API names the 6.9" family APP_IPHONE_69 on newer accounts and APP_IPHONE_67 on older ones.
# Apple needs one iPhone set: 6.9" (or 6.7"), or 6.5" when there is no 6.9" set.
# It scales that set down for the smaller phones.
SCREENSHOT_SLOTS = {'iPhone 6.9" or 6.5"': ("APP_IPHONE_69", "APP_IPHONE_67", "APP_IPHONE_65")}

CONTACT_KEYS = ("first_name", "last_name", "phone", "email")
# The copyright line names the seller, so it lives in contact.local.json too ("copyright",
# written as shown, for example "2026 Example Company"); it is not committed.


# --- local files ---------------------------------------------------------------------

def read(name: str, sub: str = f"metadata/{LOCALE}") -> str | None:
    path = STORE / sub / name if sub else STORE / name
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8").strip()


def metadata() -> dict[str, str | None]:
    out: dict[str, str | None] = {}
    for table in (INFO_FIELDS, VERSION_FIELDS):
        for field, (file, _) in table.items():
            out[field] = read(file)
    out["whatsNew"] = read(WHATS_NEW[0])
    return out


def lint() -> list[str]:
    """Problems in the local files. Offline; the same rules `check` and `listing` apply."""
    problems: list[str] = []
    md = metadata()
    limits = {f: lim for table in (INFO_FIELDS, VERSION_FIELDS) for f, (_, lim) in table.items()}
    limits["whatsNew"] = WHATS_NEW[1]
    files = {f: file for table in (INFO_FIELDS, VERSION_FIELDS) for f, (file, _) in table.items()}
    files["whatsNew"] = WHATS_NEW[0]
    for field, text in md.items():
        where = f"metadata/{LOCALE}/{files[field]}"
        if not text:
            problems.append(f"{where} is missing or empty")
            continue
        if limits[field] and len(text) > limits[field]:
            problems.append(f"{where}: {len(text)} characters, limit {limits[field]}")
        if PROVIDERS.search(text):
            problems.append(f"{where} names a model provider")
        if field.endswith("Url") and not re.fullmatch(r"https://\S+", text):
            problems.append(f"{where} is not one https URL")
    kw = md.get("keywords") or ""
    if ", " in kw or " ," in kw or kw != kw.lower():
        problems.append("keywords: comma-separated, no spaces around commas, lower case")
    for word in kw.split(","):
        if md.get("name") and word and word in (md["name"] or "").lower().split():
            problems.append(f"keywords: '{word}' repeats the name")
    for field in ("name", "subtitle", "keywords"):
        if THIRD_PARTY.search(md.get(field) or ""):
            problems.append(f"{field} names a third-party project (3x-ui, Xray)")
    desc = md.get("description") or ""
    if len(THIRD_PARTY.findall(desc)) > 1:
        problems.append("description names 3x-ui or Xray more than once (compatibility only, once)")
    if desc and "not a VPN" not in desc:
        problems.append('description must say "not a VPN service"')
    notes = read("review_notes.txt", "")
    if not notes:
        problems.append("review_notes.txt is missing or empty")
    elif len(notes) > REVIEW_NOTES_LIMIT:
        problems.append(f"review_notes.txt: {len(notes)} characters, limit {REVIEW_NOTES_LIMIT}")
    elif "3x-ui" not in notes:
        problems.append("review_notes.txt must explain the 3x-ui naming choice")
    return problems


def contact() -> tuple[dict[str, str] | None, str]:
    """The reviewer contact from the untracked local file. The values are never printed."""
    path = STORE / "contact.local.json"
    if not path.is_file():
        return None, "app/store/contact.local.json is missing (copy contact.example.json)"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as e:
        return None, f"contact.local.json is not valid JSON: {e}"
    missing = [k for k in CONTACT_KEYS if not str(data.get(k, "")).strip()]
    if missing:
        return None, "contact.local.json lacks: " + ", ".join(missing)
    if "example.com" in data["email"] or not data["phone"].startswith("+") \
            or "YOUR" in str(data.get("copyright", "")):
        return None, "contact.local.json still holds the example values (phone needs a +country code)"
    out = {k: str(data[k]).strip() for k in CONTACT_KEYS}
    out["copyright"] = str(data.get("copyright", "")).strip()
    return out, ""


# --- App Store Connect ---------------------------------------------------------------

def testflight():
    path = os.path.expanduser("~/ops/bin/testflight")
    loader = importlib.machinery.SourceFileLoader("testflight", path)
    spec = importlib.util.spec_from_loader("testflight", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class Asc:
    """One app, its editable app info and its editable version, fetched once."""

    def __init__(self) -> None:
        self.tf = testflight()
        self.cfg = self.tf.load_config()
        self.app = self.tf._app_id(self.cfg, BUNDLE_ID)
        self._info: dict | None = None
        self._version: dict | None = None

    def get(self, path: str, soft: tuple[int, ...] = (404,)) -> dict:
        return self.tf.api(self.cfg, path, soft=soft)

    def pages(self, path: str) -> list[dict]:
        return self.tf._all_pages(self.cfg, path)

    def send(self, path: str, method: str, body: dict) -> dict:
        return self.tf.write(self.cfg, path, method=method, body=body)

    @property
    def info(self) -> dict:
        if self._info is None:
            infos = self.pages(f"/v1/apps/{self.app}/appInfos")
            editable = [i for i in infos if i["attributes"].get("appStoreState") in EDITABLE]
            if not editable:
                sys.exit("no editable app info: the app has no version in an editable state")
            self._info = editable[0]
        return self._info

    @property
    def version(self) -> dict:
        if self._version is None:
            versions = self.pages(f"/v1/apps/{self.app}/appStoreVersions?filter[platform]=IOS")
            editable = [v for v in versions if v["attributes"]["appStoreState"] in EDITABLE]
            if not editable:
                sys.exit("no editable iOS version: create one in App Store Connect first")
            self._version = editable[0]
        return self._version

    def is_first_release(self) -> bool:
        versions = self.pages(f"/v1/apps/{self.app}/appStoreVersions?filter[platform]=IOS")
        return all(v["attributes"]["appStoreState"] in EDITABLE for v in versions)

    def info_localization(self) -> dict | None:
        rows = self.pages(f"/v1/appInfos/{self.info['id']}/appInfoLocalizations")
        return next((r for r in rows if r["attributes"]["locale"] == LOCALE), None)

    def version_localization(self) -> dict | None:
        rows = self.pages(
            f"/v1/appStoreVersions/{self.version['id']}/appStoreVersionLocalizations")
        return next((r for r in rows if r["attributes"]["locale"] == LOCALE), None)


def show(value) -> str:
    text = " ".join(str(value).split())
    return text if len(text) <= 60 else text[:57] + "..."


def diff(current: dict, wanted: dict) -> dict:
    """Print one line per field and return the fields that differ."""
    changes = {}
    for field, new in wanted.items():
        old = current.get(field)
        if old == new:
            print(f"  = {field}")
        else:
            changes[field] = new
            print(f"  ~ {field}: {show(old) if old not in (None, '') else '(empty)'}"
                  f"  ->  {show(new)}")
    return changes


# --- commands ------------------------------------------------------------------------

def cmd_lint(_: argparse.Namespace) -> int:
    problems = lint()
    for p in problems:
        print(f"!! {p}")
    md = metadata()
    for field in ("name", "subtitle", "promotionalText", "description", "keywords"):
        text = md.get(field) or ""
        print(f"   {field}: {len(text)} characters")
    print(f"lint: {len(problems)} problem(s)")
    return 1 if problems else 0


def territories(asc: Asc) -> list[str]:
    return sorted(t["id"] for t in asc.pages("/v1/territories?limit=200"))


def current_availability(asc: Asc):
    r = asc.get(f"/v1/apps/{asc.app}/appAvailabilityV2")
    if r.get("error") == 404:
        return None
    rows = asc.pages(f"/v2/appAvailabilities/{r['data']['id']}/territoryAvailabilities"
                     "?include=territory&limit=200")
    return ({row["relationships"]["territory"]["data"]["id"]: row["attributes"]["available"]
             for row in rows},
            {row["relationships"]["territory"]["data"]["id"]: row["id"] for row in rows})


def cmd_availability(asc: Asc, args: argparse.Namespace) -> int:
    state = current_availability(asc)
    if state is None:
        ids = territories(asc)
        print(f"availability: not set yet; would create it with {len(ids) - len(EXCLUDED & set(ids))}"
              f" of {len(ids)} territories on, off: {', '.join(sorted(EXCLUDED))}")
        if not args.apply:
            return 1
        refs = [{"type": "territoryAvailabilities", "id": f"${{{t}}}"} for t in ids]
        included = [{"type": "territoryAvailabilities", "id": f"${{{t}}}",
                     "attributes": {"available": t not in EXCLUDED},
                     "relationships": {"territory": {"data": {"type": "territories", "id": t}}}}
                    for t in ids]
        asc.send("/v2/appAvailabilities", "POST", {
            "data": {"type": "appAvailabilities",
                     "attributes": {"availableInNewTerritories": True},
                     "relationships": {"app": {"data": {"type": "apps", "id": asc.app}},
                                       "territoryAvailabilities": {"data": refs}}},
            "included": included})
        print("availability: created")
        return 0
    available, row_ids = state
    wrong = {t: v for t, v in available.items() if v == (t in EXCLUDED)}
    print(f"availability: {sum(available.values())} of {len(available)} territories on; "
          f"CHN {'on' if available.get('CHN') else 'off'}")
    if not wrong:
        return 0
    print("differs from the rule: " + ", ".join(
        f"{t} {'on' if v else 'off'}" for t, v in sorted(wrong.items())))
    if not args.apply:
        return 1
    for t in sorted(wrong):
        asc.send(f"/v1/territoryAvailabilities/{row_ids[t]}", "PATCH", {
            "data": {"type": "territoryAvailabilities", "id": row_ids[t],
                     "attributes": {"available": t not in EXCLUDED}}})
        print(f"  {t} -> {'on' if t not in EXCLUDED else 'off'}")
    return 0


def cmd_listing(asc: Asc, args: argparse.Namespace) -> int:
    problems = lint()
    if problems:
        for p in problems:
            print(f"!! {p}")
        print("listing: fix the files first")
        return 1
    md = metadata()
    changed = 0

    print("app info (name, subtitle, privacy policy):")
    loc = asc.info_localization()
    wanted = {f: md[f] for f in INFO_FIELDS}
    changes = diff(loc["attributes"] if loc else {}, wanted)
    if changes:
        changed += 1
        if args.apply:
            if loc:
                asc.send(f"/v1/appInfoLocalizations/{loc['id']}", "PATCH", {
                    "data": {"type": "appInfoLocalizations", "id": loc["id"],
                             "attributes": changes}})
            else:
                asc.send("/v1/appInfoLocalizations", "POST", {
                    "data": {"type": "appInfoLocalizations",
                             "attributes": {"locale": LOCALE, **changes},
                             "relationships": {"appInfo": {"data": {
                                 "type": "appInfos", "id": asc.info["id"]}}}}})

    print(f"primary category ({CATEGORY}):")
    cat = asc.get(f"/v1/appInfos/{asc.info['id']}/primaryCategory")
    have = (cat.get("data") or {}).get("id")
    print(f"  {'=' if have == CATEGORY else '~'} primaryCategory: {have or '(empty)'}"
          + ("" if have == CATEGORY else f"  ->  {CATEGORY}"))
    if have != CATEGORY:
        changed += 1
        if args.apply:
            asc.send(f"/v1/appInfos/{asc.info['id']}", "PATCH", {
                "data": {"type": "appInfos", "id": asc.info["id"], "relationships": {
                    "primaryCategory": {"data": {"type": "appCategories", "id": CATEGORY}}}}})

    version = asc.version
    print(f"version {version['attributes']['versionString']} "
          f"({version['attributes']['appStoreState']}), {LOCALE}:")
    loc = asc.version_localization()
    wanted = {f: md[f] for f in VERSION_FIELDS}
    if asc.is_first_release():
        # Apple refuses "What's New" on a first version; release_notes.txt waits for 1.1.
        print("  - whatsNew: skipped, Apple does not take it on a first release")
    else:
        wanted["whatsNew"] = md["whatsNew"]
    changes = diff(loc["attributes"] if loc else {}, wanted)
    if changes:
        changed += 1
        if args.apply:
            if loc:
                asc.send(f"/v1/appStoreVersionLocalizations/{loc['id']}", "PATCH", {
                    "data": {"type": "appStoreVersionLocalizations", "id": loc["id"],
                             "attributes": changes}})
            else:
                asc.send("/v1/appStoreVersionLocalizations", "POST", {
                    "data": {"type": "appStoreVersionLocalizations",
                             "attributes": {"locale": LOCALE, **changes},
                             "relationships": {"appStoreVersion": {"data": {
                                 "type": "appStoreVersions", "id": version["id"]}}}}})

    print("version and app attributes:")
    c, why = contact()
    if c and c["copyright"]:
        changes = diff(version["attributes"], {"copyright": c["copyright"]})
    else:
        changes = {}
        print(f"  - copyright: skipped ({why or 'no copyright in contact.local.json'})")
    if changes:
        changed += 1
        if args.apply:
            asc.send(f"/v1/appStoreVersions/{version['id']}", "PATCH", {
                "data": {"type": "appStoreVersions", "id": version["id"], "attributes": changes}})
    app = asc.get(f"/v1/apps/{asc.app}")["data"]["attributes"]
    changes = diff(app, {"contentRightsDeclaration": CONTENT_RIGHTS})
    if changes:
        changed += 1
        if args.apply:
            asc.send(f"/v1/apps/{asc.app}", "PATCH", {
                "data": {"type": "apps", "id": asc.app, "attributes": changes}})

    print(f"listing: {changed} group(s) {'written' if args.apply else 'would change (dry run)'}")
    return 1 if changed and not args.apply else 0


def review_attributes() -> tuple[dict | None, str]:
    notes = read("review_notes.txt", "")
    c, why = contact()
    if not notes or len(notes) > REVIEW_NOTES_LIMIT:
        return None, "review_notes.txt is missing, empty or over 4000 characters"
    attrs = {"demoAccountRequired": False, "notes": notes}
    if c:
        attrs.update({"contactFirstName": c["first_name"], "contactLastName": c["last_name"],
                      "contactPhone": c["phone"], "contactEmail": c["email"]})
    return attrs, why


def cmd_review(asc: Asc, args: argparse.Namespace) -> int:
    attrs, why = review_attributes()
    if attrs is None:
        print(f"!! {why}")
        return 1
    version = asc.version
    r = asc.get(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail")
    detail = r.get("data")
    print(f"App Review information for version {version['attributes']['versionString']}:")
    # Contact values are personal data: shown as set or unset, never printed.
    shown_current = {k: v for k, v in (detail["attributes"] if detail else {}).items()}
    for field, new in attrs.items():
        old = shown_current.get(field)
        if field.startswith("contact"):
            same = old == new
            print(f"  {'=' if same else '~'} {field}: {'set' if same else 'would be set'}")
        elif old == new:
            print(f"  = {field}")
        else:
            print(f"  ~ {field}: {show(old) if old not in (None, '') else '(empty)'}"
                  f"  ->  {show(new)}")
    if why:
        print(f"!! contact not included: {why}")
    changes = {k: v for k, v in attrs.items() if shown_current.get(k) != v}
    if not changes:
        print("review: up to date")
        return 1 if why else 0
    if not args.apply:
        print("review: dry run")
        return 1 if why else 0
    if why:
        print("review: refusing to write without a contact; Apple requires one")
        return 1
    if detail:
        asc.send(f"/v1/appStoreReviewDetails/{detail['id']}", "PATCH", {
            "data": {"type": "appStoreReviewDetails", "id": detail["id"], "attributes": changes}})
    else:
        asc.send("/v1/appStoreReviewDetails", "POST", {
            "data": {"type": "appStoreReviewDetails", "attributes": changes,
                     "relationships": {"appStoreVersion": {"data": {
                         "type": "appStoreVersions", "id": version["id"]}}}}})
    print("review: written")
    return 0


def cmd_age_rating(asc: Asc, args: argparse.Namespace) -> int:
    decl = asc.get(f"/v1/appInfos/{asc.info['id']}/ageRatingDeclaration")["data"]
    have = decl["attributes"]
    wanted = {k: v for k, v in AGE_RATING_NONE.items() if k in have}
    skipped = sorted(set(AGE_RATING_NONE) - set(wanted))
    print("age rating questionnaire (expected result: 4+):")
    changes = diff(have, wanted)
    if skipped:
        print(f"  - not offered by the API for this app: {', '.join(skipped)}")
    if not changes:
        print("age-rating: up to date")
        return 0
    if not args.apply:
        print(f"age-rating: {len(changes)} answer(s) would change (dry run)")
        return 1
    asc.send(f"/v1/ageRatingDeclarations/{decl['id']}", "PATCH", {
        "data": {"type": "ageRatingDeclarations", "id": decl["id"], "attributes": wanted}})
    info = asc.get(f"/v1/appInfos/{asc.info['id']}")["data"]["attributes"]
    print(f"age-rating: written; App Store rating now {info.get('appStoreAgeRating')}")
    return 0


# --- check ---------------------------------------------------------------------------

class Report:
    def __init__(self) -> None:
        self.missing = 0

    def ok(self, text: str) -> None:
        print(f"  ok   {text}")

    def bad(self, text: str) -> None:
        self.missing += 1
        print(f"  MISS {text}")

    def test(self, cond: bool, good: str, bad: str) -> None:
        (self.ok if cond else self.bad)(good if cond else bad)

    def manual(self, text: str) -> None:
        print(f"  site {text}")


def url_status(url: str) -> str:
    try:
        req = urllib.request.Request(url, method="GET", headers={"User-Agent": "casavpn-store-check"})
        with urllib.request.urlopen(req, timeout=15) as r:
            return str(r.status)
    except urllib.error.HTTPError as e:
        return str(e.code)
    except (urllib.error.URLError, OSError) as e:
        return f"unreachable ({getattr(e, 'reason', e)})"


def local_checks(rep: Report) -> None:
    print("local files:")
    problems = lint()
    rep.test(not problems, "metadata, keywords and review notes pass lint",
             "lint: " + "; ".join(problems))
    c, why = contact()
    rep.test(c is not None, "reviewer contact file is filled in", why)
    plist = (ROOT / "app/CasaVPN/Supporting/Info.plist")
    text = plist.read_text(encoding="utf-8") if plist.is_file() else ""
    rep.test(bool(re.search(r"<key>ITSAppUsesNonExemptEncryption</key>\s*<false/>", text)),
             "Info.plist: ITSAppUsesNonExemptEncryption is NO",
             "Info.plist: ITSAppUsesNonExemptEncryption is not NO")
    proj = (ROOT / "app/project.yml")
    ptext = proj.read_text(encoding="utf-8") if proj.is_file() else ""
    rep.test(bool(re.search(r'^\s*TARGETED_DEVICE_FAMILY:\s*"1"\s*$', ptext, re.M)),
             'project.yml: TARGETED_DEVICE_FAMILY is "1" (iPhone only, no iPad screenshots)',
             'project.yml: TARGETED_DEVICE_FAMILY is not "1"')
    rep.test((ROOT / "app/CasaVPN/Supporting/PrivacyInfo.xcprivacy").is_file(),
             "PrivacyInfo.xcprivacy is present", "PrivacyInfo.xcprivacy is missing")
    m = re.search(r'MARKETING_VERSION:\s*"?([0-9.]+)"?', ptext)
    print(f"       project.yml MARKETING_VERSION: {m.group(1) if m else '?'}")


def remote_checks(asc: Asc, rep: Report) -> None:
    md = metadata()
    print("App Store Connect (read-only):")

    state = current_availability(asc)
    if state is None:
        rep.bad("availability is not set (scripts/store.py availability --apply)")
    else:
        rep.test(state[0].get("CHN") is False and sum(state[0].values()) > 100,
                 "availability: China mainland off, the rest on",
                 "availability: China mainland is on, or too few territories (availability --apply)")

    loc = asc.info_localization()
    attrs = loc["attributes"] if loc else {}
    rep.test(all(attrs.get(f) == md[f] for f in INFO_FIELDS),
             "app info: name, subtitle and privacy policy URL match the files",
             "app info differs from the files (listing --apply)")
    cat = (asc.get(f"/v1/appInfos/{asc.info['id']}/primaryCategory").get("data") or {}).get("id")
    rep.test(cat == CATEGORY, f"primary category is {CATEGORY}", f"primary category is {cat or 'empty'}")

    version = asc.version
    vstr = version["attributes"]["versionString"]
    vloc = asc.version_localization()
    vattrs = vloc["attributes"] if vloc else {}
    rep.test(all(vattrs.get(f) == md[f] for f in VERSION_FIELDS),
             f"version {vstr}: description, keywords, promo text and URLs match the files",
             f"version {vstr} differs from the files (listing --apply)")
    rep.test(bool(version["attributes"].get("copyright")), "copyright is set",
             "copyright is empty (listing --apply)")
    app = asc.get(f"/v1/apps/{asc.app}")["data"]["attributes"]
    rep.test(bool(app.get("contentRightsDeclaration")), "content rights declaration is set",
             "content rights declaration is empty (listing --apply)")

    decl = asc.get(f"/v1/appInfos/{asc.info['id']}/ageRatingDeclaration")["data"]["attributes"]
    unanswered = sorted(k for k in AGE_RATING_NONE if k in decl and decl[k] is None)
    rep.test(not unanswered, "age rating: every question answered",
             f"age rating: {len(unanswered)} question(s) unanswered (age-rating --apply)")

    detail = asc.get(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail").get("data")
    da = detail["attributes"] if detail else {}
    have_contact = all(da.get(k) for k in ("contactFirstName", "contactLastName",
                                           "contactPhone", "contactEmail"))
    rep.test(bool(da.get("notes")) and have_contact,
             "App Review information: notes and contact are set",
             "App Review information: notes or contact missing (review --apply)")

    sets = (asc.pages(f"/v1/appStoreVersionLocalizations/{vloc['id']}/appScreenshotSets")
            if vloc else [])
    by_type = {s["attributes"]["screenshotDisplayType"]: s for s in sets}
    for slot, types in SCREENSHOT_SLOTS.items():
        count = 0
        for t in types:
            if t in by_type:
                count += len(asc.pages(f"/v1/appScreenshotSets/{by_type[t]['id']}/appScreenshots"))
        rep.test(count > 0, f"screenshots: {slot} has {count}",
                 f"screenshots: {slot} has none (upload 1 to 10, portrait)")

    build = asc.get(f"/v1/appStoreVersions/{version['id']}/build").get("data")
    if build:
        rep.test(build["attributes"]["processingState"] == "VALID",
                 f"build {build['attributes']['version']} is attached and processed",
                 f"build {build['attributes']['version']} is attached but not VALID")
    else:
        rep.bad(f"no build is attached to version {vstr} (choose one in App Store Connect)")
    builds = asc.get(f"/v1/builds?filter[app]={asc.app}&include=preReleaseVersion&limit=50")
    built = {x["attributes"]["version"] for x in builds.get("included", [])
             if x["type"] == "preReleaseVersions"}
    rep.test(vstr in built, f"a build exists for version {vstr}",
             f"no uploaded build is for version {vstr} (builds are for: "
             f"{', '.join(sorted(built)) or 'none'}); set MARKETING_VERSION to {vstr}")

    sched = asc.get(f"/v1/apps/{asc.app}/appPriceSchedule").get("data")
    prices = (asc.get(f"/v1/appPriceSchedules/{sched['id']}/manualPrices").get("data")
              if sched else None)
    rep.test(bool(prices), "price schedule is set",
             "price schedule is not set (website: Pricing and Availability, choose Free)")

    for field in ("supportUrl", "privacyPolicyUrl"):
        url = md[field]
        status = url_status(url) if url else "no URL"
        rep.test(status == "200", f"{field} answers 200",
                 f"{field} answers {status} (GitHub Pages: branch main, folder /docs)")


def cmd_check(asc: Asc, _: argparse.Namespace) -> int:
    rep = Report()
    local_checks(rep)
    remote_checks(asc, rep)
    print("only the website can do (the API has no endpoint):")
    rep.manual("App Privacy: choose 'Data Not Collected' and publish (see app/store/APP-PRIVACY.md)")
    rep.manual("Digital Services Act trader status for the EU storefronts (name, address, phone, e-mail)")
    rep.manual("Paid Apps / free-app agreements active; tax and banking only if the app is paid")
    rep.manual("'Add for Review' / 'Submit for Review' and the release choice (after approval)")
    print(f"check: {rep.missing} item(s) missing")
    return 1 if rep.missing else 0


COMMANDS = {"availability": cmd_availability, "listing": cmd_listing, "review": cmd_review,
            "age-rating": cmd_age_rating, "check": cmd_check}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("lint", help="validate app/store/ offline")
    sub.add_parser("check", help="what is missing before submit (read-only)")
    for name, text in (("availability", "territories: all but China mainland"),
                       ("listing", "push the metadata files"),
                       ("review", "push the review notes and contact"),
                       ("age-rating", "answer the age-rating questionnaire")):
        s = sub.add_parser(name, help=text)
        s.add_argument("--apply", action="store_true", help="write; the default is a dry run")
    args = p.parse_args()

    if args.command == "lint":
        sys.exit(cmd_lint(args))
    sys.exit(COMMANDS[args.command](Asc(), args))


if __name__ == "__main__":
    main()
