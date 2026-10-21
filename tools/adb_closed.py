#!/usr/bin/env python3
"""Is ADB still reachable? Exit 0 when the port is closed, 1 when it is open, 2 when the
check could not run. Uses the stdlib: macOS Local Network privacy can make `nc` lie."""

import argparse
import socket
import sys


def check(host, port=5555, timeout=5.0):
    try:
        sock = socket.create_connection((host, port), timeout)
    except (ConnectionRefusedError, socket.timeout):
        return 0, f"closed: nothing is listening on {host}:{port}"
    except OSError as exc:
        return 2, f"could not check {host}:{port}: {exc}"
    sock.close()
    return 1, f"OPEN: {host}:{port} accepted a connection"


def main(argv):
    parser = argparse.ArgumentParser(
        description="Check that ADB is closed (exit 0), open (exit 1), or uncheckable (exit 2)."
    )
    parser.add_argument("host", help="the head unit's IP address")
    parser.add_argument(
        "--port", type=int, default=5555, help="TCP port to probe (default: 5555)"
    )
    parser.add_argument(
        "--timeout", type=float, default=5.0, help="seconds to wait (default: 5)"
    )
    args = parser.parse_args(argv)
    rc, message = check(args.host, args.port, args.timeout)
    print(message)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
