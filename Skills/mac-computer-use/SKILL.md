---
name: mac-computer-use
description: Operate macOS apps through the Mac Computer Use MCP server (get_app_state, click, type_text, set_value, invoke_menu, navigate, verify_state) and talk to the user through its on-screen cursor (point_at, annotate, ask_user, pick_element, wait_for_user, guide). Use when a task needs to see or control a Mac app's interface, show the user something on screen, ask them to choose or point at something, or hand them a step such as a password, 2FA code or permission dialog.
---

# Mac Computer Use

Mac Computer Use lets you read and operate Mac apps through the accessibility APIs, usually without bringing them to the front. The user sees a cursor fly to every element you act on, so work as if someone is watching: deliberate, few actions, and say what you are about to do.

## The loop: look, act, check

1. **Find the app.** `list_apps` shows what is running. `open_app` launches an app that is not running; pass `background: true` so it does not steal focus. You do not need `open_app` to work with an app that is already running.
2. **Look.** Call `get_app_state(app)` before interacting. It returns a screenshot of the key window and an indexed accessibility tree. Every `element_index` and every x,y comes from this snapshot, so call it again after anything that changes the screen (navigation, a dialog, a new window, a tab switch).
3. **Act.** Prefer `element_index` over x,y, and prefer the most direct tool:
   - fields: `set_value(element_index, value)`; or `click` the field, then `type_text`
   - text selection: `select_text` (exact, case-sensitive match; never clicks)
   - menus: `invoke_menu(app, ["File", "New Window"])`
   - browsers: `navigate(url)` instead of typing into the address bar (Safari and Chromium browsers)
   - shortcuts: `press_key` with combos such as `cmd+c`, `Return`, `Tab`
   - named accessibility actions: `perform_secondary_action`; lists and pages: `scroll`
4. **Check.** Use `verify_state(app, text, condition)` to wait for an outcome instead of sleeping, or take a fresh `get_app_state`. Do not report success you have not seen.

Coordinates are screenshot pixels from the last `get_app_state`, not screen points. The exceptions: `set_window_frame` takes global screen points (use `window_id` from `list_windows`), and the desktop tools use pixels of the `get_desktop_state` display screenshot.

## Background input first

App tools work on background apps and do not move the user's real pointer. `get_desktop_state`, `desktop_click` and `desktop_press_key` are the only global input path (menu bar extras, the desktop, system UI). They need `allow_global_input: true` and a fresh desktop snapshot, and they move the real pointer and keyboard, so use them only when an app tool cannot do the job, and never while the user is typing.

## Talking to the user through the cursor

- `point_at`: fly the cursor to an element with a short label, without clicking. Use it to show what you are about to act on or to teach.
- `annotate`: draw boxes, ellipses, arrows, lines and labels, plus an optional caption, pinned to `element_index` where possible. Call `clear_annotations` when you are done.
- `ask_user`: ask a short question with 2 to 4 answer chips beside the cursor. Only the user's physical click answers it.
- `pick_element`: let the user click the thing they mean; you get its app, element and `element_index`.
- `wait_for_user`: hand over a step you must not do yourself, such as passwords, 2FA codes, payment details, CAPTCHAs and permission dialogs. Point at the element with an instruction and wait for the user to finish. Never type secrets yourself.
- `guide`: walk the user through a task one step at a time. Pass `save_as` to keep the tour so they can replay it from the Mac Computer Use menu.

## Safety the app enforces

- **Risky clicks.** Before pressing something like Send, Delete, Buy, Submit, Publish or Sign Out, the cursor rests on it with a short countdown so the user can stop it with Esc. Get the user's go-ahead in chat for anything irreversible, and `point_at` the control first.
- **Esc pauses every agent.** A result starting `[user_interrupted]` means the user stopped you. Do not retry; ask what they want. They resume from the menu bar.
- **The user is busy.** `[user_busy]` means they kept using the app, so nothing was done. Wait, or ask before retrying.
- **Hidden windows.** `[window_hidden]` means another window covers the target, so the user could not see the action. Bring it forward with `open_app` (or ask the user), call `get_app_state`, then retry.
- Secure (password) fields are never read or selected.

## Error codes

| Result starts with | What to do |
| --- | --- |
| `[client_not_allowed]` | The user has not allowed this agent. Ask them to allow it in Mac Computer Use Setup, then retry. |
| `[approval_pending]` | Mac Computer Use is asking the user to allow this agent. Ask them to answer the prompt. |
| `[stopped_by_user]` | The user quit Mac Computer Use. Ask them to reopen it; do not retry in a loop. |
| `[service_unavailable]`, `[service_mismatch]` | Ask the user to open (or quit and reopen) Mac Computer Use. |
| `[service_disconnected]` | The app restarted mid-call; the action may or may not have happened. Call `get_app_state` before retrying. |
| `[updating]` | An update is installing. Retry in a few seconds. |
| `[timeout]`, `[user_dismissed]` | The user did not answer. Do not assume an answer; ask in chat or stop. |
| `[requires_service]` | The server runs in-process without the overlay; cursor tools are unavailable. Continue without them. |

When something looks like a permission problem, call `health_report` and tell the user which permission (Accessibility or Screen Recording) to grant in Mac Computer Use Setup. Never try to change system settings yourself.
