#!/usr/bin/env python3
"""adb stand-in for the subset headroom uses, for macOS Local Network privacy blocking `adb`.
Legacy TCP ADB only (port 5555 style). Android 11+ Wireless debugging needs TLS pairing, which
adb-shell does not do: pair once with the real adb, run `scripts/connect.sh --tcpip`, then use this."""

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
KEYDIR, STOCK = HERE / "adbkey", Path.home() / ".android" / "adbkey"
LAST = HERE / ".pyadb-last"  # git-ignored: last host:port that connected


def signer():
    from adb_shell.auth.keygen import keygen
    from adb_shell.auth.sign_pythonrsa import PythonRSASigner

    key = (
        STOCK if STOCK.exists() and Path(f"{STOCK}.pub").exists() else KEYDIR / "adbkey"
    )
    if key != STOCK:  # never touch the user's own adb key
        KEYDIR.mkdir(mode=0o700, exist_ok=True)
        if not key.exists():
            keygen(str(key))
        os.chmod(key, 0o600)  # it is a credential (cleanyourtv #key-permissions)
    return PythonRSASigner(Path(f"{key}.pub").read_text(), key.read_text())


def target(serial):
    serial = serial or (LAST.read_text().strip() if LAST.exists() else "")
    host, _, port = serial.partition(":")
    if not host:
        sys.exit("error: no devices/emulators found")
    return host, int(port or 5555)


def connect(serial):
    from adb_shell.adb_device import AdbDeviceTcp

    host, port = target(serial)
    try:
        dev = AdbDeviceTcp(host, port, default_transport_timeout_s=30.0)
        dev.connect(rsa_keys=[signer()], auth_timeout_s=60.0)
        return dev
    except Exception as e:  # lib.sh's dev_ok recognises this wording
        sys.exit(f"error: device '{host}:{port}' not found ({e})")


def main(argv):
    serial = None
    if argv[:1] == ["-s"]:
        serial, argv = argv[1], argv[2:]
    if not argv:
        sys.exit(2)
    cmd, rest = argv[0], argv[1:]
    if cmd == "start-server":
        return 0
    if cmd == "mdns":
        return 0
    if cmd == "connect":
        dev = connect(rest[0])
        dev.close()
        LAST.write_text(rest[0] if ":" in rest[0] else rest[0] + ":5555")
        print(f"connected to {rest[0]}")
        return 0
    if cmd == "devices":
        print("List of devices attached")
        if LAST.exists():
            try:
                connect(None).close()
                print(f"{LAST.read_text().strip()}\tdevice")
            except SystemExit:
                pass
        return 0
    dev = connect(serial)
    LONG = 3600.0  # bg-dexopt-job can be silent for many minutes: both timeouts must allow it
    try:
        if cmd == "get-state":
            print("device")
        elif cmd == "shell":
            sys.stdout.write(
                dev.shell(" ".join(rest), transport_timeout_s=LONG, read_timeout_s=LONG)
                or ""
            )
        elif cmd == "push":
            dev.push(rest[0], rest[1], transport_timeout_s=600.0, read_timeout_s=600.0)
        elif cmd == "pull":
            dev.pull(rest[0], rest[1], transport_timeout_s=600.0, read_timeout_s=600.0)
        elif cmd == "install":  # one pm command per shell call (Phase 1 rule)
            apk = rest[-1]
            remote = "/data/local/tmp/headroom-install.apk"
            dev.push(apk, remote, transport_timeout_s=600.0, read_timeout_s=600.0)
            print(
                dev.shell(
                    f"pm install -r {remote}",
                    transport_timeout_s=600.0,
                    read_timeout_s=600.0,
                )
            )
            dev.shell(f"rm -f {remote}")
        elif cmd == "reboot":
            try:
                dev.shell("reboot", read_timeout_s=5.0)
            except Exception:
                pass  # the connection dies with the reboot
        else:
            sys.exit(f"pyadb: unsupported command {cmd}")
    except Exception as e:  # never let a traceback look like device output
        print(f"error: closed ({type(e).__name__}: {e})")
        return 1
    finally:
        try:
            dev.close()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
