# Virtual cursor assets

The automation cursor is a compact, rounded, stemless arrowhead with a cyan-to-lavender gradient, a thin white border and a faint baked shadow, on a transparent 28 x 28 point canvas. The visible arrow is roughly 18 x 17 points, close to the size of the system pointer.

`cursor-pointer.png`, `cursor-pointer@2x.png`, and `cursor-pointer@3x.png` are 28, 56, and 84 pixel exports. `cursor-pointer-master.png` is a 1120 pixel render of the same art; it is not bundled at runtime.

The art is original, drawn as vector geometry by `scripts/generate_cursor_assets.swift`. Regenerate every export with:

```bash
swift scripts/generate_cursor_assets.swift
```

The pointer hotspot is approximately `(6.75, 6.5)` points from the top-left of the canvas (the script prints the exact value). It aligns with the automation coordinate. Keep `AutomationCursorAssets.canvasSize` and `pointerHotspot` in `Sources/MacComputerUseCore/Overlay.swift` in sync with the script.

The renderer adds a white silhouette glow with a 2 point base blur. Its opacity breathes from 0.52 to 0.96; the radius compresses and rebounds on clicks. The pointer remains static, preserving its hotspot. The `cursor-pulse` exports are a plain soft glow retained for asset-loader compatibility and are no longer drawn; `cursor-pulse-master.png` is a leftover from the previous artwork.
