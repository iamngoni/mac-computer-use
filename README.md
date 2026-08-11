# mac-computer-use

A native macOS **computer-use** server for AI agents, exposed over the [Model Context Protocol (MCP)](https://modelcontextprotocol.io). It lets an MCP client (e.g. Claude Code) **see and control any macOS app** through the Accessibility API and CoreGraphics — clicking, typing, scrolling, reading the on-screen UI tree, and taking screenshots — with a live "agent is controlling your Mac" overlay.

It is a single, self-contained Swift binary packaged as a signed `.app` bundle. No Python, no Node, no external dependencies.

> Built as an open alternative to the proprietary, login-gated computer-use engine bundled with some agents. This one is yours: full control, no auth wall, no guardrails on your own machine.

---

## Features

- **Background-capable control.** Input is delivered to a target app's process (`postToPid`) and clicks prefer the Accessibility `AXPress` action, so the agent can drive an app **without bringing it to the foreground** or stealing your focus.
- **Background clicks that work on web content.** Chromium, Electron and Catalyst apps ignore ordinary posted events for their web views — they hit-test against the window server's idea of the active window. `click_method: "sky_click"` uses the private SkyLight path to land a real, `isTrusted` click on a **backgrounded** Chrome/Electron window without activating it or disturbing whatever app you're actually using.
- **Works with any app** — browsers, Music, Notes, Finder, Mail, native apps — not just the frontmost one.
- **Accessibility-tree perception.** `get_app_state` returns a compact, indexed tree of the interactive elements in an app's window, plus a screenshot. Element indices are stable and used by the action tools, and are scoped to the app that produced them.
- **One coordinate space.** Every coordinate the server prints and every `x,y` it accepts is in **screenshot pixels** — the same space as the image the model is looking at. No mental arithmetic between Retina pixels, window origins and global screen points.
- **Bounded screenshots.** Captures go through ScreenCaptureKit as in-memory images and are rescaled to fit a size budget, so a Retina window doesn't dump multiple megabytes of base64 into the model's context.
- **Reliable browser navigation.** A `navigate` tool sets a browser tab's URL directly via AppleScript (Safari + all Chromium browsers) — no flaky omnibox typing.
- **Followable-cursor overlay.** A separate agent process draws a glowing cursor ring, a status banner, target-element highlights, click flashes, and an **Esc-to-cancel** affordance — so you always see what the agent is doing. The overlay never appears in captures.

## Tools

| Tool | What it does |
|------|--------------|
| `list_apps` | List running applications (name, bundle id, pid). |
| `get_app_state` | Activate-free inspect of an app: screenshot of its key window + an indexed accessibility tree. Call before interacting; `element_index` values and all coordinates come from here. Budget knobs: `text_limit` (default 500, or `"max"`), `max_tree_nodes` (1200), `max_tree_depth` (64). |
| `click` | Click by `element_index` (prefers background `AXPress`) or by `x,y` in screenshot pixels. Supports `click_count`, `mouse_button`, and `click_method` (see below). |
| `type_text` | Type text. Uses real keycodes (accepted by fields that ignore unicode injection); can focus a target `element_index` first. |
| `press_key` | Press a key/combo, xdotool-style: `Return`, `Tab`, `cmd+c`, `cmd+t`, `Up`, … |
| `scroll` | Scroll up/down/left/right by pages, optionally over an element. |
| `set_value` | Set the `AXValue` of a settable element (e.g. a text field) directly. |
| `drag` | Drag the mouse between two screen points. |
| `perform_secondary_action` | Invoke a named accessibility action on an element. |
| `select_text` | Focus a text element. |
| `open_app` | Launch an app (or activate it if already running). Works for any macOS app. |
| `navigate` | Point a browser's active tab at a URL (Safari / Chromium). `new_tab` optional. |

### Click methods

`click` takes a `click_method`, because no single mechanism works everywhere:

| Method | How it lands | Use when |
|--------|--------------|----------|
| `auto` *(default)* | `AXPress` if the element exposes it, else a posted event to the app's pid | Almost always |
| `accessibility` | `AXPress` only, errors if unavailable | You want a guaranteed no-coordinate, no-pointer press |
| `app_post` | Public `CGEvent.postToPid` at coordinates | Native apps that need a real click at a point |
| `sky_click` | Private SkyLight path (left button, 1–2 clicks) | **Background Chromium/Electron web content**, where every other method silently does nothing |
| `global` | System HID tap — moves your real pointer | Last resort; only affects whatever is frontmost |

`sky_click` is deliberately **not** reachable from `auto` and is never fallen back to: it uses
undocumented ABI, so it fails closed with an explicit error rather than silently retrying in a
way that would steal your focus. It requires a fresh `get_app_state` and re-validates that the
window still exists, still belongs to the app, and is still on screen before posting.

Measured on macOS 27, clicking a button in a backgrounded Chrome tab:

```
app_post    → did not land   (frontmost preserved)
global      → did not land   (frontmost preserved)
sky_click   → landed, isTrusted=true, frontmost preserved
```

## Coordinates

`get_app_state` reports the screenshot's pixel size, and every coordinate in the tree — plus
every `x,y` you pass to `click` and `drag` — is in that space. The server converts to global
screen points internally. If you call `click` with coordinates and no prior `get_app_state` for
that app, coordinates are treated as global screen points instead.

## Architecture

A bare stdio subprocess on macOS **cannot host AppKit** (`NSApplication.run()` blocks without LaunchServices registration), so the overlay can't live in the MCP process. The design mirrors the proven client/service split:

```
MCP client (Claude Code)
        │  stdio JSON-RPC
        ▼
mac-computer-use (MCP process)         ── pure CLI: AX + CGEvent + screencapture
        │  launches via `open` (LaunchServices)
        ▼
mac-computer-use overlay (agent)       ── real NSApplication run loop, draws the overlay
        ▲   │
        └───┘  IPC via /tmp/maccu-overlay-state.json (+ /tmp/maccu-overlay-cancel for Esc)
```

- The MCP process never foregrounds apps unless you call `open_app`.
- The overlay agent auto-launches on the first control action and self-terminates when the MCP process exits.

## Build

Requires the Swift toolchain (Xcode or Command Line Tools).

```bash
./build.sh
```

This compiles `main.swift` into `MacComputerUse.app` and ad-hoc code-signs it with a stable identifier (`com.modestnerd.mac-computer-use`) so macOS permission grants survive in-place rebuilds.

## Permissions

Grant these to **MacComputerUse.app** in *System Settings → Privacy & Security*:

- **Accessibility** — read the UI tree and synthesize input. (Keyed by signing identifier, so it persists across rebuilds.)
- **Screen Recording** — capture window screenshots. Used via ScreenCaptureKit on macOS 14+, falling back to `screencapture` on older systems.
- **Automation** (per-app, prompted on first `navigate`) — let it script your browser.

The binary calls the system prompts on first use; you just flip the toggles. Accessibility is required; the rest are optional depending on which tools you use.

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
main.swift                # the entire server + overlay agent
build.sh                  # compile + sign into MacComputerUse.app
THIRD_PARTY_NOTICES.md    # attribution for the SkyLight click recipe
README.md
```

## License

MIT — do what you like. The `sky_click` event recipe is derived from the MIT-licensed Cua
Driver; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
