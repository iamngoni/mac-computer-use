#!/usr/bin/env python3
"""Permission-free MCP protocol contract checks for CI."""

from __future__ import annotations

from pathlib import Path
import unittest

from tests.test_live_app_resolution import MCPClient, text_content


REPO_ROOT = Path(__file__).resolve().parents[1]
SERVER_BINARY = REPO_ROOT / "MacComputerUse.app/Contents/MacOS/mac-computer-use"
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
]


class MCPContractTests(unittest.TestCase):
    def setUp(self) -> None:
        if not SERVER_BINARY.exists():
            self.fail(f"Build the bundle first: missing {SERVER_BINARY}")
        self.client = MCPClient(SERVER_BINARY)

    def tearDown(self) -> None:
        self.client.close()

    def test_server_metadata_and_tools(self) -> None:
        initialized = self.client.initialize_response["result"]
        self.assertEqual("mac-computer-use", initialized["serverInfo"]["name"])
        self.assertEqual("0.5.0", initialized["serverInfo"]["version"])

        response = self.client.request("tools/list", {})
        names = [tool["name"] for tool in response["result"]["tools"]]
        self.assertEqual(EXPECTED_TOOLS, names)

    def test_unknown_tool_fails_closed(self) -> None:
        result = self.client.call_tool("cc.antonlabs.missing-tool")
        self.assertTrue(result.get("isError"), text_content(result))
        self.assertIn("Unknown tool", text_content(result))


if __name__ == "__main__":
    unittest.main()
