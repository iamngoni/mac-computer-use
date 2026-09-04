#!/usr/bin/env python3
"""Unit tests for the MCP subprocess harness."""

from __future__ import annotations

import subprocess
import time
import unittest

from tests.test_live_app_resolution import MCPClient


class MCPClientHarnessTests(unittest.TestCase):
    def test_close_does_not_mask_prior_broken_pipe(self) -> None:
        client = object.__new__(MCPClient)
        client.process = subprocess.Popen(
            ["/bin/sh", "-c", "exit 0"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        client.process.wait(timeout=3)
        stdin = client.process.stdin
        self.assertIsNotNone(stdin)
        assert stdin is not None
        try:
            stdin.write("request\n")
            stdin.flush()
        except BrokenPipeError:
            pass

        client.close()


if __name__ == "__main__":
    unittest.main()
