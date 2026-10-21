import unittest

from helpers import Run


class ConnectTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def run_connect(self, *args, state=None):
        r = Run(state=state, profile="fixture-unit")
        self.runs.append(r)
        return r, r("connect.sh", *args)

    def output(self, p):
        return p.stdout + p.stderr

    def test_plain_connect_defaults_to_5555(self):
        r, p = self.run_connect("203.0.113.5")
        self.assertEqual(p.returncode, 0, msg=self.output(p))
        self.assertIn("connected: 203.0.113.5:5555", p.stderr)
        self.assertIn("NEXT: scripts/preflight.sh", p.stderr)
        self.assertIn(["connect", "203.0.113.5:5555"], r.calls())

    def test_connection_refused_prints_one_next_step(self):
        state = {
            "connect_reply": {
                "203.0.113.5:5555": "failed to connect to '203.0.113.5:5555': Connection refused"
            }
        }
        _, p = self.run_connect("203.0.113.5", state=state)
        self.assertEqual(p.returncode, 1)
        self.assertIn("check the unit's Developer options", self.output(p))
        self.assertNotIn("preflight", self.output(p))

    def test_unauthorized_asks_a_person_to_tap_allow(self):
        state = {
            "connect_reply": {
                "203.0.113.5:5555": "failed to authenticate to 203.0.113.5:5555"
            }
        }
        _, p = self.run_connect("203.0.113.5", state=state)
        self.assertEqual(p.returncode, 1)
        self.assertIn("a person taps Allow on the unit", self.output(p))
        self.assertIn("Do not retry in a loop", self.output(p))

    def test_unauthorized_get_state_asks_a_person_to_tap_allow(self):
        _, p = self.run_connect("203.0.113.5", state={"get_state": "unauthorized"})
        self.assertEqual(p.returncode, 1)
        self.assertIn("a person taps Allow on the unit", self.output(p))
        self.assertIn("Do not retry in a loop", self.output(p))

    def test_pair_then_connect_uses_the_connect_port(self):
        r, p = self.run_connect(
            "--pair", "203.0.113.5:37123", "123456", "--port", "41234"
        )
        self.assertEqual(p.returncode, 0, msg=self.output(p))
        self.assertIn(["pair", "203.0.113.5:37123", "123456"], r.calls())
        self.assertIn(["connect", "203.0.113.5:41234"], r.calls())
        self.assertIn("connected: 203.0.113.5:41234", p.stderr)

    def test_pair_bad_code_stops_before_connect(self):
        state = {"pair_reply": {"203.0.113.5:37123": "Failed: Wrong password"}}
        r, p = self.run_connect(
            "--pair", "203.0.113.5:37123", "000000", "--port", "41234", state=state
        )
        self.assertEqual(p.returncode, 1)
        self.assertIn("check the pairing code", self.output(p))
        self.assertNotIn(["connect", "203.0.113.5:41234"], r.calls())

    def test_pair_needs_connect_port(self):
        _, p = self.run_connect("--pair", "203.0.113.5:37123", "123456")
        self.assertEqual(p.returncode, 1)
        self.assertIn("--port is required", self.output(p))

    def test_tcpip_reads_the_route_and_reconnects(self):
        r, p = self.run_connect("--tcpip")
        self.assertEqual(p.returncode, 0, msg=self.output(p))
        self.assertIn(["-s", "test-hu", "tcpip", "5555"], r.calls())
        self.assertIn(["connect", "203.0.113.5:5555"], r.calls())
        self.assertIn("does not survive a reboot", p.stderr)

    def test_unexpected_output_is_reported(self):
        state = {"connect_reply": {"203.0.113.5:5555": "mystery response"}}
        _, p = self.run_connect("203.0.113.5", state=state)
        self.assertEqual(p.returncode, 1)
        self.assertIn("unexpected adb output: mystery response", self.output(p))

    def test_dry_run_does_not_connect(self):
        r, p = self.run_connect("--dry-run", "203.0.113.5")
        self.assertEqual(p.returncode, 0)
        self.assertIn("[dry-run] adb connect 203.0.113.5:5555", p.stderr)
        self.assertEqual(r.calls(), [])


class CloseAdbTest(unittest.TestCase):
    def setUp(self):
        self.runs = []

    def tearDown(self):
        for r in self.runs:
            r.tmp.cleanup()

    def test_no_host_and_no_mdns_means_closed(self):
        r = Run(profile="fixture-unit")
        self.runs.append(r)
        p = r("close-adb.sh")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("no head unit is advertised over mDNS", p.stderr)

    def test_dry_run_prints_steps_without_probing(self):
        r = Run(profile="fixture-unit")
        self.runs.append(r)
        p = r("close-adb.sh", "--keep-pairing", "--dry-run", "203.0.113.5")
        self.assertEqual(p.returncode, 0, msg=p.stdout + p.stderr)
        self.assertIn("Keep the USB debugging authorisations", p.stderr)
        self.assertIn("would probe 203.0.113.5:5555", p.stderr)
        self.assertFalse(any(call[:2] == ["-s", "test-hu"] for call in r.calls()))


if __name__ == "__main__":
    unittest.main()
