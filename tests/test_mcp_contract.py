#!/usr/bin/env python3
"""Permission-free MCP protocol contract checks for CI."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import tempfile
import time
import unittest

from tests.test_live_app_resolution import MCPClient, text_content


REPO_ROOT = Path(__file__).resolve().parents[1]
SERVER_BINARY = REPO_ROOT / "MacComputerUse.app/Contents/MacOS/mac-computer-use"
UNBUNDLED_BINARY = REPO_ROOT / ".build/debug/mac-computer-use"
EXPECTED_TOOLS = [
    "list_apps",
    "get_app_state",
    "get_desktop_state",
    "desktop_click",
    "desktop_press_key",
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
    "point_at",
    "annotate",
    "clear_annotations",
    "ask_user",
    "pick_element",
    "wait_for_user",
    "guide",
    "say",
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
        self.assertEqual("0.9.3", initialized["serverInfo"]["version"])

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

    def test_agent_skill_and_icon_are_packaged(self) -> None:
        resources = SERVER_BINARY.parent.parent / "Resources"
        bundled = resources / "Skills" / "mac-computer-use" / "SKILL.md"
        source = Path(__file__).resolve().parent.parent / "Skills" / "mac-computer-use" / "SKILL.md"
        self.assertEqual(source.read_bytes(), bundled.read_bytes())
        self.assertTrue((resources / "AppIcon.icns").is_file())
        self.assertTrue((resources / "Assets.car").is_file())

    def test_virtual_cursor_runtime_assets_are_packaged_at_native_scales(self) -> None:
        resource_dir = (
            SERVER_BINARY.parent.parent
            / "Resources"
            / "VirtualCursor"
        )
        expected = {
            "cursor-pointer.png": (28, 28),
            "cursor-pointer@2x.png": (56, 56),
            "cursor-pointer@3x.png": (84, 84),
            "cursor-pulse.png": (28, 28),
            "cursor-pulse@2x.png": (56, 56),
            "cursor-pulse@3x.png": (84, 84),
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
                "permissions_attributed_to",
                "service",
            },
            set(report),
        )
        self.assertEqual("stdio_mcp", report["process"]["mode"])
        self.assertEqual({"connected": False}, report["service"])
        self.assertEqual("agent", report["overlay"]["transport"])
        attributed = report["permissions_attributed_to"]
        self.assertIsInstance(attributed["pid"], int)
        self.assertIsInstance(attributed["is_self"], bool)
        self.assertIsInstance(attributed["application"], str)
        self.assertIsInstance(report["accessibility"]["trusted"], bool)
        self.assertIsInstance(report["screen_recording"]["granted"], bool)
        self.assertEqual(self.client.process.pid, report["process"]["pid"])
        self.assertTrue(report["process"]["executable"].endswith("mac-computer-use"))
        self.assertNotIn(str(Path.home()), report["process"]["executable"])
        self.assertEqual(
            "com.modestnerd.mac-computer-use", report["bundle"]["identifier"]
        )
        self.assertEqual("0.9.3", report["bundle"]["version"])
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
        self.assertEqual("allow_global_input", report["input"]["global_pointer_opt_in"])

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


class ServiceModeContractTests(unittest.TestCase):
    """The relay -> service -> worker path, in an isolated runtime directory.

    The service is started directly (not through LaunchServices) with a private
    MACCU_RUNTIME_DIR and test auto-approval, so it never touches the user's
    real service and never prompts.
    """

    def setUp(self) -> None:
        if not SERVER_BINARY.exists():
            self.fail(f"Build the bundle first: missing {SERVER_BINARY}")
        # Unix socket paths are limited to 104 bytes; the system temp dir is short.
        self.runtime = Path(tempfile.mkdtemp(prefix="maccu-"))
        self.environment = os.environ.copy()
        self.environment.pop("MACCU_DISABLE_MANAGER", None)
        self.environment.pop("MACCU_IN_PROCESS", None)
        self.environment["MACCU_RUNTIME_DIR"] = str(self.runtime)
        self.environment["MACCU_TEST_AUTO_APPROVE"] = "1"
        self.environment["MACCU_DISABLE_UPDATES"] = "1"
        # Speech completes without audio, whatever the user's preference.
        self.environment["MACCU_VOICE"] = "silent"
        self.service = self.start_service()
        self.clients: list[MCPClient] = []

    def tearDown(self) -> None:
        for client in self.clients:
            client.close()
        self.stop_service(self.service)
        shutil.rmtree(self.runtime, ignore_errors=True)

    def start_service(self) -> subprocess.Popen:
        service = subprocess.Popen(
            [str(SERVER_BINARY), "manager", "--background"],
            env=self.environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        socket_path = self.runtime / "service.sock"
        deadline = time.monotonic() + 10
        while not socket_path.exists():
            if time.monotonic() > deadline:
                service.kill()
                self.fail("service did not start listening")
            time.sleep(0.05)
        return service

    def stop_service(self, service: subprocess.Popen) -> None:
        if service.poll() is None:
            service.terminate()
            try:
                service.wait(timeout=5)
            except subprocess.TimeoutExpired:
                service.kill()
                service.wait(timeout=5)

    def connect(self) -> MCPClient:
        client = MCPClient(SERVER_BINARY, environment=self.environment)
        self.clients.append(client)
        return client

    def health(self, client: MCPClient) -> dict:
        result = client.call_tool("health_report")
        self.assertFalse(result.get("isError"), text_content(result))
        return json.loads(text_content(result))

    def test_relay_runs_tools_in_an_approved_service_worker(self) -> None:
        client = self.connect()
        self.assertEqual(
            "mac-computer-use", client.initialize_response["result"]["serverInfo"]["name"]
        )
        tools = client.request("tools/list", {})["result"]["tools"]
        self.assertEqual(EXPECTED_TOOLS, [tool["name"] for tool in tools])

        report = self.health(client)
        self.assertEqual("service_worker", report["process"]["mode"])
        self.assertNotEqual(client.process.pid, report["process"]["pid"])
        self.assertTrue(report["service"]["connected"])
        self.assertEqual("approved", report["service"]["approval"])
        self.assertEqual(self.service.pid, report["service"]["service_pid"])
        self.assertEqual("service", report["overlay"]["transport"])

        listed = client.call_tool("list_apps")
        self.assertFalse(listed.get("isError"), text_content(listed))

    def test_say_speaks_through_the_service(self) -> None:
        client = self.connect()
        self.assertTrue(self.health(client)["service"]["voice"])
        spoken = client.call_tool("say", {"text": "Opening your settings now."})
        self.assertFalse(spoken.get("isError"), text_content(spoken))
        self.assertIn("Said aloud", text_content(spoken))
        started = client.call_tool("say", {"text": "Still working.", "wait": False})
        self.assertFalse(started.get("isError"), text_content(started))
        self.assertIn("Not waiting", text_content(started))
        empty = client.call_tool("say", {"text": "   "})
        self.assertTrue(empty.get("isError"))

    def test_say_reports_that_the_user_did_not_hear_it_when_voice_is_off(self) -> None:
        self.stop_service(self.service)
        self.environment["MACCU_VOICE"] = "off"
        self.service = self.start_service()
        client = self.connect()
        self.assertFalse(self.health(client)["service"]["voice"])
        muted = client.call_tool("say", {"text": "Hello"})
        self.assertTrue(muted.get("isError"))
        self.assertTrue(text_content(muted).startswith("[voice_muted]"), text_content(muted))

    def test_worker_exits_when_its_client_disconnects(self) -> None:
        client = self.connect()
        worker = self.health(client)["process"]["pid"]
        client.close()
        self.clients.remove(client)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(worker, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        self.fail(f"worker {worker} outlived its client")

    def test_quitting_the_service_ends_every_worker(self) -> None:
        first = self.health(self.connect())["process"]["pid"]
        second = self.health(self.connect())["process"]["pid"]
        self.assertNotEqual(first, second)
        self.stop_service(self.service)
        deadline = time.monotonic() + 5
        alive = {first, second}
        while alive and time.monotonic() < deadline:
            for worker in list(alive):
                try:
                    os.kill(worker, 0)
                except ProcessLookupError:
                    alive.discard(worker)
            time.sleep(0.05)
        self.assertEqual(set(), alive)

    def test_relay_reconnects_after_the_service_restarts(self) -> None:
        client = self.connect()
        before = self.health(client)["process"]["pid"]
        self.stop_service(self.service)
        self.service = self.start_service()
        after = self.health(client)
        self.assertEqual("service_worker", after["process"]["mode"])
        self.assertNotEqual(before, after["process"]["pid"])

    def test_user_quit_keeps_automation_off_without_relaunching(self) -> None:
        client = self.connect()
        (self.runtime / "stopped-by-user").touch()
        self.stop_service(self.service)
        result = client.call_tool("list_apps")
        self.assertTrue(result.get("isError"))
        self.assertIn("[stopped_by_user]", text_content(result))
        tools = client.request("tools/list", {})["result"]["tools"]
        self.assertEqual(EXPECTED_TOOLS, [tool["name"] for tool in tools])
        self.assertFalse((self.runtime / "service.sock").exists() and self.service.poll() is None)


if __name__ == "__main__":
    unittest.main()
