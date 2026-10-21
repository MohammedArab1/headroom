#!/usr/bin/env python3
"""Fake `adb` for offline tests. State: $FAKE_ADB_STATE (JSON). Log: $FAKE_ADB_LOG (one JSON list
per call). Unknown commands exit 92, so tests notice a script doing something new."""

import json
import os
import re
import sys
from pathlib import Path

STATE = Path(os.environ["FAKE_ADB_STATE"])
S = json.loads(STATE.read_text())
with open(os.environ["FAKE_ADB_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")


def save():
    STATE.write_text(json.dumps(S))


def reply(text=""):
    if text:
        print(text)
    sys.exit(0)


args = sys.argv[1:]
if args == ["start-server"]:
    reply()
if args == ["devices"]:
    reply(
        "List of devices attached\n"
        + "\n".join(f"{d}\tdevice" for d in S.get("devices", [S["serial"]]))
    )
if args[:1] == ["mdns"]:
    reply("")
if args[:1] == ["connect"]:
    if len(args) != 2:
        sys.exit(93)
    target = args[1]
    if target in S.get("connect_reply", {}):
        reply(S["connect_reply"][target])
    if target in S.get("connect_fail", []):
        reply(f"failed to connect to '{target}': Connection refused")
    if target not in S.setdefault("serials", [S["serial"]]):
        S["serials"].append(target)
    if target not in S.setdefault("devices", [S["serial"]]):
        S["devices"].append(target)
    save()
    reply(f"connected to {target}")
if args[:1] == ["pair"]:
    if len(args) != 3:
        sys.exit(93)
    target = args[1]
    if target in S.get("pair_reply", {}):
        reply(S["pair_reply"][target])
    reply(f"Successfully paired to {target} [guid=adb-fake]")
if args[:1] == ["tcpip"]:
    reply("restarting in TCP mode port: 5555")
serials = S.get("serials", [S["serial"]])
if args[:1] != ["-s"] or len(args) < 2 or args[1] not in serials:
    sys.exit(91)
args = args[2:]
if args == ["get-state"]:
    reply(S.get("get_state", "device"))
if args[:1] == ["tcpip"]:
    reply("restarting in TCP mode port: 5555")
if args == ["reboot"]:
    S["reboots"] = S.get("reboots", 0) + 1
    for p in S.get(
        "reenable_at_boot", []
    ):  # firmware that turns packages back on at boot
        if p in S["disabled"]:
            S["disabled"].remove(p)
    save()
    reply()
if args[:1] != ["shell"]:
    sys.exit(93)
cmd = " ".join(args[1:])

if cmd in S.get("fail_on", []):  # simulate a dropped connection
    print("error: closed")
    sys.exit(1)
if cmd in S.get("canned", {}):  # exact answers for anything else
    reply(S["canned"][cmd])
m = re.fullmatch(r"getprop (\S+)", cmd)
if m:
    reply(S["props"].get(m.group(1), ""))
if cmd == "getprop":
    reply("\n".join(f"[{k}]: [{v}]" for k, v in S["props"].items()))
if cmd == "cat /proc/meminfo":
    reply(
        S.get(
            "meminfo",
            (
                "MemTotal:        1998848 kB\nMemFree:          204800 kB\n"
                "MemAvailable:     612340 kB\nBuffers:           10240 kB\nCached:           512000 kB\n"
            ),
        )
    )
if cmd == "cat /proc/cpuinfo":
    reply(
        S.get(
            "cpuinfo",
            "\n\n".join(f"processor\t: {i}\nmodel name\t: Fake CPU" for i in range(8)),
        )
        + "\n"
    )
if cmd == "df /data":
    reply(
        S.get(
            "df_data",
            (
                "Filesystem      1K-blocks     Used Available Use% Mounted on\n"
                "/dev/block/dm-0  26214400 14336000  11878400  55% /data\n"
            ),
        )
    )
if cmd == "wm size":
    reply(S.get("wm_size", "Physical size: 1280x720"))
if cmd == "wm density":
    reply(S.get("wm_density", "Physical density: 240"))
if cmd == "pm list packages -f":
    reply("\n".join(f"package:/system/app/{p}/base.apk={p}" for p in S["installed"]))
m = re.fullmatch(r"settings list (system|secure|global)", cmd)
if m:
    ns = m.group(1)
    items = S.get("settings_list", {}).get(ns)
    if items is None:
        items = [
            f"{k.split(' ', 1)[1]}={v}"
            for k, v in S.get("settings", {}).items()
            if k.startswith(ns + " ")
        ]
        if ns == "global":
            items += [
                "window_animation_scale=1.0",
                "transition_animation_scale=1.0",
                "animator_duration_scale=1.0",
            ]
    reply("\n".join(items))
if cmd == "pm list packages":
    reply("\n".join("package:" + p for p in S["installed"]))
if cmd == "pm list packages -d":
    reply("\n".join("package:" + p for p in S["installed"] if p in S["disabled"]))
if cmd == "pm list packages -3":
    reply("\n".join("package:" + p for p in S.get("third", [])))
m = re.fullmatch(r"pm path (\S+)", cmd)
if m:
    reply(
        f"package:/system/app/{m.group(1)}/base.apk"
        if m.group(1) in S["installed"]
        else ""
    )
m = re.fullmatch(r"pm disable-user --user 0 (\S+)", cmd)
if m:
    p = m.group(1)
    if p in S.get("refuse", []):
        reply(
            f"Error: java.lang.SecurityException: Cannot disable a protected package: {p}"
        )
    if p not in S["disabled"]:
        S["disabled"].append(p)
    save()
    reply(f"Package {p} new state: disabled-user")
m = re.fullmatch(r"pm enable --user 0 (\S+)", cmd)
if m:
    S["disabled"] = [d for d in S["disabled"] if d != m.group(1)]
    save()
    reply(f"Package {m.group(1)} new state: enabled")
m = re.fullmatch(r"dumpsys package (\S+)", cmd)
if m:
    default = (
        f"Packages:\n  Package [{m.group(1)}] (abc):\n    userId=10123\n"
        "    pkgFlags=[ SYSTEM HAS_CODE ALLOW_CLEAR_USER_DATA ]\n"
        "    requested permissions:\n      android.permission.INTERNET\n"
    )
    reply(S.get("dumpsys", {}).get(m.group(1), default))
m = re.fullmatch(r"settings get (\w+) (\S+)", cmd)
if m:
    reply(S.get("settings", {}).get(f"{m.group(1)} {m.group(2)}", "null"))
m = re.fullmatch(r"settings put (\w+) (\S+) (.+)", cmd)
if m:
    S.setdefault("settings", {})[f"{m.group(1)} {m.group(2)}"] = m.group(3)
    save()
    reply()
if cmd.startswith("cmd package resolve-activity --brief") and "category.HOME" in cmd:
    reply("priority=0 preferredOrder=0 match=0x108000\n" + S["home"])
if cmd.startswith("cmd package query-activities --brief") and "category.HOME" in cmd:
    reply("\n".join("  " + c for c in S.get("home_claims", [S["home"]])))
if cmd == "dumpsys device_policy":
    reply(S.get("device_policy", ""))
if cmd == "ip route":
    reply(
        S.get(
            "ip_route",
            "default via 203.0.113.1 dev wlan0 proto static scope link src 203.0.113.5",
        )
    )
if cmd == "dumpsys activity activities":
    reply(f"  mResumedActivity: ActivityRecord{{1 u0 {S['home']} t1}}")

print("unexpected command: " + cmd, file=sys.stderr)
sys.exit(92)
