# Changelog

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
