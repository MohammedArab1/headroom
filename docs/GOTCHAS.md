# Gotchas

Each note says where it came from. Add field notes with the unit and the build
in the catalog, never with an identifier.

## Inherited

- A disabled persistent package can keep running until reboot. Check after the
  reboot, not before. *inherited from dumbtv*
- Some firmware re-enables packages at every boot. Note them in the profile and
  do not loop trying to disable them again. *inherited from cleanyourtv*
- Opening a factory or test app can flip a mode flag. Learn what they are from
  `dumpsys package`; do not open them. *inherited from cleanyourtv*
- `grep -q` at the end of a pipeline plus `set -o pipefail` gives false
  negatives when the reader exits early. This repo ends pipelines in
  `grep ... >/dev/null`. *inherited from cleanyourtv*
- `adb install` can hang on Android 14 waiting for an on-screen confirmation.
  `launcher/install.sh` pushes the APK and runs `pm install -r` instead.
  *inherited from cleanyourtv*
- Without a `<queries>` block, an Android 11+ launcher sees no apps. The
  manifest in `launcher/` has one. *inherited from cleanyourtv*
- Android drops the HOME preference when the set of HOME apps changes. Set HOME
  again after disabling a launcher; `stock-launcher.sh` does. *inherited from
  cleanyourtv*
- Injected key events prove less than real buttons. Confirm HOME and the
  steering-wheel keys by hand. *inherited from dumbtv*
- On Android 7 to 9, Chrome may be the WebView provider. Check
  `dumpsys webviewupdate` before disabling Chrome. *inherited from dumbtv*
- Animation scale 0.5 broke a menu on one Fire OS build. After `tune.sh`, open
  the vendor apps' menus once. *inherited from cleanyourtv*

## From field sessions

Add a line per surprise, marked **verified on <catalog id>** once that entry
exists. Keep identifiers out: no IP, MAC, serial, VIN, plate, e-mail, phone or
coordinates.

- (empty)
