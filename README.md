# mac-computer-use

A native macOS computer-use server for AI agents, exposed over the [Model Context Protocol (MCP)](https://modelcontextprotocol.io). It lets an MCP client inspect and control macOS apps through Accessibility, Core Graphics, ScreenCaptureKit, and targeted WindowServer events.

It is a single, self-contained Swift binary packaged as a signed `.app` bundle. No Python, no Node, no external dependencies.

> Built as an open alternative to proprietary, login-gated computer-use engines. It has no auth wall and fails closed when app, window, or snapshot identity is missing.

## Features

- **Background-capable control.** Clicks prefer the Accessibility `AXPress` action. Coordinate clicks, scrolling, and dragging target a validated app and window without moving the hardware pointer.
- **Background clicks for web content.** Chromium, Electron, and Catalyst web views can ignore ordinary process-posted events. `click_method: "sky_click"` uses a fail-closed SkyLight path against the exact snapshot window without activating the app.
- **Persistent automation cursor.** The overlay loads the supplied scale-aware pointer and cyan pulse layers from `Assets/VirtualCursor`, aligns their documented hotspot to explicit automation coordinates, and animates the pulse for breathing and click feedback. A small, non-activating, input-transparent panel remains at the last automation coordinate for the MCP session without reading or moving the hardware pointer. Runtime bundles include only the 1×/2×/3× exports, not the master generation files.
- **Visible menu-bar status.** While the overlay session is active, a compact macOS status item shows the supplied cursor artwork, a blue activity dot, and the current app's icon. Its accessible label and menu name the current or last controlled app, and the menu lists every app controlled during that MCP session.
- **Exact window identity.** `list_windows` returns WindowServer IDs. Exact window operations use `_AXUIElementGetWindow` when available and reject ambiguous fallback matches.
- **Works across macOS apps.** Targets browsers, Music, Notes, Finder, Mail, and other native apps without requiring them to be frontmost.
- **Accessibility-tree perception.** `get_app_state` returns a compact, indexed tree of the interactive elements in an app's window, plus a screenshot. Element indices are stable and used by the action tools, and are scoped to the app that produced them.
- **One interaction coordinate space.** Tree coordinates and `x,y` accepted by `click` and `drag` use screenshot pixels. Window geometry is the explicit exception: `list_windows` reports and `set_window_frame` accepts global screen points.
- **Bounded screenshots.** Captures go through ScreenCaptureKit as in-memory images and are rescaled to fit a size budget, so a Retina window doesn't dump multiple megabytes of base64 into the model's context.
- **Reliable browser navigation.** `navigate` sets a Safari or Chromium tab URL through AppleScript without omnibox typing.
- **Visible, cancellable control.** A separate agent process draws the persistent automation cursor, transient action banner, target highlights, click flashes, and an Esc-to-cancel affordance. The overlay does not appear in captures.

## Tools

| Tool | What it does |
|------|--------------|
| `list_apps` | List running applications (name, bundle id, pid). |
| `list_windows` | List stable WindowServer IDs, process IDs, titles, bounds, and front-to-back order. |
| `get_app_state` | Inspect an app without activation. Returns an exact-window screenshot and indexed accessibility tree. Accepts `window_id`. Call it before interacting. |
| `click` | Click by `element_index` (prefers background `AXPress`) or by `x,y` in screenshot pixels. Supports `click_count`, `mouse_button`, and `click_method` (see below). |
| `type_text` | Type text. Uses real keycodes (accepted by fields that ignore unicode injection); can focus a target `element_index` first. |
| `press_key` | Press a key/combo, xdotool-style: `Return`, `Tab`, `cmd+c`, `cmd+t`, `Up`, … |
| `scroll` | Scroll a validated snapshot window, optionally over an element, without moving the hardware pointer. |
| `set_value` | Set the `AXValue` of a settable element (e.g. a text field) directly. |
| `drag` | Drag between two screenshot-pixel points in a validated window without moving the hardware pointer. |
| `perform_secondary_action` | Invoke a named accessibility action on an element. |
| `select_text` | Focus a text element. |
| `open_app` | Launch an app (or activate it if already running). Works for any macOS app. |
| `navigate` | Point a browser's active tab at a URL (Safari / Chromium). `new_tab` optional. |
| `verify_state` | Poll for an accessibility title or label to exist or disappear, with a bounded timeout. |
| `set_window_frame` | Move and resize an exact WindowServer window, then verify its resulting bounds. |
| `invoke_menu` | Invoke an application menu path by accessibility title. Missing path segments fail closed. |
| `health_report` | Return JSON diagnostics for permissions, process identity, overlay IPC, input policy, and app/window discovery. |

### Click methods

`click` takes a `click_method`, because no single mechanism works everywhere:

| Method | How it lands | Use when |
|--------|--------------|----------|
| `auto` *(default)* | `AXPress` if the element exposes it, else a process-posted event | Native controls |
| `accessibility` | `AXPress` only, errors if unavailable | You want a guaranteed no-coordinate, no-pointer press |
| `app_post` | Public `CGEvent.postToPid` at coordinates | Native apps that accept process-posted pointer events |
| `sky_click` | Private SkyLight path, left button, one or two clicks | Background Chromium, Electron, and Catalyst web content |

`sky_click` is not reachable from `auto`. It uses an undocumented application binary interface (ABI), so it returns an explicit error instead of falling back to a focus-stealing path. The server does not expose a system Human Interface Device (HID) pointer mode.

## Coordinates

`get_app_state` reports the screenshot's pixel size. Every tree coordinate and every `x,y` accepted by `click` and `drag` uses that screenshot-pixel space. `click`, `scroll`, and `drag` reject calls without a matching, current snapshot. Window-management coordinates are separate: `list_windows` reports global screen-point bounds and `set_window_frame` accepts global screen-point `x,y,width,height`.

## Architecture

A bare stdio subprocess on macOS **cannot host AppKit** (`NSApplication.run()` blocks without LaunchServices registration), so the overlay can't live in the MCP process. The design mirrors the proven client/service split:

```
MCP client
        │  stdio JSON-RPC
        ▼
mac-computer-use (MCP process)         ── pure CLI: AX + CGEvent + screencapture
        │  launches via `open` (LaunchServices)
        ▼
mac-computer-use overlay (agent)       ── real NSApplication run loop, draws the overlay
        ▲   │
        └───┘  randomized per-server IPC directory with state.json, ready.json, and cancel
```

- The MCP process never foregrounds apps unless you call `open_app`.
- The overlay agent launches on the first control action. Its cursor and menu-bar status remain visible for that MCP session, and it exits when the owning MCP process exits.
- Each MCP process owns an isolated IPC directory, so concurrent clients cannot overwrite or delete each other's overlay state.

## Build

Requires the Swift toolchain (Xcode or Command Line Tools).

```bash
./build.sh
```

This builds the Swift package's release executable, installs it in `MacComputerUse.app`,
and ad-hoc code-signs the bundle with the stable identifier
`com.modestnerd.mac-computer-use` so macOS permission grants survive in-place rebuilds.
The bundle reports version `0.6.0`. The executable and `Info.plist` both target macOS 13 or later.

## Test

Run the permission-free Swift and MCP contract tests, then the permissioned live
app-resolution regression:

```bash
swift test
python3 -m unittest tests.test_mcp_contract -v
python3 tests/test_live_app_resolution.py -v
```

The integration suite covers process replacement, exact window identity, menu invocation, state polling, window mutation, isolated overlay IPC, and pointer-independent click, scroll, and drag delivery.

## GitHub Actions

Both workflows use self-hosted macOS runners only:

- `Compile and package` targets `[self-hosted, macOS, ARM64]` and runs for trusted same-repository pull requests, pushes to `master`, and manual dispatches. It remains queued until a matching runner is registered.
- `GUI integration` is manual and targets
  `[self-hosted, macOS, ARM64, maccu-tcc]`. Register that label only on a logged-in
  runner where the fixed-path app has Accessibility and Screen Recording permissions.

Fork pull-request code does not run on the self-hosted runner. Neither workflow has write permissions or receives repository credentials from checkout. Do not add a GitHub-hosted fallback when no runner is registered.

## Permissions

Grant these to **MacComputerUse.app** in *System Settings → Privacy & Security*:

- **Accessibility**: read the user interface tree and synthesize app-scoped input
- **Screen Recording**: capture window screenshots through ScreenCaptureKit on macOS 14 or later, with a `screencapture` fallback on older systems
- **Automation**: script Safari or Chromium for `navigate`; macOS grants this permission per target app

Grant Accessibility and Screen Recording to the fixed installed bundle path before running GUI integration. The `maccu-tcc` runner label belongs only on a logged-in runner with those Transparency, Consent, and Control (TCC) grants.

## Use with Claude Code

Register the bundle's executable as an MCP server:

```bash
claude mcp add mac-computer-use --scope user -- \
  "$HOME/.local/share/mac-computer-use/MacComputerUse.app/Contents/MacOS/mac-computer-use"
```

Restart Claude Code; the tools attach as `mcp__mac-computer-use__*`.

> Note: macOS reserves the server name `computer-use` for the built-in engine, so register this under a distinct name (e.g. `mac-computer-use`).

### Typical flow

```
get_app_state(app: "Google Chrome")          # see the page + indexed tree
click(app: "Google Chrome", element_index: 42)  # AXPress, background
navigate(app: "Google Chrome", url: "example.com")  # set the URL directly
open_app(app: "Music"); click(app: "Music", element_index: 7)  # play
```

## Layout

```
Package.swift                       # Swift package definition
Sources/MacComputerUse/             # three-line executable entry point
Sources/MacComputerUseCore/         # MCP, AX, capture, input, overlay, and tool modules
SwiftTests/MacComputerUseCoreTests/ # permission-free Swift contract tests
tests/test_mcp_contract.py          # permission-free executable protocol test
tests/test_live_app_resolution.py   # permissioned app lifecycle regression
.github/workflows/                  # self-hosted compile and GUI workflows
build.sh                            # package + sign into MacComputerUse.app
THIRD_PARTY_NOTICES.md              # attribution for the SkyLight click recipe
README.md
```

## License

MIT licensed. The `sky_click` event recipe is derived from the MIT-licensed Cua
Driver; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
