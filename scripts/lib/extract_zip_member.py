#!/usr/bin/env python3
"""extract_zip_member.py: write ONE named member of a zip to a file.

    python3 -I extract_zip_member.py <zip> <member> <dest>

Used for the Xray core zip, which holds the binary next to geo data files we do
not want. Only the exact member name is read (never a path from the archive), so
a crafted archive cannot write anywhere else. Exit 1 if the member is missing,
is not a regular file, or is implausibly large.
"""
import os
import shutil
import sys
import zipfile

MAX_BYTES = 200 * 1024 * 1024


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    archive, member, dest = argv[1:]
    try:
        with zipfile.ZipFile(archive) as z:
            try:
                info = z.getinfo(member)
            except KeyError:
                print(f"extract_zip_member: no member '{member}' in {archive}", file=sys.stderr)
                return 1
            if info.is_dir() or info.file_size > MAX_BYTES:
                print(f"extract_zip_member: '{member}' is not a plausible binary", file=sys.stderr)
                return 1
            fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o755)
            with os.fdopen(fd, "wb") as out, z.open(info) as src:
                shutil.copyfileobj(src, out)
    except (zipfile.BadZipFile, OSError) as e:
        print(f"extract_zip_member: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
