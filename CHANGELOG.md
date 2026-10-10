# Changelog

## 1.1.0 - 2026-10-10

- **Keep off**: the tested Samsung TV turned itself back on ~30 s after being switched off with the remote,
  when Windows removes the display (HDMI hot-plug). The helper now catches that and switches the TV off
  over the network, which keeps it off. Optional (`-KeepOff`). Wake-ups done by SamsungTV-Companion itself
  (boot, resume, installer test) are marked so they are not mistaken for a self-wake.
- The installer stops a running helper before its power test.
- Watcher log records TV state changes and how long each wake-up took.
- `SamsungTVWatcher.exe --off` switches the TV off and exits.
- Key presses wait 1 s after connecting and keep the connection open a little longer (the first press
  was occasionally ignored).

## 1.0.0 - 2026-10-09

First release.

- TV turns on at boot, logon and resume (scheduled task, Wake-on-LAN).
- TV turns off at shutdown (local group policy shutdown script); stays on during restart (configurable).
- Installer wizard (English / Portuguese): discovery, pairing, power test.
- Uninstaller that preserves other shutdown scripts.
- Follows the TV by MAC address when its IP changes.
- Optional wake-on-input helper: the TV turns back on when the mouse or keyboard is used after it was switched off with the remote (~2 MB RAM, compiled from source at install).
- Power-off is confirmed and retried once (Wi-Fi occasionally loses a key press).
- CLI: `On`, `Off`, `Status`, `Pair`, `Discover`.
