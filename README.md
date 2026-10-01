# mac-computer-use

A native macOS computer-use server for AI agents, exposed over the [Model Context Protocol (MCP)](https://modelcontextprotocol.io). It lets an MCP client inspect and control macOS apps through Accessibility, Core Graphics, ScreenCaptureKit, and targeted WindowServer events.

It is a native Swift app with no Python, Node, or runtime package-manager dependency. Signed releases bundle the Sparkle updater inside the app.

You grant Accessibility and Screen Recording to **Mac Computer Use once**. Clients such as Claude Code and Codex reach the Mac through it, so they never need those permissions themselves; Mac Computer Use asks you once per client app instead. Agents can also communicate with you through the cursor: point at things, draw on screen, ask a question, let you point back, and hand a step to you.

> Built as an open alternative to proprietary, login-gated computer-use engines. It has no auth wall and fails closed when app, window, or snapshot identity is missing.

## Features

- **Background-capable control.** Clicks prefer the Accessibility `AXPress` action. Coordinate clicks, scrolling, and dragging target a validated app and window without moving the hardware pointer.
- **Background clicks for web content.** Chromium, Electron, and Catalyst web views can ignore ordinary process-posted events. `click_method: "sky_click"` uses a fail-closed SkyLight path against the exact snapshot window without activating the app.
- **Permissions belong to Mac Computer Use.** `mac-computer-use mcp` is a thin relay. Every tool runs in a worker that the LaunchServices-launched app spawns, so macOS attributes Accessibility and Screen Recording to MacComputerUse.app, not to the client. `health_report` shows which app permissions are attributed to.
- **Client approval.** The first time a client app acts, Mac Computer Use asks whether to allow it, identifying the app by its code signature. Allowed apps are listed, and removable, in Setup.
- **Automation cursor that communicates.** A compact rounded arrowhead (original art from `scripts/generate_cursor_assets.swift`) flies along an eased arc to each target and lands before the action happens. Small badges show typing, key presses, scrolling or dragging; a failed action shakes it; several agents get their own glow colour and name tag. It never moves the hardware pointer, fades out after 8 idle seconds, disappears when its client disconnects, and is removed with every other overlay when the app quits. Reduce Motion is respected.
- **Show, ask and hand off.** `point_at`, `annotate`, `ask_user`, `pick_element`, `wait_for_user` and `guide` let an agent explain with the cursor, draw hand-drawn marks and captions, ask a question only your physical click can answer, let you point back at the thing you mean, hand you a password or 2FA step, and walk you through a task.
- **Human brakes.** Esc pauses every agent until you resume from the menu bar, and interrupted actions return `[user_interrupted]` errors. Pressing something like Send, Delete or Buy first shows a 2-second countdown ring you can stop. Agents wait while you are actively using the same app.
- **Agent preview.** When an agent works in a window you cannot see, a small live preview with its cursor floats in a corner.
- **Guided tours.** `guide` can save an element-based tour that you replay later from the menu bar, without an agent.
- **One menu-bar manager.** One status item lists active apps and connected clients, and offers Pause/Resume Agents, Show Agent Preview, Guided Tours, Setup, updates and Quit. Quitting turns automation off until you open the app again.
- **Native setup.** Opening the app shows permission status, one-click registration for Codex and Claude Code, copyable fallback commands, and a launch-at-login switch.
- **Safe automatic updates.** Signed releases check and download through Sparkle. Installation waits until no tool call is in flight, then restarts the service; relays reconnect to the new version on their next call.
- **Exact window identity.** `list_windows` returns WindowServer IDs. Exact window operations use `_AXUIElementGetWindow` when available and reject ambiguous fallback matches.
- **Works across macOS apps.** Targets browsers, Music, Notes, Finder, Mail, and other native apps without requiring them to be frontmost.
- **Accessibility-tree perception.** `get_app_state` returns a compact, indexed tree of the interactive elements in an app's window, plus a screenshot. Element indices are stable and used by the action tools, and are scoped to the app that produced them.
- **One interaction coordinate space.** Tree coordinates and `x,y` accepted by `click` and `drag` use screenshot pixels. Window geometry is the explicit exception: `list_windows` reports and `set_window_frame` accepts global screen points.
- **Bounded screenshots.** Captures go through ScreenCaptureKit as in-memory images and are rescaled to fit a size budget, so a Retina window doesn't dump multiple megabytes of base64 into the model's context.
- **Reliable browser navigation.** `navigate` sets a Safari or Chromium tab URL through AppleScript without omnibox typing.
- **Visible, cancellable control.** The service draws every cursor, the action banner and click feedback. Overlay windows are excluded from agent screenshots, and pointing or drawing fails closed when the target window is covered.
- **Explicit desktop control.** `get_desktop_state` captures a selected display on macOS 14+, returns a snapshot token, and indexes visible menu/status elements with their owning process IDs. `desktop_click` and `desktop_press_key` require `allow_global_input: true`, validate that token, and serialize global HID input so unrelated MCP sessions cannot race the hardware pointer.

## Tools

| Tool | What it does |
|------|--------------|
| `list_apps` | List running applications (name, bundle id, pid). |
| `list_windows` | List stable WindowServer IDs, process IDs, titles, bounds, and front-to-back order. |
| `get_app_state` | Inspect an app without activation. Returns an exact-window screenshot and indexed accessibility tree. Accepts `window_id`. Call it before interacting. |
| `get_desktop_state` | Capture the main display (or an active `display_id`) on macOS 14+, returning a screenshot, snapshot token, and indexed visible menu/status elements with owner PIDs. |
| `desktop_click` | Explicit global desktop click by a fresh `snapshot_id` and screenshot-pixel `x,y`, or by an indexed menu/status element. Requires `allow_global_input: true`; rejects stale tokens and mixed/out-of-bounds targets. |
| `desktop_press_key` | Explicit global HID key/combo press against a fresh desktop snapshot. Requires `allow_global_input: true`. |
| `click` | Click by `element_index` (prefers background `AXPress`) or by `x,y` in screenshot pixels. Supports `click_count`, `mouse_button`, and `click_method` (see below). |
| `type_text` | Type text with keycodes for the current keyboard layout (Unicode injection for characters the layout cannot produce); can focus a target `element_index` first. |
| `press_key` | Press a key/combo, xdotool-style: `Return`, `Tab`, `cmd+c`, `cmd++`, `F13`, `Up`, … Characters follow the current keyboard layout and fail closed if it cannot produce them. |
| `scroll` | Scroll a validated snapshot window, optionally over an element, without moving the hardware pointer. |
| `set_value` | Set the `AXValue` of a settable element (e.g. a text field) directly. |
| `drag` | Drag between two screenshot-pixel points in a validated window without moving the hardware pointer. |
| `perform_secondary_action` | Invoke a named accessibility action on an element. |
| `select_text` | Select text (or place the caret) inside a text element through Accessibility, disambiguated with `prefix`, `suffix` or `occurrence`. Never presses the element; refuses secure fields. |
| `open_app` | Launch an app that isn't running, or bring one forward. Not needed to interact with a running app; `background: true` launches without activating. |
| `navigate` | Point a browser's active tab at a URL (Safari / Chromium). `new_tab` optional. |
| `verify_state` | Poll for an accessibility title or label to exist or disappear, with a bounded timeout. |
| `set_window_frame` | Move and resize an exact WindowServer window, then verify its resulting bounds. |
| `invoke_menu` | Invoke an application menu path by accessibility title. Missing path segments fail closed. |
| `point_at` | Fly the cursor to an element or `x,y` and show a label bubble. Nothing is clicked. |
| `annotate` | Draw rectangles, ellipses, arrows, paths, pill labels and a caption over an app, pinned to elements. Cleared after `duration_ms` or when the window moves. |
| `clear_annotations` | Remove everything `annotate` drew. |
| `ask_user` | Ask a question with 2 to 4 answer chips beside the cursor; only the user's physical click answers. |
| `pick_element` | Capture the user's click(s) and return the app, element and, when it is in the last snapshot, its `element_index`. |
| `wait_for_user` | Hand a step to the user (password, 2FA, permission dialog) and wait for a click or value change. Secure fields are watched by length only. |
| `guide` | Walk the user through steps that advance when they click each element. `save_as` keeps the tour for replay from the menu bar. |
| `health_report` | Return JSON diagnostics for permissions (and which app they are attributed to), process and service session, overlay, input policy, and app/window discovery. |

### Click methods

`click` takes a `click_method`, because no single mechanism works everywhere:

| Method | How it lands | Use when |
|--------|--------------|----------|
| `auto` *(default)* | `AXPress` if the element exposes it, else a process-posted event | Native controls |
| `accessibility` | `AXPress` only, errors if unavailable | You want a guaranteed no-coordinate, no-pointer press |
| `app_post` | Public `CGEvent.postToPid` at coordinates | Native apps that accept process-posted pointer events |
| `sky_click` | Private SkyLight path, left button, one or two clicks | Background Chromium, Electron, and Catalyst web content |

`sky_click` is not reachable from `auto`. It uses an undocumented application binary interface (ABI), so it returns an explicit error instead of falling back to a focus-stealing path. The server does not expose a system Human Interface Device (HID) pointer mode.

Desktop control is the deliberate exception: it is opt-in per call with `allow_global_input: true`, requires a fresh `get_desktop_state` token, and uses the global HID event tap. Indexed menu/status clicks try the recorded element's `AXPress` action first, then use the validated display coordinate if AXPress is unavailable. Synthetic desktop Escape events are tagged so they do not trigger the overlay's physical-Esc cancellation monitor.

## Coordinates

`get_app_state` reports the screenshot's pixel size. Every tree coordinate and every `x,y` accepted by `click` and `drag` uses that screenshot-pixel space. `click`, `scroll`, and `drag` reject calls without a matching, current snapshot. Window-management coordinates are separate: `list_windows` reports global screen-point bounds and `set_window_frame` accepts global screen-point `x,y,width,height`.

`get_desktop_state` reports a display screenshot's pixel size and a fresh `snapshot_id`. Desktop `x,y` values are pixels relative to that display, not global screen points. `desktop_click` rejects an old token, an inactive/moved display, coordinates outside the captured display, or a request that supplies both an element index and coordinates.

## Architecture

Mac Computer Use works like Codex's computer use: one app owns the permissions and the overlay, and MCP clients reach it through a small relay.

```
MCP client ── stdio ── relay (mac-computer-use mcp)
                          │  private per-user Unix socket
                          ▼
        MacComputerUse.app service ── menu bar, Setup, Sparkle, client approval,
              │                       every overlay (cursor, banner, bubbles,
              │                       annotations, agent preview, tours)
              └── one worker per client session (mac-computer-use worker)
                    runs the tools; macOS attributes its permissions to the app
```

- The relay starts the service through LaunchServices when needed and forwards JSON-RPC lines. If the service restarts (for example after an update), the relay reconnects and replays the client's handshake. After the user quits the app, the relay answers `[stopped_by_user]` instead of relaunching it.
- The service accepts only same-user connections, identifies the client app from the relay's responsible process and code signature, and asks the user once per app. Relays only talk to a service with the same code identity.
- Each worker is a child of the service, so a crash affects one session. Workers exit as soon as their client or the service goes away.
- Workers send cursor and banner state over a control channel; the service renders it. There is no file polling, and the overlay timer stops when nothing is visible.
- Coordination files and the socket live in the Darwin per-user temporary directory from `confstr`, so a client that overrides `$TMPDIR` cannot split relays from the service.
- `mac-computer-use mcp --in-process` (or an unbundled development build) runs the tools in the client's process with the older per-process overlay agent; tests and development use it.

## Install

Download the notarized DMG from [GitHub Releases](https://github.com/iamngoni/mac-computer-use/releases), drag `MacComputerUse.app` to Applications, and open it once. The setup window guides the remaining steps:

1. Grant Accessibility and Screen Recording access.
2. Connect Codex and/or Claude Code. Existing registrations are shown and are replaced only after an explicit click.
3. Optionally enable launch at login.

After setup, the app lives in the menu bar. Opening it again returns to setup. Each release also includes a ready-to-publish Homebrew cask; see [the release guide](docs/RELEASING.md).

## Build

Requires the Swift toolchain (Xcode or Command Line Tools).

```bash
./build.sh
```

This builds the Swift package's release executable, embeds Sparkle and the cursor assets in `MacComputerUse.app`,
and ad-hoc code-signs the bundle with the stable identifier
`com.modestnerd.mac-computer-use` so macOS permission grants survive in-place rebuilds.
Local builds use the hardened runtime like releases do, so `DYLD_*` injection is ignored; only library
validation is relaxed, because ad-hoc code has no Team ID to match the bundled Sparkle framework.
The version comes from `VERSION`; the executable and `Info.plist` both target macOS 13 or later. Local builds intentionally omit the Sparkle feed and public key, so they never contact the release channel.

## Test

Run the permission-free Swift and MCP contract tests, then the permissioned live
app-resolution regression. The contract suite also starts an isolated service (a
private `MACCU_RUNTIME_DIR` with test auto-approval) to cover the relay, workers,
reconnection and quit behaviour:

```bash
swift test
python3 -m unittest tests.test_mcp_contract -v
python3 tests/test_live_app_resolution.py -v
```

The integration suite covers process replacement, exact window identity, menu invocation, state polling, window mutation, isolated overlay IPC, and pointer-independent click, scroll, and drag delivery.

## Configuration

| Variable | Effect |
|----------|--------|
| `MACCU_CURSOR_PACE` | `off`, `natural` (default) or `showcase`: how long the cursor takes to fly before actions. |
| `MACCU_RISKY_CONFIRM_MS` | Countdown before pressing Send, Delete, Buy and similar. Default `2000`; `0` disables it. |
| `MACCU_CAPTURE_OVERLAY` | `1` makes overlays visible to screen recordings (they are hidden from captures by default). |
| `MACCU_IN_PROCESS` | `1` runs tools in the client's process instead of through the service (development). |
| `MACCU_RUNTIME_DIR` | Isolated runtime directory for tests; with `MACCU_TEST_AUTO_APPROVE=1` the isolated service skips the approval prompt. |

## GitHub Actions

Both workflows use self-hosted macOS runners only:

- `Compile and package` targets `[self-hosted, macOS, ARM64]` and runs for trusted same-repository pull requests, pushes to `master`, and manual dispatches. It remains queued until a matching runner is registered.
- `GUI integration` is manual and targets
  `[self-hosted, macOS, ARM64, maccu-tcc]`. Register that label only on a logged-in
  runner where the fixed-path app has Accessibility and Screen Recording permissions.
- `Signed release` runs only for a version-matching tag (or an existing tag selected manually). It builds a universal app, signs with Developer ID, notarizes and staples the app and DMG, signs the Sparkle archive/appcast, and publishes the DMG, ZIP, appcast, and Homebrew cask.

Fork pull-request code does not run on the self-hosted runner. Neither workflow has write permissions or receives repository credentials from checkout. Do not add a GitHub-hosted fallback when no runner is registered.

## Permissions

Grant these to **MacComputerUse.app** in *System Settings → Privacy & Security*. Clients do not need them; Mac Computer Use asks you once before each client app may act:

- **Accessibility**: read the user interface tree and synthesize app-scoped input
- **Screen Recording**: capture window screenshots through ScreenCaptureKit on macOS 14 or later, with a `screencapture` fallback on older systems; desktop capture requires macOS 14 or later
- **Input Monitoring / Accessibility**: desktop control posts only after the caller explicitly supplies `allow_global_input: true`; macOS may require the app's Accessibility/Input Monitoring permission for global HID delivery
- **Automation**: script Safari or Chromium for `navigate`; macOS grants this permission per target app

Grant Accessibility and Screen Recording to the fixed installed bundle path before running GUI integration. The `maccu-tcc` runner label belongs only on a logged-in runner with those Transparency, Consent, and Control (TCC) grants.

## Use with Claude Code

The setup window can register the installed executable. The equivalent manual command is:

```bash
claude mcp add --scope user mac-computer-use -- \
  "/Applications/MacComputerUse.app/Contents/MacOS/mac-computer-use" mcp
```

Restart Claude Code; the tools attach as `mcp__mac-computer-use__*`.

For Codex:

```bash
codex mcp add mac-computer-use -- \
  "/Applications/MacComputerUse.app/Contents/MacOS/mac-computer-use" mcp
```

> Note: macOS reserves the server name `computer-use` for the built-in engine, so register this under a distinct name (e.g. `mac-computer-use`).

### Typical flow

```
get_app_state(app: "Google Chrome")                 # see the page + indexed tree
click(app: "Google Chrome", element_index: 42)      # AXPress, background
navigate(app: "Google Chrome", url: "example.com")  # set the URL directly
point_at(app: "Mail", element_index: 12, label: "Your draft is here")   # show, don't touch
ask_user(question: "Send it now?", options: ["Send", "Not yet"])       # only the user answers
wait_for_user(app: "Safari", element_index: 5, instruction: "Enter your 2FA code")
```

## Layout

```
Package.swift                       # Swift package definition
Sources/MacComputerUse/             # executable dispatcher, manager, setup, and updater
Sources/MacComputerUseCore/         # MCP, AX, capture, input, overlay, and tool modules
SwiftTests/MacComputerUseCoreTests/ # permission-free Swift contract tests
tests/test_mcp_contract.py          # permission-free executable protocol test
tests/test_live_app_resolution.py   # permissioned app lifecycle regression
.github/workflows/                  # compile, GUI, and signed-release workflows
Packaging/Casks/                    # rendered into each release's Homebrew cask
scripts/package_release.sh          # notarize and assemble release artifacts
build.sh                            # embed dependencies and sign MacComputerUse.app
VERSION                             # single source of app/release version
THIRD_PARTY_NOTICES.md              # attribution for the SkyLight click recipe
README.md
```

## License

MIT licensed. The `sky_click` event recipe is derived from the MIT-licensed Cua
Driver; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
