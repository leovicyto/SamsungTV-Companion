# How it works

Notes for anyone who wants to understand, port or extend SamsungTV-Companion. Most of this was found
the hard way on a QN55Q70T (2020, Tizen 5.5) connected over Wi-Fi.

## The TV's network interfaces

| Port | What | Used for |
|---|---|---|
| `8001` HTTP | `GET /api/v2/` returns device info as JSON | discovery, `device.PowerState` (`on` / `standby`), Wi-Fi MAC, model |
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

Use the MAC of the interface the TV is actually using. `device.wifiMac` from the API may be the Wi-Fi MAC
even when the TV is on a cable (untested), so the installer reads the MAC from the ARP table first.

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

## Finding the TV again

The config stores IP and MAC. If the TV does not answer at its IP, every host on the local /24 is
probed on TCP 8001 in parallel (about 2 s), and the one whose MAC matches is the TV. The new IP is
saved.
