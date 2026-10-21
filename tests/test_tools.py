import importlib.util
import socket
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from helpers import ROOT


def load(name):
    path = ROOT / "tools" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class AdbClosedTest(unittest.TestCase):
    def setUp(self):
        self.mod = load("adb_closed")

    def test_refused_means_closed(self):
        with mock.patch("socket.create_connection", side_effect=ConnectionRefusedError):
            self.assertEqual(self.mod.main(["203.0.113.5"]), 0)

    def test_timeout_means_closed(self):
        with mock.patch("socket.create_connection", side_effect=socket.timeout):
            self.assertEqual(self.mod.main(["203.0.113.5"]), 0)

    def test_network_error_cannot_be_checked(self):
        with mock.patch("socket.create_connection", side_effect=OSError("no route")):
            self.assertEqual(self.mod.main(["203.0.113.5"]), 2)

    def test_open_connection_is_one(self):
        sock = mock.Mock()
        with mock.patch("socket.create_connection", return_value=sock) as connect:
            self.assertEqual(self.mod.main(["--port", "6000", "203.0.113.5"]), 1)
            connect.assert_called_once_with(("203.0.113.5", 6000), 5.0)
            sock.close.assert_called_once_with()


class PyadbTest(unittest.TestCase):
    def setUp(self):
        self.mod = load("pyadb")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.mod.LAST = Path(self.tmp.name) / "last"

    def test_target_defaults_to_5555(self):
        self.assertEqual(self.mod.target("203.0.113.5"), ("203.0.113.5", 5555))
        self.assertEqual(self.mod.target("203.0.113.5:6000"), ("203.0.113.5", 6000))

    def test_target_uses_last_when_serial_is_missing(self):
        self.mod.LAST.write_text("203.0.113.9:6001")
        self.assertEqual(self.mod.target(None), ("203.0.113.9", 6001))

    def test_target_without_serial_or_last_exits(self):
        with self.assertRaises(SystemExit):
            self.mod.target(None)

    def test_serverless_commands_do_not_connect(self):
        self.assertEqual(self.mod.main(["start-server"]), 0)
        self.assertEqual(self.mod.main(["mdns"]), 0)

    def test_connect_remembers_the_target(self):
        dev = mock.Mock()
        with mock.patch.object(self.mod, "connect", return_value=dev):
            self.assertEqual(self.mod.main(["connect", "203.0.113.5"]), 0)
        self.assertEqual(self.mod.LAST.read_text(), "203.0.113.5:5555")
        dev.close.assert_called_once_with()

    def test_devices_reports_the_last_target(self):
        self.mod.LAST.write_text("203.0.113.5:5555")
        dev = mock.Mock()
        with mock.patch.object(self.mod, "connect", return_value=dev):
            self.assertEqual(self.mod.main(["devices"]), 0)
        dev.close.assert_called_once_with()

    def test_unsupported_command_exits_nonzero(self):
        with mock.patch.object(self.mod, "connect", return_value=mock.Mock()):
            with self.assertRaises(SystemExit) as raised:
                self.mod.main(["-s", "203.0.113.5:5555", "bogus"])
        self.assertIn("unsupported command", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
