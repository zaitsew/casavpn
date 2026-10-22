# CasaVPN icon concepts

Three distinct App Store icon concepts for CasaVPN. The current icon
(`app/CasaVPN/Assets.xcassets/AppIcon.appiconset/AppIcon.png`) is untouched: the owner picks first.
No text, no letters, no Apple glyphs, no flags, no landmarks. Each variant is an opaque
1024x1024 PNG without an alpha channel.

| Concept | Source | Render |
|---|---|---|
| Portal Home | `tunnel.svg` | `variants/tunnel.png` |
| Keyhole Home | `keyhome.svg` | `variants/keyhome.png` |
| Orbit Line | `ribbon.svg` | `variants/ribbon.png` |

`contact-sheet.png` shows each concept at 1024, 180, 120, 60 and 40 px, masked like iOS, on a light and a dark background.

## 1. Portal Home (`tunnel.svg`)

A white-lavender house at night whose arched doorway opens into a glowing tunnel in perspective.
Six nested arches shrink toward a vanishing point and brighten from deep indigo to white-hot,
and the light spills out of the door onto the ground. The idea: your home, reachable from anywhere.
Palette: sky `#0B1442` / `#2A1A7A` / `#5B2BB8`; house `#FFFFFF` / `#EEF2FF` / `#9AA9F5`;
tunnel `#120C52`, `#25189A`, `#4A33D8`, `#2F7BF0`, `#25BEF2`, `#5CF0EE`, `#C8FFFF`; ground `#150C45` / `#07041F`.

## 2. Keyhole Home (`keyhome.svg`)

A warm gold, embossed house-shaped plate with a keyhole cut into it. A lit room glows behind the
keyhole, and the plate casts a soft shadow on a sunset background. The house is the lock: your
home, secured, with light on inside. Palette: background `#2E0B4F` / `#6E1760` / `#C23B55` with
an orange glow `#FF9A4A`; gold `#FFF1B8`, `#FFD15A`, `#F2A22C`, `#D07A16`; edge `#B15A0C` / `#6C2C04`;
keyhole `#2B0A3A` with light `#FFFFFF`, `#FFE9A8`, `#FF9A3D`.

## 3. Orbit Line (`ribbon.svg`)

One continuous neon ribbon: it climbs a house outline (walls and roof) and its two ends run into
an elliptical orbit that passes behind the walls, with a white node on the orbit as "you,
somewhere else". Bold and geometric on a deep navy field. Palette: background `#141F4A` / `#05070F`
with a `#3A5CFF` bloom; ribbon gradient `#D4FF4A`, `#2EF0B0`, `#3AA0FF`, `#A06BFF`; node `#FFFFFF`.

## Re-render

No SVG rasterizer is needed: `render.swift` draws each SVG in an offscreen WebKit view and flattens
the snapshot onto an opaque context (no alpha). Run from this directory:

```sh
swiftc -O render.swift -o /tmp/icon-render
/tmp/icon-render tunnel.svg variants/tunnel.png keyhome.svg variants/keyhome.png ribbon.svg variants/ribbon.png
swiftc -O contact-sheet.swift -o /tmp/icon-sheet
/tmp/icon-sheet contact-sheet.png variants/tunnel.png variants/keyhome.png variants/ribbon.png
sips -g hasAlpha -g pixelWidth -g pixelHeight variants/*.png   # expect hasAlpha: no, 1024 x 1024
```

To adopt a concept: copy its PNG over `AppIcon.png` and run `app/generate.sh`.
