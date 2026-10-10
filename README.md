# SamsungTV-Companion

**Turn your Samsung TV on and off together with your Windows PC.**

[Português (Brasil)](README.pt-BR.md)

Using a Samsung Smart TV as a PC monitor has an annoying gap: PC graphics cards don't support
HDMI-CEC, so the TV never follows the PC. You shut down Windows and the TV stays on showing
"No signal"; you turn the PC on and have to grab the remote.

SamsungTV-Companion fixes that with the TV's own network features. It is plain PowerShell:
no dependencies, nothing to compile and no background process.

- **PC turns on, logs on or wakes from sleep** → TV turns on (Wake-on-LAN, ~10 s)
- **PC shuts down** → TV turns off
- **PC restarts** → TV stays on (configurable)
- **Router gives the TV a new IP** → it is found again by its MAC address
- **No background process** → nothing stays running, no RAM used

It is the Samsung counterpart of what [LGTV Companion](https://github.com/JPersson77/LGTVCompanion) does for LG TVs.
Not affiliated with Samsung.

---

## Requirements

**TV:** a Samsung Smart TV running Tizen (2016 or newer). Tested on a **QN55Q70T (2020)**. Please
[report other models](../../issues) that work or don't.

Set these once on the TV:

| Setting | Value | Why |
|---|---|---|
| Settings › General › Network › Expert Settings › **Power On with Mobile** | On | keeps the network alive in standby, so Wake-on-LAN can turn the TV on |
| Settings › General › Network › Expert Settings › **IP Remote** (if present) | On | allows network remote control |
| Settings › General › External Device Manager › Device Connection Manager › **Access Notification** | First Time Only | the TV asks once to allow the PC |

A wired network connection on the TV is more reliable than Wi-Fi for Wake-on-LAN, but Wi-Fi works
(the tested TV is on Wi-Fi).

**PC:** Windows 10 or 11 (tested on Windows 11 Pro), Windows PowerShell 5.1 (built in), administrator
rights to install. PC and TV on the same local network.

## Install

1. [Download the ZIP](../../archive/refs/heads/main.zip) and extract it (or `git clone`).
2. Windows marks downloaded files as unsafe. Unblock them once: open PowerShell in the folder and run
   `Get-ChildItem -Recurse | Unblock-File`.
3. Turn the TV **on**.
4. Double-click **`Install.cmd`** and accept the administrator prompt.

The installer:

1. finds Samsung TVs on your network (pick one if there are several);
2. pairs: **choose "Allow" on the TV** when asked;
3. optionally tests: turns the TV **off and back on by itself** (about 1 minute);
4. asks whether the TV should stay on when Windows restarts;
5. installs the hooks (see [How it works](#how-it-works)).

Installer options (run from an elevated PowerShell): `src\Install.ps1 -TvAddress 192.168.1.50 -OnRestart Keep -SkipPowerTest`

## Manual control

After installing, the files are in `C:\ProgramData\SamsungTV-Companion`:

```powershell
$tv = "$env:ProgramData\SamsungTV-Companion\SamsungTV.ps1"
powershell -File $tv On        # turn on (Wake-on-LAN)
powershell -File $tv Off       # turn off
powershell -File $tv Status    # IP, power state, pairing
powershell -File $tv Discover  # list Samsung TVs on the network
```

These work great on a keyboard shortcut, a Stream Deck button or an AutoHotkey script.
Everything is logged to `C:\ProgramData\SamsungTV-Companion\SamsungTV.log`.

## How it works

| Event | Mechanism |
|---|---|
| Boot, logon, resume | Scheduled task `SamsungTV-Companion - Power On` (runs as SYSTEM) sends Wake-on-LAN packets every 2 s until the TV reports it is on |
| Shutdown | A **local group policy shutdown script**. Windows runs it while the network is still up and waits for it to finish. It sends `KEY_POWER` through the TV remote API (`wss://<tv>:8002`), only if the TV is on |
| Restart | The same shutdown script reads the shutdown type that Windows logs (event 1074) and leaves the TV on |

Technical details, including why the obvious approaches fail, are in [docs/how-it-works.md](docs/how-it-works.md).

## Troubleshooting

Check `C:\ProgramData\SamsungTV-Companion\SamsungTV.log` first.

**The TV does not turn on**
- Check that **Power On with Mobile** is on. Without it, the TV turns its network off in standby.
- Give it time: right after turning off, the TV takes 15–30 s to enter network standby.
- On Wi-Fi, the router has to forward broadcast packets to wireless clients. Most do. If yours doesn't,
  use a cable or reserve the TV's IP in the router.

**The "Allow" prompt never appears / pairing fails**
- Set **Access Notification** to *First Time Only*.
- In **Device Connection Manager › Device List**, delete or allow the PC if it is there as denied.
- Restart the TV for real: hold the remote's power button until the Samsung logo appears.

**The TV does not turn off at shutdown**
- On a PC joined to a company domain, domain policies may override local shutdown scripts.
- Windows Home has not been tested yet.

**The TV turns off when I restart**
- The restart type is read from Windows' event log in several languages. If yours is not recognised,
  please [open an issue](../../issues) with the output of
  `Get-WinEvent -FilterHashtable @{LogName='System';Id=1074} -MaxEvents 3 | % { $_.Properties[4].Value }`.

## Uninstall

Double-click **`Uninstall.cmd`**, or run `C:\ProgramData\SamsungTV-Companion\Uninstall.ps1` as
administrator. It removes the scheduled task, its own shutdown script entry (other shutdown scripts
are left untouched) and the installed files.

## Limitations and roadmap

- [ ] Turn the TV off when the PC **sleeps** (for now, use the TV's own *Auto Power Off / No Signal* setting)
- [ ] Turn the TV off when the display turns off due to inactivity
- [ ] More than one TV per PC
- [ ] Test on Windows Home and more TV models

## Security and privacy

- Everything stays on your local network: no cloud, no Samsung account, no telemetry.
- The hooks run as SYSTEM, so the install folder is writable only by Administrators and SYSTEM.
- The pairing token is stored in `config.json` in that folder.
- The TV uses a self-signed certificate on port 8002, so the certificate is not validated
  (only for the connection to the TV).

## Credits

- [LGTV Companion](https://github.com/JPersson77/LGTVCompanion): the inspiration, for LG TVs.
- [samsungtvws](https://github.com/xchwarze/samsung-tv-ws-api) and
  [samsungctl](https://github.com/kdschlosser/samsungctl): community documentation of the Samsung TV protocol.

## License

[MIT](LICENSE)
