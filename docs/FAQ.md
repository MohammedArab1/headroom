# FAQ

**Does it void my warranty?**
Ask the seller. Nothing is flashed, rooted or uninstalled; packages are disabled
with a supported Android command and can be enabled again. Still, a seller may
take a dim view of any change. Record what you did.

**Will a firmware update undo it?**
Sometimes. The update can re-enable packages and reset settings. Run
`scripts/drift.sh` to see what came back, then `scripts/drift.sh --fix`. The
snapshot and batch records are outside the repository and survive the update.

**Can I still use CarPlay or Android Auto?**
Yes. Keep the projection app (`com.google.android.projection.gearhead` for
Android Auto, the vendor's CarPlay app) and add it to `KEEP_APPS`. The guard on
`carplay|androidauto|projection` also refuses to disable it by default.

**Does Private DNS block YouTube ads?**
No. It blocks lookups to known tracker domains if the resolver filters them;
YouTube serves ads from the same domains as the video. It also means the
resolver sees every lookup the unit makes. `tune.sh` says so and tests the
resolver before keeping the setting.

**My unit is older than Android 8.0. Why is it refused?**
The HOME guard needs `cmd package resolve-activity --brief`,
`query-activities` and `set-home-activity`, which older shells do not have. A
guard that cannot see HOME must not run. `need_device` stops at API 26.

**Why disable instead of uninstall?**
A preloaded APK may not be restorable on older Android, and `pm uninstall` gives
no in-Settings undo. `pm disable-user` is reversible and shows as "Disabled" in
Settings > Apps.

**Why does the launcher need zero permissions?**
So it cannot read location, storage or the network, and so a mistake in the
launcher cannot leak anything. It also keeps the APK small and the startup
fast.

**Can I use the scripts without the launcher?**
Yes. `LAUNCHER=0` in `headroom.conf`, or answer No to question 13. The debloat,
tune, verify and drift halves are independent of it.

**What if ADB does not come back after a reboot?**
Use `report/manual-undo-<batch>.txt`: on the unit, Settings > Apps (show system
apps), enable each app listed, then reboot. No laptop is needed. If a car
function is broken, do that before driving.

**How do I start over?**
`scripts/restore.sh --all` re-enables every package headroom disabled, restores
the recorded tweaks and puts HOME back. It does not undo ahead-of-time
compilation (Android redoes that anyway) and does not touch packages disabled
by someone else.
