#!/usr/bin/env python3
"""Regression test for stale NSWorkspace app resolution.

The MCP process takes one running-app snapshot, then a temporary GUI app is
launched. The same MCP process must discover that newly launched app without
being restarted or requiring an unrelated open_app call.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SERVER_BINARY = REPO_ROOT / "MacComputerUse.app/Contents/MacOS/mac-computer-use"
SERVER_BINARY = Path(os.environ.get("MACCU_BINARY", DEFAULT_SERVER_BINARY))
FIXTURE_BUNDLE_ID = "cc.antonlabs.maccu-live-app-fixture"
FIXTURE_NAME = "MaccuLiveAppFixture"

FIXTURE_SOURCE = r"""
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 320, height: 180),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
window.title = "Mac Computer Use Live App Fixture"
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
"""

INFO_PLIST = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>{FIXTURE_NAME}</string>
  <key>CFBundleDisplayName</key><string>{FIXTURE_NAME}</string>
  <key>CFBundleIdentifier</key><string>{FIXTURE_BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>{FIXTURE_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><false/>
</dict>
</plist>
"""


class MCPClient:
    def __init__(self, binary: Path) -> None:
        self.process = subprocess.Popen(
            [str(binary)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self._next_id = 1
        self.request("initialize", {})

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
            self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=3)
        if self.process.stdout is not None:
            self.process.stdout.close()


def text_content(result: dict) -> str:
    return "\n".join(
        block.get("text", "")
        for block in result.get("content", [])
        if block.get("type") == "text"
    )


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
        subprocess.run(
            ["pkill", "-f", "/MaccuLiveAppFixture.app/Contents/MacOS/MaccuLiveAppFixture"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.temp_dir = Path(tempfile.mkdtemp(prefix="maccu-live-app-test-"))
        self.bundle = self.temp_dir / f"{FIXTURE_NAME}.app"
        self.executable = self.bundle / f"Contents/MacOS/{FIXTURE_NAME}"
        self.executable.parent.mkdir(parents=True)
        source = self.temp_dir / "Fixture.swift"
        source.write_text(FIXTURE_SOURCE)
        (self.bundle / "Contents/Info.plist").write_text(INFO_PLIST)
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

    def launch_fixture(self) -> int:
        subprocess.run(["open", "-na", str(self.bundle)], check=True)
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
        matches = re.findall(rf"\[{re.escape(FIXTURE_BUNDLE_ID)}\] pid=(\d+)", listing)
        self.assertTrue(matches, "long-lived MCP process returned a stale app snapshot")
        return [int(pid) for pid in matches]

    def assert_fixture_state_available(self, expected_pid: int) -> None:
        deadline = time.monotonic() + 5
        last_state: dict = {}
        while time.monotonic() < deadline:
            last_state = self.client.call_tool("get_app_state", {"app": FIXTURE_BUNDLE_ID})
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

    def test_same_server_resolves_app_launch_and_pid_replacement(self) -> None:
        before = text_content(self.client.call_tool("list_apps"))
        self.assertNotIn(FIXTURE_BUNDLE_ID, before)

        first_pid = self.launch_fixture()
        self.assertEqual([first_pid], self.listed_fixture_pids())
        self.assert_fixture_state_available(first_pid)

        self.stop_fixture(first_pid)
        after_stop = text_content(self.client.call_tool("list_apps"))
        self.assertNotIn(FIXTURE_BUNDLE_ID, after_stop)

        second_pid = self.launch_fixture()
        self.assertNotEqual(first_pid, second_pid)
        self.assertEqual([second_pid], self.listed_fixture_pids())
        self.assert_fixture_state_available(second_pid)


if __name__ == "__main__":
    unittest.main()
