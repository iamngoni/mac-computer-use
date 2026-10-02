# App icon

The icon shows the project's stemless arrowhead with a click ripple on a midnight-navy field. The art was made for this project with an image model, using the cursor's cyan-to-lavender palette.

`AppIcon.icon` is the source, an Icon Composer document with one full-bleed 1024 px layer (`Assets/art.png`). `scripts/generate_app_icon.swift` builds the bundled files from it:

- `Assets.car` is the document compiled by `actool`. macOS 26 and later read it through `CFBundleIconName` and mask and light it like a native icon; a plain `.icns` would sit on a grey platter there.
- `AppIcon.icns` is used through `CFBundleIconFile` on macOS 13–15. It holds the art masked to the classic rounded square on Apple's 1024 pt grid (824 pt body) with the standard drop shadow, at every size from 16 pt to 512 pt @2x.
- `AppIcon-1024.png` is that masked master, kept for documentation and the release page.

`build.sh` copies `Assets.car` and `AppIcon.icns` into `Contents/Resources`. After changing the art or `icon.json`, regenerate them (requires Xcode 26 or later for `actool`):

```bash
swift scripts/generate_app_icon.swift
```
