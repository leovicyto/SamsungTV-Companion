# How it works

Notes for anyone who wants to understand, port or extend SamsungTV-Companion. Most of this was found
the hard way on a QN55Q70T (2020, Tizen 5.5), first over Wi-Fi and then over a cable.

## The TV's network interfaces

| Port | What | Used for |
|---|---|---|
| `8001` HTTP | `GET /api/v2/` returns device info as JSON | discovery, `device.PowerState` (`on` / `standby`), MAC (`wifiMac`), model |
| `8001` WS | `ws://…/api/v2/channels/samsung.remote.control` | **rejected** on 2018+ models (`ms.channel.unauthorized`) |
| `8002` WSS | `wss://…/api/v2/channels/samsung.remote.control?name=<base64>&token=<token>` | remote keys (`KEY_POWER`). Self-signed certificate |

Pairing: the first connection to `8002` makes the TV show an *Allow / Deny* prompt (if *Access
Notification* is not *Off*). On *Allow*, the first message is

```json
{"event":"ms.channel.connect","data":{"id":"…","token":"12345678", …}}
```

Sending the token on later connections skips the prompt. A key press is:

```json
{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"KEY_POWER","Option":"false","TypeOfRemote":"SendRemoteKey"}}
```

## Pitfall 1: .NET's ClientWebSocket loses the TV's first message

`System.Net.WebSockets.ClientWebSocket` (.NET Framework 4.x, the one Windows PowerShell 5.1 uses)
connects fine, reports `State = Open`, and then **never receives anything**. Looking at the raw TCP
stream shows why: the TV sends the `HTTP/1.1 101 Switching Protocols` response **and** the first
WebSocket frame in the same TCP segment, and as far as we can tell the framework's handshake reader
consumes and drops the bytes after the headers.

So the connection looks "silent" and the pairing seems to hang, as if the TV were waiting for the user to
accept a prompt that never shows up. Most people end up blaming the TV.

The fix is a minimal RFC 6455 client over `SslStream`: read the HTTP headers **byte by byte** until
`\r\n\r\n`, then parse frames yourself (server frames are unmasked; client frames must be masked).
That is about 60 lines in `SamsungTV.Core.ps1`.

## Pitfall 2: you cannot turn the TV on with KEY_POWER

With *Power On with Mobile* enabled, a TV in standby keeps Wi-Fi up and still answers
`GET :8001/api/v2/` with `"PowerState": "standby"`. It is tempting to send `KEY_POWER` again. But
in standby the TV **accepts the WebSocket connection and never answers**, so the command goes nowhere.

What works is **Wake-on-LAN**: the standard magic packet (6×`FF` + 16× MAC) to UDP 9/7. It is sent to
`255.255.255.255`, to the subnet broadcast and to the TV's last IP, and **repeated every 2 seconds**.
A single packet right after the TV entered standby was not enough in testing. Repeating it turned the
TV on in about 9 s.

Use the MAC of the interface the TV is actually using. Despite its name, `device.wifiMac` reported the
**wired** MAC when the TV was on a cable. The installer reads the MAC from the ARP table first anyway.
Wi-Fi and cable have different MACs, so moving the TV between them needs a re-install.

## What the TV does after power-off

Measured over a cable, polling every 2 s:

| Time after `KEY_POWER` | `GET :8001/api/v2/` | ping |
|---|---|---|
| 0–3 s | TV closes the WebSocket itself | yes |
| ~3–20 s | `"PowerState": "standby"` | yes |
| ~20 s on | no answer at all | no |
| Wake-on-LAN sent at 45 s | `"PowerState": "on"` 2 s later | yes |

So "off" means the TV disappears from the network completely, but its NIC still listens for the magic
packet. Over Wi-Fi the TV also reconnected later in a `standby` state.

## Wi-Fi vs cable

Over Wi-Fi each direction failed once in a handful of tests: one power-off key was accepted but ignored,
and one 90-second wake attempt got no reaction, while an identical attempt a few minutes earlier woke the
TV in 9 s. Over a cable every test worked and wake-up took ~2 s. That is why `Invoke-TvOff` confirms the
state and retries once. It waits 6 s before retrying, because `KEY_POWER` toggles: a second press while the
TV is already shutting down would turn it back on.

## Pitfall 3: running something at shutdown, reliably

A scheduled task triggered by the shutdown event (`User32` 1074) races against Windows stopping
services and the network. Sometimes it runs, sometimes it doesn't.

A **machine shutdown script** in the local group policy does not have that problem: Windows runs it
before tearing down the network, and waits for it (up to the policy timeout). It is registered by:

- `%windir%\System32\GroupPolicy\Machine\Scripts\scripts.ini` (UTF-16, hidden):
  ```ini
  [Shutdown]
  0CmdLine=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
  0Parameters=-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "...\SamsungTV.ps1" Off -OnShutdown
  ```
- `%windir%\System32\GroupPolicy\gpt.ini`: add the Scripts client-side extension
  `[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]` to
  `gPCMachineExtensionNames` and increment `Version`;
- then `gpupdate /target:computer /force`.

The installer **merges** its entry with any existing ones and the uninstaller removes only its own.

## Telling a restart from a shutdown

Inside the shutdown script there is no API that says "this is a restart". But Windows logs **event
1074 (User32)** when a shutdown starts, before the scripts run, and its 5th property is the type:
`restart` / `power off` in English, `reiniciar` / `Desligado` in Portuguese, `Neustart` in German, and
so on. It is localized, so `Test-RestartInProgress` matches the restart word in the common languages.
Anything unknown is treated as a shutdown, so in the worst case the TV turns off, which is the
behaviour you would have had anyway.

## The TV turns itself back on after the remote

Recording TV state and the Windows display device once per second while the TV was switched off:

| | Switched off with the **remote** | Switched off over the **network** (`KEY_POWER`) |
|---|---|---|
| 0–20 s | `standby`, then offline | `standby`, then offline |
| 22–35 s | Windows logs Kernel-PnP **1010**: `DISPLAY\SAM7003` removed, "absent from the bus" | display stays present |
| < 1 s later | **TV is on again** | TV stays off (90 s recorded, then woken on purpose) |

So, switched off with the remote, the TV drops the HDMI hot-plug line; Windows and the graphics driver
(AMD here) react to the display disappearing, and that activity wakes the TV. Disabling *Anynet+
(HDMI-CEC)* made no difference, and nothing else was connected to the TV. It happened in 2 of 3
remote power-offs. In the third, Windows never removed the display and the TV stayed off.

The helper's *keep off* mode polls every 2 s for 90 s after the TV goes off. If the TV comes back on and
`GetLastInputInfo` has not changed since it went off (nobody touched the PC), it sends `KEY_POWER` over
the network. That puts the TV in the standby that does not drop the hot-plug line.

Wake-ups done on purpose by SamsungTV-Companion (boot, logon, resume, the installer's power test) touch
`last-wake.txt` next to `config.json`, and the helper ignores a wake-up within 2 minutes of that file being
updated. Without that, resuming from sleep would look like the TV waking up by itself (found the hard way:
the installer's power test got switched off by a running helper). The remaining trade-off: turning the TV
on with the remote within that window, without touching the PC, looks the same, so it gets switched off.

A key sent immediately after `ms.channel.connect` was sometimes ignored: one network power-off took
17 s because the first press was lost and was retried. Waiting 1 s before sending, and keeping the
connection open 1.5 s afterwards, brought it to 5 s.

## Wake on input (optional helper)

Windows has no "mouse moved" trigger for scheduled tasks, so this part needs something running.
`src/Watcher/SamsungTVWatcher.cs` is a ~200-line C# program compiled at install time by the
`csc.exe` that ships with .NET Framework 4.x (so it is C# 5). It runs in the user's session, started by a
logon task for the Users group, and:

- polls the TV state every 10 s (plain HTTP/1.0 over a socket);
- reads `GetLastInputInfo` every 0.5 s;
- if there was new input and the TV has been off for at least `wakeOnInputGraceSeconds` (15 s), sends
  Wake-on-LAN every 2 s until the TV reports `on` (max 60 s, then pauses 5 min).

The grace period is there so that switching the TV off with the remote while your hand is still on the
mouse does not turn it straight back on.

Memory: a first version using `HttpWebRequest` had a 23 MB working set. Replacing it with a raw socket and
calling `SetProcessWorkingSetSize(-1, -1)` after each check brought the working set to about 2 MB
(private commit stays around 17 MB, mostly untouched and pageable). CPU time is about 0.05 s per minute.

## Finding the TV again

The config stores IP and MAC. If the TV does not answer at its IP, every host on the local /24 is
probed on TCP 8001 in parallel (about 2 s), and the one whose MAC matches is the TV. The new IP is
saved.
