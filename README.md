# mac-computer-use

A native macOS **computer-use** server for AI agents, exposed over the [Model Context Protocol (MCP)](https://modelcontextprotocol.io). It lets an MCP client (e.g. Claude Code) **see and control any macOS app** through the Accessibility API and CoreGraphics — clicking, typing, scrolling, reading the on-screen UI tree, and taking screenshots — with a live "agent is controlling your Mac" overlay.

It is a single, self-contained Swift binary packaged as a signed `.app` bundle. No Python, no Node, no external dependencies.

> Built as an open alternative to the proprietary, login-gated computer-use engine bundled with some agents. This one is yours: full control, no auth wall, no guardrails on your own machine.

---

## Features

- **Background-capable control.** Input is delivered to a target app's process (`postToPid`) and clicks prefer the Accessibility `AXPress` action, so the agent can drive an app **without bringing it to the foreground** or stealing your focus.
- **Works with any app** — browsers, Music, Notes, Finder, Mail, native apps — not just the frontmost one.
- **Accessibility-tree perception.** `get_app_state` returns a compact, indexed tree of the interactive elements in an app's window, plus a screenshot. Element indices are stable and used by the action tools.
- **Window-id screenshots.** Captures a specific window by id, so it works even when the window is occluded or in the background.
- **Reliable browser navigation.** A `navigate` tool sets a browser tab's URL directly via AppleScript (Safari + all Chromium browsers) — no flaky omnibox typing.
- **Followable-cursor overlay.** A separate agent process draws a glowing cursor ring, a status banner, target-element highlights, click flashes, and an **Esc-to-cancel** affordance — so you always see what the agent is doing. The overlay is excluded from screenshots so it never pollutes captures.

## Tools

| Tool | What it does |
|------|--------------|
| `list_apps` | List running applications (name, bundle id, pid). |
| `get_app_state` | Activate-free inspect of an app: screenshot of its key window + an indexed accessibility tree. Call before interacting; `element_index` values come from here. |
| `click` | Click by `element_index` (prefers background `AXPress`) or by `x,y` pixels. Supports `click_count` and `mouse_button`. |
| `type_text` | Type text. Uses real keycodes (accepted by fields that ignore unicode injection); can focus a target `element_index` first. |
| `press_key` | Press a key/combo, xdotool-style: `Return`, `Tab`, `cmd+c`, `cmd+t`, `Up`, … |
| `scroll` | Scroll up/down/left/right by pages, optionally over an element. |
| `set_value` | Set the `AXValue` of a settable element (e.g. a text field) directly. |
| `drag` | Drag the mouse between two screen points. |
| `perform_secondary_action` | Invoke a named accessibility action on an element. |
| `select_text` | Focus a text element. |
| `open_app` | Launch an app (or activate it if already running). Works for any macOS app. |
| `navigate` | Point a browser's active tab at a URL (Safari / Chromium). `new_tab` optional. |

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
- **Screen Recording** — capture window screenshots.
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
main.swift     # the entire server + overlay agent
build.sh       # compile + sign into MacComputerUse.app
README.md
```

## License

MIT — do what you like.
