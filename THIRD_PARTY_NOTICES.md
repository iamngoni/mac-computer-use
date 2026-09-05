# Third-Party Notices

## Sparkle

Signed release builds bundle Sparkle 2 for secure application updates.

- Project: https://github.com/sparkle-project/Sparkle
- License: MIT and bundled third-party notices

The complete upstream license and its external-component notices are packaged at
`MacComputerUse.app/Contents/Resources/Licenses/Sparkle-LICENSE.txt`.

## Cua Driver

The `sky_click` event recipe and the private SkyLight bridge in `main.swift` are derived
from Cua Driver — specifically the Chromium-compatible click sequence in
`rust/crates/platform-macos/src/input/mouse.rs` and the dynamic-symbol declarations in
`rust/crates/platform-macos/src/input/skylight.rs`.

- Project: https://github.com/trycua/cua
- License: MIT

MIT License

Copyright (c) 2025 Cua AI, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## yabai

The practice of dynamically loading SkyLight and the shape of the window activation
event record were cross-checked against yabai. No yabai code was copied.

- Project: https://github.com/koekeishiya/yabai
- License: MIT

The MIT License (MIT)

Copyright (c) 2019 Åsmund Vikane

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## open-codex-computer-use

The overall approach — a `click_method` selector, screenshot-pixel coordinate space,
bounded screenshot payloads, and the refinement of only ever synthesizing focus for the
*target* app (never defocusing the real frontmost app, which fires AppKit
`resignActive`/`resignKey` and destroys the user's first responder) — was informed by
open-codex-computer-use.

- Project: https://github.com/ifuryst/open-codex-computer-use
- License: MIT
