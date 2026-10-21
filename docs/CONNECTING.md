# Connecting to the head unit

Everything here is done with the car **parked and the parking brake on**. Run the
engine only outdoors, or connect a battery charger or maintainer instead.

## 1. Network

1. Turn on your phone's hotspot.
2. Join it from the head unit (Settings > Wi-Fi) and from the laptop.
3. Some phone hotspots isolate clients: the laptop can see the internet but not
   the head unit. If so, turn off client isolation in the hotspot settings, or
   use a small travel router.

## 2. Enable debugging on the unit

1. Settings > About (sometimes System > About) and tap **Build number** seven times.
2. Open Developer options.

**Android 11 or later (Wireless debugging)**

- Turn on **Wireless debugging**.
- Tap **Pair device with pairing code**. Note the `<pair-port>` and the code.
- Note the **connect port** shown on the Wireless debugging screen. It is a
  different number from the pairing port.

**Older units (TCP on 5555)**

- Turn on **USB debugging**.
- Some units also have **ADB over network** or **Network debugging**. That
  survives reboots; plain `adb tcpip 5555` does not.

If Developer options is missing or locked, it may be behind the vendor's factory
menu. Do **not** change anything else there (the project's rule 4). Write down
the path in the catalog entry; do not go looking for passwords.

## 3. Find the unit's IP

Settings > About > Status, the Wi-Fi network details, or the hotspot's list of
connected devices. Never commit a real address to this repository.

## 4. Connect

```sh
scripts/connect.sh <hu-ip>                         # legacy TCP, port 5555
scripts/connect.sh --pair <hu-ip>:<pair-port> <code> --port <connect-port>
scripts/connect.sh --tcpip                         # open 5555 after pairing
```

`scripts/connect.sh` never scans the network. It prints exactly one next step
for each outcome:

| Outcome | What it means | Next step |
|---|---|---|
| connected | the unit answers `get-state` as `device` | `scripts/preflight.sh` |
| unauthorized | the unit is showing "Allow USB debugging?" | a person taps Allow and ticks Always allow. Do not retry in a loop |
| No route to host | macOS Local Network privacy may be blocking `adb` | allow your terminal under System Settings > Privacy & Security > Local Network, run `adb kill-server`, retry |
| Connection refused | debugging is off, or the port is wrong | check Developer options; Android 11+ needs `--pair` |
| timeout | wrong IP, or the hotspot isolates clients | check the IP and the hotspot |

If `adb` itself cannot work but the unit offers plain TCP ADB on port 5555, use
the stand-in:

```sh
python3 -m venv tools/venv
tools/venv/bin/pip install -r tools/requirements.txt
export ADB="$PWD/tools/pyadb"
```

`tools/pyadb` speaks legacy TCP ADB only. It cannot do Android 11 TLS pairing:
pair once with the real `adb`, run `scripts/connect.sh --tcpip`, then use it.

## 5. Every reboot

Wireless debugging often turns itself off at boot, and its port changes. After
each reboot:

1. Re-enable Wireless debugging on the unit if needed. The pairing is
   remembered, so no new code is required.
2. Run `scripts/connect.sh --pair <hu-ip>:<pair-port> <code> --port <connect-port>`
   only if the unit asks for a new code; otherwise use the plain form with the
   current connect port.

Units with a persistent network-ADB toggle on 5555 are the easy case. Find out
which kind yours is during the reboot drill in Field Session A.

## 6. Closing the session

Leaving ADB open in a car gives anyone on the same network a shell. At the end
of every session:

```sh
scripts/close-adb.sh <hu-ip>
```

A person turns Wireless debugging and USB debugging off on the unit, optionally
taps **Revoke USB debugging authorisations**, and reboots. The script then
probes port 5555 with the stdlib (macOS `nc` can lie because of Local Network
privacy) and exits 0 only when the port is closed. Wireless debugging's random
port cannot be probed this way; check instead that `adb mdns services` no longer
lists the unit.
