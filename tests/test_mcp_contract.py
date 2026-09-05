#!/usr/bin/env python3
"""Permission-free MCP protocol contract checks for CI."""

from __future__ import annotations

import json
import os
from pathlib import Path
import struct
import time
import unittest

from tests.test_live_app_resolution import MCPClient, text_content


REPO_ROOT = Path(__file__).resolve().parents[1]
SERVER_BINARY = REPO_ROOT / "MacComputerUse.app/Contents/MacOS/mac-computer-use"
UNBUNDLED_BINARY = REPO_ROOT / ".build/debug/mac-computer-use"
EXPECTED_TOOLS = [
    "list_apps",
    "get_app_state",
    "click",
    "type_text",
    "press_key",
    "scroll",
    "set_value",
    "drag",
    "perform_secondary_action",
    "select_text",
    "open_app",
    "navigate",
    "list_windows",
    "verify_state",
    "set_window_frame",
    "invoke_menu",
    "health_report",
]


class MCPContractTests(unittest.TestCase):
    def setUp(self) -> None:
        if not SERVER_BINARY.exists():
            self.fail(f"Build the bundle first: missing {SERVER_BINARY}")
        environment = os.environ.copy()
        environment["MACCU_DISABLE_MANAGER"] = "1"
        environment["MACCU_DISABLE_UPDATES"] = "1"
        self.client = MCPClient(SERVER_BINARY, environment=environment)

    def tearDown(self) -> None:
        self.client.close()

    def test_server_metadata_and_tools(self) -> None:
        initialized = self.client.initialize_response["result"]
        self.assertEqual("mac-computer-use", initialized["serverInfo"]["name"])
        self.assertEqual("0.7.0", initialized["serverInfo"]["version"])

        response = self.client.request("tools/list", {})
        names = [tool["name"] for tool in response["result"]["tools"]]
        self.assertEqual(EXPECTED_TOOLS, names)

    def test_unbundled_binary_reports_current_version(self) -> None:
        self.assertTrue(UNBUNDLED_BINARY.is_file(), UNBUNDLED_BINARY)
        environment = os.environ.copy()
        environment["MACCU_DISABLE_MANAGER"] = "1"
        client = MCPClient(UNBUNDLED_BINARY, environment=environment)
        try:
            initialized = client.initialize_response["result"]
            self.assertEqual("development", initialized["serverInfo"]["version"])
        finally:
            client.close()

    def test_virtual_cursor_runtime_assets_are_packaged_at_native_scales(self) -> None:
        resource_dir = (
            SERVER_BINARY.parent.parent
            / "Resources"
            / "VirtualCursor"
        )
        expected = {
            "cursor-pointer.png": (36, 36),
            "cursor-pointer@2x.png": (72, 72),
            "cursor-pointer@3x.png": (108, 108),
            "cursor-pulse.png": (36, 36),
            "cursor-pulse@2x.png": (72, 72),
            "cursor-pulse@3x.png": (108, 108),
        }
        for name, dimensions in expected.items():
            path = resource_dir / name
            self.assertTrue(path.is_file(), path)
            data = path.read_bytes()
            self.assertEqual(b"\x89PNG\r\n\x1a\n", data[:8], path)
            self.assertEqual(dimensions, struct.unpack(">II", data[16:24]), path)
        self.assertFalse((resource_dir / "cursor-pointer-master.png").exists())
        self.assertFalse((resource_dir / "cursor-pulse-master.png").exists())

    def test_unknown_tool_fails_closed(self) -> None:
        result = self.client.call_tool("cc.antonlabs.missing-tool")
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("Unknown tool", text_content(result))

    def test_list_windows_missing_app_fails_closed(self) -> None:
        response = self.client.request(
            "tools/call",
            {
                "name": "list_windows",
                "arguments": {"app": "cc.antonlabs.missing-window-app"},
            },
        )
        result = response["result"]
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("did not uniquely identify one live app", text_content(result))

    def test_health_report_is_permission_free_and_machine_readable(self) -> None:
        result = self.client.call_tool("health_report")
        self.assertFalse(result.get("isError"), text_content(result))
        report = json.loads(text_content(result))

        self.assertEqual(
            {
                "accessibility",
                "screen_recording",
                "process",
                "bundle",
                "overlay",
                "resolution",
                "input",
            },
            set(report),
        )
        self.assertIsInstance(report["accessibility"]["trusted"], bool)
        self.assertIsInstance(report["screen_recording"]["granted"], bool)
        self.assertEqual(self.client.process.pid, report["process"]["pid"])
        self.assertTrue(report["process"]["executable"].endswith("mac-computer-use"))
        self.assertNotIn(str(Path.home()), report["process"]["executable"])
        self.assertEqual(
            "com.modestnerd.mac-computer-use", report["bundle"]["identifier"]
        )
        self.assertEqual("0.7.0", report["bundle"]["version"])
        self.assertIsInstance(report["overlay"]["launch_requested"], bool)
        self.assertIsInstance(report["overlay"]["state_file_present"], bool)
        self.assertEqual("not_requested", report["overlay"]["status"])
        self.assertIsNone(report["overlay"]["agent_pid"])
        self.assertIsInstance(report["overlay"]["menu_bar_item_active"], bool)
        self.assertIsNone(report["overlay"]["current_app"])
        self.assertEqual([], report["overlay"]["controlled_apps"])
        self.assertFalse(report["overlay"]["cursor_initialized"])
        self.assertIsNone(report["overlay"]["last_error"])
        self.assertTrue(report["overlay"]["channel_id"])
        self.assertIsInstance(report["overlay"]["state_file"], str)
        self.assertIsInstance(report["overlay"]["ready_file"], str)
        self.assertNotIn(str(Path.home()), report["overlay"]["state_file"])
        self.assertGreaterEqual(report["resolution"]["running_app_count"], 0)
        self.assertGreaterEqual(report["resolution"]["app_with_window_count"], 0)
        self.assertGreaterEqual(report["resolution"]["on_screen_window_count"], 0)
        self.assertIsInstance(
            report["resolution"]["exact_ax_window_id_available"], bool
        )
        self.assertEqual("application_scoped", report["input"]["default_scope"])
        self.assertEqual("disabled", report["input"]["global_pointer_opt_in"])

    def test_overlay_ipc_paths_are_isolated_and_lazy(self) -> None:
        first_report = json.loads(text_content(self.client.call_tool("health_report")))
        first_path = Path(first_report["overlay"]["state_file"])
        self.assertFalse(first_path.parent.exists(), first_path.parent)

        environment = os.environ.copy()
        environment["MACCU_DISABLE_MANAGER"] = "1"
        second = MCPClient(SERVER_BINARY, environment=environment)
        second_report = json.loads(text_content(second.call_tool("health_report")))
        second_path = Path(second_report["overlay"]["state_file"])
        try:
            self.assertNotEqual(first_path, second_path)
            self.assertFalse(second_path.parent.exists(), second_path.parent)
        finally:
            second.close()

        self.assertFalse(second_path.parent.exists(), second_path.parent)
        self.assertFalse(first_path.parent.exists(), first_path.parent)


if __name__ == "__main__":
    unittest.main()
