# Virtual cursor assets

Version 0.8.0 uses an imagegen-authored compact cyan-to-violet pointer with a short rounded stem and white border on a transparent 36 x 36 point canvas.

`cursor-pointer.png`, `cursor-pointer@2x.png`, and `cursor-pointer@3x.png` are 36, 72, and 108 pixel exports. `cursor-pointer-master.png` is the generated source; it is not bundled at runtime.

The pointer hotspot is approximately `(8, 7.5)` points from the top-left of the canvas. It aligns with the automation coordinate.

The renderer adds a white silhouette glow with a 2.5 point base blur. Its opacity breathes from 0.52 to 0.96; the radius compresses and rebounds on clicks. The pointer remains static, preserving its hotspot. The old cyan pulse assets are retained for asset-loader compatibility but no longer drawn.

Generated with the built-in imagegen tool from the approved concept. Prompt: Extract the exact approved compact cursor into one transparent production asset; preserve the short broad arrowhead, tiny rounded stem, cyan-blue-violet gradient and crisp white border, with transparent padding and no presentation board or text. Scale exports use sips.
