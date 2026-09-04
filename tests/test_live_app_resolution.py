#!/usr/bin/env python3
"""Regression test for stale NSWorkspace app resolution.

The MCP process takes one running-app snapshot, then a temporary GUI app is
launched. The same MCP process must discover that newly launched app without
being restarted or requiring an unrelated open_app call.
"""

from __future__ import annotations

import base64
import ctypes
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import uuid


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SERVER_BINARY = REPO_ROOT / "MacComputerUse.app/Contents/MacOS/mac-computer-use"
SERVER_BINARY = Path(os.environ.get("MACCU_BINARY", DEFAULT_SERVER_BINARY))
FIXTURE_NAME = "MaccuLiveAppFixture"

FIXTURE_SOURCE = r"""
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let windowStyle: NSWindow.StyleMask = CommandLine.arguments.contains("fixed-size-window")
    ? [.titled, .closable]
    : [.titled, .closable, .resizable]
let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 320, height: 180),
    styleMask: windowStyle,
    backing: .buffered,
    defer: false
)
window.title = "Mac Computer Use Live App Fixture"

final class FixtureClickView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.title = "Background Click Received"
    }

    override func scrollWheel(with event: NSEvent) {
        window?.title = "Background Scroll Received"
    }

    override func mouseDragged(with event: NSEvent) {
        window?.title = "Background Drag Received"
    }
}

let clickView = FixtureClickView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
clickView.autoresizingMask = [.width, .height]
window.contentView = clickView

final class FixtureMenuTarget: NSObject {
    let window: NSWindow
    init(window: NSWindow) { self.window = window }

    @objc func markInvoked() {
        window.title = "Menu Action Invoked"
    }
}

let menuTarget = FixtureMenuTarget(window: window)
let menuBar = NSMenu(title: "Main")
let applicationMenuItem = NSMenuItem(title: "Application", action: nil, keyEquivalent: "")
applicationMenuItem.submenu = NSMenu(title: "Application")
menuBar.addItem(applicationMenuItem)
let fixtureMenuItem = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
let fixtureMenu = NSMenu(title: "Fixture")
let markItem = NSMenuItem(
    title: "Mark Invoked",
    action: #selector(FixtureMenuTarget.markInvoked),
    keyEquivalent: ""
)
markItem.target = menuTarget
fixtureMenu.addItem(markItem)
fixtureMenuItem.submenu = fixtureMenu
menuBar.addItem(fixtureMenuItem)
if CommandLine.arguments.contains("duplicate-menu") {
    let duplicateItem = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
    let duplicateMenu = NSMenu(title: "Fixture")
    let duplicateMark = NSMenuItem(
        title: "Mark Invoked",
        action: #selector(FixtureMenuTarget.markInvoked),
        keyEquivalent: ""
    )
    duplicateMark.target = menuTarget
    duplicateMenu.addItem(duplicateMark)
    duplicateItem.submenu = duplicateMenu
    menuBar.addItem(duplicateItem)
}
app.mainMenu = menuBar

var secondaryWindow: NSWindow?
final class NonKeyFixturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
var floatingPanel: NSPanel?
if CommandLine.arguments.contains("two-windows") {
    window.title = "Shared Window Title"
    window.contentView = NSTextField(labelWithString: "Primary Window Marker")

    let secondary = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 320, height: 180),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    secondary.title = "Shared Window Title"
    secondary.contentView = NSTextField(labelWithString: "Secondary Window Marker")
    secondaryWindow = secondary
    secondary.orderFront(nil)
}

window.makeKeyAndOrderFront(nil)
if CommandLine.arguments.contains("floating-window") {
    window.title = "Primary Fixture Window"
    window.contentView = NSTextField(labelWithString: "Primary Window Marker")
    let panel = NonKeyFixturePanel(
        contentRect: NSRect(x: 240, y: 220, width: 260, height: 140),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    panel.title = "Floating Fixture Window"
    panel.contentView = NSTextField(labelWithString: "Floating Window Marker")
    floatingPanel = panel
    panel.orderFront(nil)
}
app.activate(ignoringOtherApps: true)
app.run()
"""

def fixture_info_plist(bundle_id: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>{FIXTURE_NAME}</string>
  <key>CFBundleDisplayName</key><string>{FIXTURE_NAME}</string>
  <key>CFBundleIdentifier</key><string>{bundle_id}</string>
  <key>CFBundleExecutable</key><string>{FIXTURE_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><false/>
</dict>
</plist>
"""


class MCPClient:
    def __init__(self, binary: Path, response_timeout: float = 15) -> None:
        self.response_timeout = response_timeout
        self.process = subprocess.Popen(
            [str(binary)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self._next_id = 1
        self.initialize_response: dict = {}
        try:
            self.initialize_response = self.request("initialize", {})
        except Exception:
            self.close()
            raise

    def request(self, method: str, params: dict) -> dict:
        request_id = self._next_id
        self._next_id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        }
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()

        assert self.process.stdout is not None
        while True:
            readable, _, _ = select.select(
                [self.process.stdout.fileno()],
                [],
                [],
                self.response_timeout,
            )
            if not readable:
                raise TimeoutError(
                    f"MCP server did not reply to {method!r} within {self.response_timeout}s"
                )
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("MCP server exited before replying")
            response = json.loads(line)
            if response.get("id") == request_id:
                return response

    def call_tool(self, name: str, arguments: dict | None = None) -> dict:
        response = self.request(
            "tools/call",
            {"name": name, "arguments": arguments or {}},
        )
        return response["result"]

    def close(self) -> None:
        if self.process.stdin is not None:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        if self.process.stdout is not None:
            self.process.stdout.close()


def text_content(result: dict) -> str:
    return "\n".join(
        block.get("text", "")
        for block in result.get("content", [])
        if block.get("type") == "text"
    )


def parse_list_windows(text: str) -> list[dict]:
    windows: list[dict] = []
    pattern = re.compile(
        r'window_id=(?P<window_id>\d+).*?'
        r'title="(?P<title>[^"]*)" '
        r'bounds=\(x:(?P<x>-?[\d.]+), y:(?P<y>-?[\d.]+), '
        r'width:(?P<width>[\d.]+), height:(?P<height>[\d.]+)\)'
    )
    for match in pattern.finditer(text):
        values = match.groupdict()
        windows.append(
            {
                "window_id": int(values["window_id"]),
                "x": float(values["x"]),
                "y": float(values["y"]),
                "width": float(values["width"]),
                "height": float(values["height"]),
                "title": values["title"],
            }
        )
    return windows


class QuartzPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


def hardware_pointer_location() -> tuple[float, float]:
    core_graphics = ctypes.CDLL(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
    )
    core_foundation = ctypes.CDLL(
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
    )
    core_graphics.CGEventCreate.argtypes = [ctypes.c_void_p]
    core_graphics.CGEventCreate.restype = ctypes.c_void_p
    core_graphics.CGEventGetLocation.argtypes = [ctypes.c_void_p]
    core_graphics.CGEventGetLocation.restype = QuartzPoint
    core_foundation.CFRelease.argtypes = [ctypes.c_void_p]
    event = core_graphics.CGEventCreate(None)
    if not event:
        raise RuntimeError("CGEventCreate returned null")
    try:
        point = core_graphics.CGEventGetLocation(event)
        return point.x, point.y
    finally:
        core_foundation.CFRelease(event)


def png_dimensions(result: dict) -> tuple[int, int]:
    image = next(block for block in result["content"] if block.get("type") == "image")
    data = base64.b64decode(image["data"])
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError("get_app_state image is not PNG")
    return struct.unpack(">II", data[16:24])


def frontmost_bundle_id() -> str:
    front = subprocess.run(
        ["/usr/bin/lsappinfo", "front"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    info = subprocess.run(
        ["/usr/bin/lsappinfo", "info", front],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    match = re.search(r'bundleID="([^"]+)"', info)
    if not match:
        raise AssertionError(f"Could not read frontmost bundle ID: {info}")
    return match.group(1)


def fixture_pids(executable: Path) -> list[int]:
    probe = subprocess.run(
        ["pgrep", "-f", str(executable)],
        check=False,
        capture_output=True,
        text=True,
    )
    return [int(line) for line in probe.stdout.splitlines() if line.strip().isdigit()]


class LiveAppResolutionTests(unittest.TestCase):
    def setUp(self) -> None:
        if not SERVER_BINARY.exists():
            self.fail(f"Build the server first: missing {SERVER_BINARY}")
        self.temp_dir = Path(tempfile.mkdtemp(prefix="maccu-live-app-test-"))
        self.fixture_bundle_id = (
            f"cc.antonlabs.maccu-live-app-fixture.run-{uuid.uuid4().hex}"
        )
        self.bundle = self.temp_dir / f"{FIXTURE_NAME}.app"
        self.executable = self.bundle / f"Contents/MacOS/{FIXTURE_NAME}"
        self.executable.parent.mkdir(parents=True)
        source = self.temp_dir / "Fixture.swift"
        source.write_text(FIXTURE_SOURCE)
        (self.bundle / "Contents/Info.plist").write_text(
            fixture_info_plist(self.fixture_bundle_id)
        )
        subprocess.run(
            [
                "swiftc",
                str(source),
                "-o",
                str(self.executable),
                "-framework",
                "AppKit",
            ],
            check=True,
        )
        self.client = MCPClient(SERVER_BINARY)

    def tearDown(self) -> None:
        for pid in fixture_pids(self.executable):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.client.close()
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def launch_fixture(self, *arguments: str) -> int:
        command = ["open", "-na", str(self.bundle)]
        if arguments:
            command.extend(["--args", *arguments])
        subprocess.run(command, check=True)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            pids = fixture_pids(self.executable)
            if pids:
                return pids[0]
            time.sleep(0.05)
        self.fail("fixture app did not launch")

    def stop_fixture(self, pid: int) -> None:
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if pid not in fixture_pids(self.executable):
                return
            time.sleep(0.05)
        self.fail(f"fixture PID {pid} did not terminate")

    def listed_fixture_pids(self) -> list[int]:
        listing = text_content(self.client.call_tool("list_apps"))
        matches = re.findall(rf"\[{re.escape(self.fixture_bundle_id)}\] pid=(\d+)", listing)
        self.assertTrue(matches, "long-lived MCP process returned a stale app snapshot")
        return [int(pid) for pid in matches]

    def assert_fixture_state_available(self, expected_pid: int) -> None:
        deadline = time.monotonic() + 5
        last_state: dict = {}
        while time.monotonic() < deadline:
            last_state = self.client.call_tool(
                "get_app_state", {"app": self.fixture_bundle_id}
            )
            state_text = text_content(last_state)
            has_image = any(block.get("type") == "image" for block in last_state.get("content", []))
            if (
                not last_state.get("isError")
                and "No window found" not in state_text
                and f"(pid {expected_pid})" in state_text
                and has_image
            ):
                return
            time.sleep(0.05)
        self.fail(text_content(last_state) or "fixture app state never became available")

    def test_app_scoped_input_rejects_empty_target(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assertEqual([fixture_pid], self.listed_fixture_pids())
        for invalid_app in ("", " \t\n"):
            with self.subTest(app=repr(invalid_app)):
                result = self.client.call_tool("type_text", {"app": invalid_app, "text": ""})
                self.assertTrue(result.get("isError"), text_content(result))
                self.assertIn("needs 'app'", text_content(result))

    def test_click_rejects_global_hardware_pointer_mode(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        pointer_before = hardware_pointer_location()
        result = self.client.call_tool(
            "click",
            {"app": self.fixture_bundle_id, "click_method": "global"},
        )
        pointer_after = hardware_pointer_location()

        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("click_method must be", text_content(result))
        self.assertLessEqual(abs(pointer_after[0] - pointer_before[0]), 1.0)
        self.assertLessEqual(abs(pointer_after[1] - pointer_before[1]), 1.0)

    def test_click_rejects_unbounded_coordinates_without_exiting(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        result = self.client.call_tool(
            "click",
            {
                "app": self.fixture_bundle_id,
                "x": 1e20,
                "y": 10,
                "click_method": "app_post",
            },
        )
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("screenshot bounds", text_content(result))
        self.assertIn("Running apps", text_content(self.client.call_tool("list_apps")))

    def test_click_rejects_coordinates_outside_snapshot(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        state = self.client.call_tool("get_app_state", {"app": self.fixture_bundle_id})
        width, _ = png_dimensions(state)
        result = self.client.call_tool(
            "click",
            {
                "app": self.fixture_bundle_id,
                "x": width,
                "y": 10,
                "click_method": "app_post",
            },
        )
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("screenshot bounds", text_content(result))

    def test_click_rejects_unbounded_click_count_without_exiting(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        result = self.client.call_tool(
            "click",
            {
                "app": self.fixture_bundle_id,
                "x": 10,
                "y": 10,
                "click_count": 1e20,
                "click_method": "app_post",
            },
        )
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("click_count", text_content(result))
        self.assertIn("Running apps", text_content(self.client.call_tool("list_apps")))

    def test_scroll_rejects_unbounded_pages_without_exiting(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        result = self.client.call_tool(
            "scroll",
            {
                "app": self.fixture_bundle_id,
                "direction": "down",
                "pages": 1e20,
            },
        )
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("pages", text_content(result))
        self.assertIn("Running apps", text_content(self.client.call_tool("list_apps")))

    def test_scroll_rejects_malformed_pages_without_exiting(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        result = self.client.call_tool(
            "scroll",
            {
                "app": self.fixture_bundle_id,
                "direction": "down",
                "pages": "many",
            },
        )
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("pages", text_content(result))
        self.assertIn("Running apps", text_content(self.client.call_tool("list_apps")))

    def test_drag_rejects_coordinates_outside_snapshot_without_exiting(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        result = self.client.call_tool(
            "drag",
            {
                "app": self.fixture_bundle_id,
                "from_x": 1e20,
                "from_y": 10,
                "to_x": 20,
                "to_y": 20,
            },
        )
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("screenshot bounds", text_content(result))
        self.assertIn("Running apps", text_content(self.client.call_tool("list_apps")))

    def test_scroll_and_drag_require_snapshot_authority(self) -> None:
        self.launch_fixture()
        fresh_client = MCPClient(SERVER_BINARY)
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if self.fixture_bundle_id in text_content(
                    fresh_client.call_tool("list_apps")
                ):
                    break
                time.sleep(0.05)
            else:
                self.fail("fresh server could not resolve fixture")

            cases = [
                (
                    "click",
                    {
                        "app": self.fixture_bundle_id,
                        "x": 10,
                        "y": 10,
                        "click_method": "app_post",
                    },
                ),
                ("scroll", {"app": self.fixture_bundle_id, "direction": "down"}),
                (
                    "drag",
                    {
                        "app": self.fixture_bundle_id,
                        "from_x": 10,
                        "from_y": 10,
                        "to_x": 20,
                        "to_y": 20,
                    },
                ),
            ]
            for tool_name, arguments in cases:
                with self.subTest(tool=tool_name):
                    result = fresh_client.call_tool(tool_name, arguments)
                    self.assertTrue(result.get("isError"), text_content(result))
                    self.assertIn("get_app_state snapshot", text_content(result))
        finally:
            fresh_client.close()

    def test_open_app_tracks_resolved_application_and_pid(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        result = self.client.call_tool("open_app", {"app": self.fixture_bundle_id})
        self.assertFalse(result.get("isError"), text_content(result))

        deadline = time.monotonic() + 3
        overlay = None
        while time.monotonic() < deadline:
            overlay = json.loads(
                text_content(self.client.call_tool("health_report"))
            )["overlay"]
            if overlay["status"] == "running":
                break
            time.sleep(0.05)
        self.assertIsNotNone(overlay)
        assert overlay is not None
        self.assertEqual("running", overlay["status"], overlay)
        self.assertEqual(FIXTURE_NAME, overlay["current_app"])
        state = json.loads(Path(overlay["state_file"]).read_text())
        self.assertEqual(fixture_pid, state["current_app_pid"])

    def test_type_text_with_element_index_requires_snapshot_authority(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        fresh_client = MCPClient(SERVER_BINARY)
        try:
            result = fresh_client.call_tool(
                "type_text",
                {
                    "app": self.fixture_bundle_id,
                    "element_index": 0,
                    "text": "must not be delivered",
                },
            )
            self.assertTrue(result.get("isError"), text_content(result))
            self.assertIn("valid element_index", text_content(result))
        finally:
            fresh_client.close()

    def test_app_scoped_input_fails_closed_when_target_is_missing(self) -> None:
        missing_app = "cc.antonlabs.missing-input-target"
        cases = [
            ("click", {"app": missing_app}),
            ("type_text", {"app": missing_app, "text": ""}),
            ("press_key", {"app": missing_app, "key": "not-a-real-key"}),
            ("scroll", {"app": missing_app, "direction": "invalid"}),
            ("set_value", {"app": missing_app, "element_index": "-1", "value": ""}),
            ("drag", {"app": missing_app}),
            (
                "perform_secondary_action",
                {"app": missing_app, "element_index": "-1", "action": "Press"},
            ),
            ("select_text", {"app": missing_app, "element_index": "-1", "text": ""}),
        ]
        for tool_name, arguments in cases:
            with self.subTest(tool=tool_name):
                result = self.client.call_tool(tool_name, arguments)
                self.assertTrue(result.get("isError"), text_content(result))
                self.assertIn("App not found", text_content(result))

    def test_get_app_state_targets_exact_window_id(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)

        listing = text_content(
            self.client.call_tool("list_windows", {"app": self.fixture_bundle_id})
        )
        match = re.search(r"window_id=(\d+)", listing)
        self.assertIsNotNone(match, listing)
        assert match is not None
        window_id = int(match.group(1))

        state = self.client.call_tool(
            "get_app_state",
            {"app": self.fixture_bundle_id, "window_id": window_id},
        )
        self.assertFalse(state.get("isError"), text_content(state))
        self.assertIn(f"Window ID: {window_id}", text_content(state))
        self.assertTrue(
            any(block.get("type") == "image" for block in state.get("content", [])),
            text_content(state),
        )

        invalid = self.client.call_tool(
            "get_app_state",
            {"app": self.fixture_bundle_id, "window_id": window_id + 10_000_000},
        )
        self.assertTrue(invalid.get("isError"), text_content(invalid))
        self.assertIn("Window not found", text_content(invalid))

    def test_exact_window_id_distinguishes_identical_title_and_frame(self) -> None:
        fixture_pid = self.launch_fixture("two-windows")
        self.assert_fixture_state_available(fixture_pid)
        listing = text_content(
            self.client.call_tool("list_windows", {"app": self.fixture_bundle_id})
        )
        window_ids = [int(value) for value in re.findall(r"window_id=(\d+)", listing)]
        self.assertGreaterEqual(len(window_ids), 2, listing)

        states = [
            text_content(
                self.client.call_tool(
                    "get_app_state",
                    {"app": self.fixture_bundle_id, "window_id": window_id},
                )
            )
            for window_id in window_ids[:2]
        ]
        self.assertTrue(any("Primary Window Marker" in state for state in states), states)
        self.assertTrue(any("Secondary Window Marker" in state for state in states), states)

    def test_default_snapshot_tree_matches_returned_window_identity(self) -> None:
        self.launch_fixture("floating-window")
        deadline = time.monotonic() + 5
        listing = ""
        while time.monotonic() < deadline:
            listing = text_content(
                self.client.call_tool(
                    "list_windows",
                    {"app": self.fixture_bundle_id},
                )
            )
            if "Primary Fixture Window" in listing and "Floating Fixture Window" in listing:
                break
            time.sleep(0.05)
        else:
            self.fail(listing or "fixture windows were not listed")

        identities = {
            int(window_id): title
            for window_id, title in re.findall(
                r'window_id=(\d+).*?title="([^"]+)"',
                listing,
            )
        }
        result = self.client.call_tool(
            "get_app_state",
            {"app": self.fixture_bundle_id},
        )
        result_text = text_content(result)
        self.assertFalse(result.get("isError"), result_text)
        match = re.search(r"Window ID: (\d+)", result_text)
        if match is None:
            self.fail(result_text)
        returned_id = int(match.group(1))
        returned_title = identities[returned_id]
        expected_marker = {
            "Primary Fixture Window": "Primary Window Marker",
            "Floating Fixture Window": "Floating Window Marker",
        }[returned_title]
        other_marker = {
            "Primary Fixture Window": "Floating Window Marker",
            "Floating Fixture Window": "Primary Window Marker",
        }[returned_title]
        self.assertIn(expected_marker, result_text)
        self.assertNotIn(other_marker, result_text)

    def test_verify_state_waits_for_present_and_missing_text(self) -> None:
        self.launch_fixture()
        present = self.client.call_tool(
            "verify_state",
            {
                "app": self.fixture_bundle_id,
                "text": "Mac Computer Use Live App Fixture",
                "condition": "exists",
                "timeout_ms": 1000,
            },
        )
        self.assertFalse(present.get("isError"), text_content(present))
        self.assertIn("Verified", text_content(present))

        missing = self.client.call_tool(
            "verify_state",
            {
                "app": self.fixture_bundle_id,
                "text": "cc.antonlabs.text-that-does-not-exist",
                "condition": "exists",
                "timeout_ms": 100,
            },
        )
        self.assertTrue(missing.get("isError"), text_content(missing))
        self.assertIn("Timed out", text_content(missing))

    def test_verify_state_fails_if_target_exits_during_wait(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)

        def kill_fixture() -> None:
            try:
                os.kill(fixture_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

        timer = threading.Timer(0.2, kill_fixture)
        timer.start()
        try:
            result = self.client.call_tool(
                "verify_state",
                {
                    "app": self.fixture_bundle_id,
                    "text": "Mac Computer Use Live App Fixture",
                    "condition": "not_exists",
                    "timeout_ms": 2_000,
                    "poll_interval_ms": 50,
                },
            )
        finally:
            timer.cancel()

        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("target exited or changed identity", text_content(result))

    def test_set_window_frame_updates_windowserver_bounds(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        listing = text_content(
            self.client.call_tool("list_windows", {"app": self.fixture_bundle_id})
        )
        match = re.search(
            r"window_id=(\d+).*bounds=\(x:(-?\d+), y:(-?\d+), width:(\d+), height:(\d+)\)",
            listing,
        )
        self.assertIsNotNone(match, listing)
        assert match is not None
        window_id, x, y, width, height = map(int, match.groups())
        expected = (x + 20, y + 20, width + 40, height + 30)

        result = self.client.call_tool(
            "set_window_frame",
            {
                "app": self.fixture_bundle_id,
                "window_id": window_id,
                "x": expected[0],
                "y": expected[1],
                "width": expected[2],
                "height": expected[3],
            },
        )
        self.assertFalse(result.get("isError"), text_content(result))

        deadline = time.monotonic() + 2
        observed = None
        while time.monotonic() < deadline:
            listing = text_content(
                self.client.call_tool("list_windows", {"app": self.fixture_bundle_id})
            )
            current = re.search(
                rf"window_id={window_id}.*bounds=\(x:(-?\d+), y:(-?\d+), width:(\d+), height:(\d+)\)",
                listing,
            )
            if current:
                observed = tuple(map(int, current.groups()))
                if all(abs(actual - wanted) <= 2 for actual, wanted in zip(observed, expected)):
                    break
            time.sleep(0.05)
        self.assertIsNotNone(observed, listing)
        assert observed is not None
        self.assertTrue(
            all(abs(actual - wanted) <= 2 for actual, wanted in zip(observed, expected)),
            f"expected {expected}, observed {observed}",
        )

    def test_window_move_invalidates_old_snapshot_coordinates(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        listing = text_content(
            self.client.call_tool("list_windows", {"app": self.fixture_bundle_id})
        )
        match = re.search(
            r"window_id=(\d+).*bounds=\(x:(-?\d+), y:(-?\d+), width:(\d+), height:(\d+)\)",
            listing,
        )
        if match is None:
            self.fail(listing)
        window_id, x, y, width, height = map(int, match.groups())
        moved = self.client.call_tool(
            "set_window_frame",
            {
                "app": self.fixture_bundle_id,
                "window_id": window_id,
                "x": x + 80,
                "y": y + 60,
                "width": width,
                "height": height,
            },
        )
        self.assertFalse(moved.get("isError"), text_content(moved))

        stale_click = self.client.call_tool(
            "click",
            {
                "app": self.fixture_bundle_id,
                "x": 20,
                "y": 20,
                "click_method": "app_post",
            },
        )
        self.assertTrue(stale_click.get("isError"), text_content(stale_click))
        self.assertIn("fresh get_app_state", text_content(stale_click))

    def test_set_window_frame_rolls_back_when_size_is_rejected(self) -> None:
        fixture_pid = self.launch_fixture("fixed-size-window")
        self.assert_fixture_state_available(fixture_pid)
        before = next(
            window
            for window in parse_list_windows(
                text_content(self.client.call_tool("list_windows", {"app": self.fixture_bundle_id}))
            )
            if window["title"] == "Mac Computer Use Live App Fixture"
        )
        result = self.client.call_tool(
            "set_window_frame",
            {
                "app": self.fixture_bundle_id,
                "window_id": before["window_id"],
                "x": before["x"] + 70,
                "y": before["y"] + 50,
                "width": before["width"] + 100,
                "height": before["height"] + 80,
            },
        )
        self.assertTrue(result.get("isError"), text_content(result))
        after = next(
            window
            for window in parse_list_windows(
                text_content(self.client.call_tool("list_windows", {"app": self.fixture_bundle_id}))
            )
            if window["window_id"] == before["window_id"]
        )
        for key in ("x", "y", "width", "height"):
            self.assertAlmostEqual(before[key], after[key], delta=2, msg=(before, after))

    def test_invoke_menu_runs_named_menu_path(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        result = self.client.call_tool(
            "invoke_menu",
            {
                "app": self.fixture_bundle_id,
                "path": ["Fixture", "Mark Invoked"],
            },
        )
        self.assertFalse(result.get("isError"), text_content(result))

        changed = self.client.call_tool(
            "verify_state",
            {
                "app": self.fixture_bundle_id,
                "text": "Menu Action Invoked",
                "condition": "exists",
                "timeout_ms": 1000,
            },
        )
        self.assertFalse(changed.get("isError"), text_content(changed))

    def test_invoke_menu_missing_path_fails_closed(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        result = self.client.call_tool(
            "invoke_menu",
            {
                "app": self.fixture_bundle_id,
                "path": ["Fixture", "Missing Action"],
            },
        )
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("path segment 2: Missing Action", text_content(result))

        unchanged = self.client.call_tool(
            "verify_state",
            {
                "app": self.fixture_bundle_id,
                "text": "Menu Action Invoked",
                "condition": "not_exists",
                "timeout_ms": 200,
            },
        )
        self.assertFalse(unchanged.get("isError"), text_content(unchanged))

    def test_invoke_menu_rejects_omitted_parent_segment(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        result = self.client.call_tool(
            "invoke_menu",
            {
                "app": self.fixture_bundle_id,
                "path": ["Mark Invoked"],
            },
        )
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("path segment 1", text_content(result))
        unchanged = self.client.call_tool(
            "verify_state",
            {
                "app": self.fixture_bundle_id,
                "text": "Menu Action Invoked",
                "condition": "not_exists",
                "timeout_ms": 200,
            },
        )
        self.assertFalse(unchanged.get("isError"), text_content(unchanged))

    def test_invoke_menu_rejects_ambiguous_segment(self) -> None:
        fixture_pid = self.launch_fixture("duplicate-menu")
        self.assert_fixture_state_available(fixture_pid)
        result = self.client.call_tool(
            "invoke_menu",
            {
                "app": self.fixture_bundle_id,
                "path": ["Fixture", "Mark Invoked"],
            },
        )
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("ambiguous path segment 1", text_content(result))

    def test_sky_click_uses_virtual_cursor_without_moving_hardware_pointer(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        state = self.client.call_tool("get_app_state", {"app": self.fixture_bundle_id})
        image_width, image_height = png_dimensions(state)
        target_pixel = (image_width / 2, image_height * 0.65)

        listing = text_content(
            self.client.call_tool("list_windows", {"app": self.fixture_bundle_id})
        )
        match = re.search(
            r"bounds=\(x:(-?\d+), y:(-?\d+), width:(\d+), height:(\d+)\)",
            listing,
        )
        self.assertIsNotNone(match, listing)
        assert match is not None
        x, y, width, _ = map(int, match.groups())
        pixel_scale = image_width / width
        expected_quartz = (
            x + target_pixel[0] / pixel_scale,
            y + target_pixel[1] / pixel_scale,
        )

        report = json.loads(text_content(self.client.call_tool("health_report")))
        state_path = Path(report["overlay"]["state_file"])
        frontmost_before = frontmost_bundle_id()
        pointer_before = hardware_pointer_location()
        result = self.client.call_tool(
            "click",
            {
                "app": self.fixture_bundle_id,
                "x": target_pixel[0],
                "y": target_pixel[1],
                "click_method": "sky_click",
            },
        )
        pointer_after = hardware_pointer_location()
        frontmost_after = frontmost_bundle_id()
        self.assertFalse(result.get("isError"), text_content(result))
        self.assertEqual(0o700, state_path.parent.stat().st_mode & 0o777)
        self.assertEqual(frontmost_before, frontmost_after)
        self.assertLessEqual(abs(pointer_after[0] - pointer_before[0]), 1.0)
        self.assertLessEqual(abs(pointer_after[1] - pointer_before[1]), 1.0)

        received = self.client.call_tool(
            "verify_state",
            {
                "app": self.fixture_bundle_id,
                "text": "Background Click Received",
                "condition": "exists",
                "timeout_ms": 1000,
            },
        )
        self.assertFalse(received.get("isError"), text_content(received))

        overlay_state = json.loads(state_path.read_text())
        self.assertIn("cursor", overlay_state)
        self.assertAlmostEqual(expected_quartz[0], overlay_state["cursor"][0], delta=2)
        self.assertAlmostEqual(expected_quartz[1], overlay_state["cursor"][1], delta=2)

        deadline = time.monotonic() + 3
        overlay_health = None
        while time.monotonic() < deadline:
            overlay_health = json.loads(
                text_content(self.client.call_tool("health_report"))
            )["overlay"]
            if overlay_health["status"] == "running":
                break
            time.sleep(0.05)
        self.assertIsNotNone(overlay_health)
        assert overlay_health is not None
        self.assertEqual("running", overlay_health["status"], overlay_health)
        self.assertIsInstance(overlay_health["agent_pid"], int)
        ready = json.loads(Path(overlay_health["ready_file"]).read_text())
        self.assertEqual(self.client.process.pid, ready["owner_pid"])
        self.assertEqual(overlay_health["agent_pid"], ready["agent_pid"])
        self.assertEqual(overlay_health["channel_id"], ready["channel_id"])
        self.assertTrue(overlay_health["menu_bar_item_active"])
        self.assertEqual(FIXTURE_NAME, overlay_health["current_app"])
        self.assertIn(FIXTURE_NAME, overlay_health["controlled_apps"])
        self.assertTrue(overlay_health["cursor_initialized"])

        time.sleep(1.1)
        persistent_state = json.loads(state_path.read_text())
        self.assertFalse(persistent_state["controlling"])
        self.assertEqual(FIXTURE_NAME, persistent_state["current_app"])
        self.assertIn(FIXTURE_NAME, persistent_state["controlled_apps"])
        self.assertEqual(overlay_state["cursor"], persistent_state["cursor"])

    def test_overlay_agent_cleans_channel_after_owner_sigkill(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        secondary = MCPClient(SERVER_BINARY)
        channel_directory = None
        agent_pid = None
        try:
            launch_result = secondary.call_tool(
                "press_key",
                {"app": self.fixture_bundle_id, "key": "not-a-real-key"},
            )
            self.assertTrue(launch_result.get("isError"), text_content(launch_result))

            deadline = time.monotonic() + 3
            overlay_health = None
            while time.monotonic() < deadline:
                overlay_health = json.loads(
                    text_content(secondary.call_tool("health_report"))
                )["overlay"]
                if overlay_health["status"] == "running":
                    break
                time.sleep(0.05)
            self.assertIsNotNone(overlay_health)
            assert overlay_health is not None
            self.assertEqual("running", overlay_health["status"], overlay_health)
            agent_pid = overlay_health["agent_pid"]
            channel_directory = Path(overlay_health["state_file"]).parent
            self.assertTrue(channel_directory.exists(), channel_directory)

            secondary.process.kill()
            secondary.process.wait(timeout=3)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                channel_exists = channel_directory.exists()
                try:
                    os.kill(agent_pid, 0)
                    agent_exists = True
                except ProcessLookupError:
                    agent_exists = False
                if not channel_exists and not agent_exists:
                    break
                time.sleep(0.05)
            self.assertFalse(channel_directory.exists(), channel_directory)
            with self.assertRaises(ProcessLookupError):
                os.kill(agent_pid, 0)
        finally:
            secondary.close()
            if channel_directory is not None:
                shutil.rmtree(channel_directory, ignore_errors=True)

    def test_overlay_agent_relaunches_after_agent_sigkill(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        first_action = self.client.call_tool(
            "press_key",
            {"app": self.fixture_bundle_id, "key": "not-a-real-key"},
        )
        self.assertTrue(first_action.get("isError"), text_content(first_action))

        deadline = time.monotonic() + 3
        first_health = None
        while time.monotonic() < deadline:
            first_health = json.loads(
                text_content(self.client.call_tool("health_report"))
            )["overlay"]
            if first_health["status"] == "running":
                break
            time.sleep(0.05)
        self.assertIsNotNone(first_health)
        assert first_health is not None
        self.assertEqual("running", first_health["status"], first_health)
        first_agent_pid = first_health["agent_pid"]
        os.kill(first_agent_pid, signal.SIGKILL)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(first_agent_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)

        second_action = self.client.call_tool(
            "press_key",
            {"app": self.fixture_bundle_id, "key": "not-a-real-key"},
        )
        self.assertTrue(second_action.get("isError"), text_content(second_action))
        deadline = time.monotonic() + 3
        second_health = None
        while time.monotonic() < deadline:
            second_health = json.loads(
                text_content(self.client.call_tool("health_report"))
            )["overlay"]
            if second_health["status"] == "running":
                break
            time.sleep(0.05)
        self.assertIsNotNone(second_health)
        assert second_health is not None
        self.assertEqual("running", second_health["status"], second_health)
        self.assertNotEqual(first_agent_pid, second_health["agent_pid"])

    def test_unused_server_sigkill_does_not_leak_overlay_channel(self) -> None:
        secondary = MCPClient(SERVER_BINARY)
        try:
            report = json.loads(text_content(secondary.call_tool("health_report")))
            channel_directory = Path(report["overlay"]["state_file"]).parent
            self.assertEqual("not_requested", report["overlay"]["status"])
            secondary.process.kill()
            secondary.process.wait(timeout=3)
            deadline = time.monotonic() + 1.5
            while time.monotonic() < deadline and channel_directory.exists():
                time.sleep(0.05)
            self.assertFalse(channel_directory.exists(), channel_directory)
        finally:
            secondary.close()

    def test_scroll_targets_snapshot_without_moving_hardware_pointer(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        listing = text_content(
            self.client.call_tool("list_windows", {"app": self.fixture_bundle_id})
        )
        match = re.search(
            r"bounds=\(x:(-?\d+), y:(-?\d+), width:(\d+), height:(\d+)\)",
            listing,
        )
        self.assertIsNotNone(match, listing)
        assert match is not None
        x, y, width, height = map(int, match.groups())
        expected_quartz = (x + width / 2, y + height / 2)

        report = json.loads(text_content(self.client.call_tool("health_report")))
        state_path = Path(report["overlay"]["state_file"])
        pointer_before = hardware_pointer_location()
        result = self.client.call_tool(
            "scroll",
            {
                "app": self.fixture_bundle_id,
                "direction": "down",
                "pages": 0.25,
            },
        )
        pointer_after = hardware_pointer_location()
        self.assertFalse(result.get("isError"), text_content(result))
        self.assertLessEqual(abs(pointer_after[0] - pointer_before[0]), 1.0)
        self.assertLessEqual(abs(pointer_after[1] - pointer_before[1]), 1.0)

        received = self.client.call_tool(
            "verify_state",
            {
                "app": self.fixture_bundle_id,
                "text": "Background Scroll Received",
                "condition": "exists",
                "timeout_ms": 1000,
            },
        )
        self.assertFalse(received.get("isError"), text_content(received))

        overlay_state = json.loads(state_path.read_text())
        self.assertAlmostEqual(expected_quartz[0], overlay_state["cursor"][0], delta=2)
        self.assertAlmostEqual(expected_quartz[1], overlay_state["cursor"][1], delta=2)

    def test_drag_targets_snapshot_without_moving_hardware_pointer(self) -> None:
        fixture_pid = self.launch_fixture()
        self.assert_fixture_state_available(fixture_pid)
        state = self.client.call_tool("get_app_state", {"app": self.fixture_bundle_id})
        image_width, image_height = png_dimensions(state)
        start_pixel = (image_width * 0.30, image_height * 0.65)
        end_pixel = (image_width * 0.70, image_height * 0.65)

        listing = text_content(
            self.client.call_tool("list_windows", {"app": self.fixture_bundle_id})
        )
        match = re.search(
            r"bounds=\(x:(-?\d+), y:(-?\d+), width:(\d+), height:(\d+)\)",
            listing,
        )
        self.assertIsNotNone(match, listing)
        assert match is not None
        x, y, width, _ = map(int, match.groups())
        pixel_scale = image_width / width
        expected_end = (
            x + end_pixel[0] / pixel_scale,
            y + end_pixel[1] / pixel_scale,
        )

        report = json.loads(text_content(self.client.call_tool("health_report")))
        state_path = Path(report["overlay"]["state_file"])
        pointer_before = hardware_pointer_location()
        result = self.client.call_tool(
            "drag",
            {
                "app": self.fixture_bundle_id,
                "from_x": start_pixel[0],
                "from_y": start_pixel[1],
                "to_x": end_pixel[0],
                "to_y": end_pixel[1],
            },
        )
        pointer_after = hardware_pointer_location()
        self.assertFalse(result.get("isError"), text_content(result))
        self.assertLessEqual(abs(pointer_after[0] - pointer_before[0]), 1.0)
        self.assertLessEqual(abs(pointer_after[1] - pointer_before[1]), 1.0)

        received = self.client.call_tool(
            "verify_state",
            {
                "app": self.fixture_bundle_id,
                "text": "Background Drag Received",
                "condition": "exists",
                "timeout_ms": 1000,
            },
        )
        self.assertFalse(received.get("isError"), text_content(received))

        overlay_state = json.loads(state_path.read_text())
        self.assertAlmostEqual(expected_end[0], overlay_state["cursor"][0], delta=2)
        self.assertAlmostEqual(expected_end[1], overlay_state["cursor"][1], delta=2)

    def test_same_server_resolves_app_launch_and_pid_replacement(self) -> None:
        before = text_content(self.client.call_tool("list_apps"))
        self.assertNotIn(self.fixture_bundle_id, before)

        first_pid = self.launch_fixture()
        self.assertEqual([first_pid], self.listed_fixture_pids())
        self.assert_fixture_state_available(first_pid)

        self.stop_fixture(first_pid)
        after_stop = text_content(self.client.call_tool("list_apps"))
        self.assertNotIn(self.fixture_bundle_id, after_stop)

        second_pid = self.launch_fixture()
        self.assertNotEqual(first_pid, second_pid)
        self.assertEqual([second_pid], self.listed_fixture_pids())
        self.assert_fixture_state_available(second_pid)


if __name__ == "__main__":
    unittest.main()
