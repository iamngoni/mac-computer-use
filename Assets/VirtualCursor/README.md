# Virtual cursor assets

The cursor is composed from two independent transparent layers on a 36 x 36 point canvas:

- `cursor-pointer`: static black pointer, rendered above the pulse.
- `cursor-pulse`: cyan-blue hotspot pulse, rendered below the pointer.

Each layer includes 1x, 2x, and 3x PNG exports. The `*-master.png` files are the full-resolution image-generation sources and should not be loaded at runtime.

## Placement

The automation coordinate is the pointer hotspot and the center of the pulse.

- Pulse center: `(18, 18)` points within its 36 x 36 canvas.
- Pointer hotspot: approximately `(12, 7)` points from the pointer image's top-left corner.
- Draw the pulse first, centered on the automation coordinate. Draw the pointer second with its hotspot aligned to the same coordinate.

## Pulse motion

Use a continuous, subtle breathing animation rather than an on/off blink:

- Duration: `1.05s`, autoreversing.
- Timing: ease-in-out.
- Scale: `0.82 -> 1.12`.
- Opacity: `0.52 -> 0.96`.
- The pointer remains static.

For click feedback, compress the pulse to `0.76` over `70ms`, expand it to `1.24` over `160ms`, then return to the breathing animation over `180ms`.
