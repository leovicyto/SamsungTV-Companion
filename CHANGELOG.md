# Changelog

## 1.0.0 - 2026-10-09

First release.

- TV turns on at boot, logon and resume (scheduled task, Wake-on-LAN).
- TV turns off at shutdown (local group policy shutdown script); stays on during restart (configurable).
- Installer wizard (English / Portuguese): discovery, pairing, power test.
- Uninstaller that preserves other shutdown scripts.
- Follows the TV by MAC address when its IP changes.
- CLI: `On`, `Off`, `Status`, `Pair`, `Discover`.
