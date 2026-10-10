# SamsungTV-Companion

**Turn your Samsung Smart TV on and off together with your Windows PC.** For anyone using a Samsung
TV (QLED, Neo QLED, The Frame, Crystal UHD… any Tizen model) as a PC monitor or for couch gaming.

[Português (Brasil)](README.pt-BR.md)

Using a Samsung Smart TV as a PC monitor has an annoying gap: PC graphics cards don't support
HDMI-CEC, so the TV never follows the PC. You shut down Windows and the TV stays on showing
"No signal"; you turn the PC on and have to grab the remote.

SamsungTV-Companion fixes that with the TV's own network features. It is plain PowerShell plus one
small optional C# helper that is compiled on your PC at install time: no dependencies and no
binaries in this repository.

- **PC turns on, logs on or wakes from sleep** → TV turns on (Wake-on-LAN, ~10 s)
- **PC shuts down** → TV turns off
- **PC restarts** → TV stays on (configurable)
- **TV switched off with the remote, you touch the mouse or keyboard** → TV turns back on (optional)
- **Router gives the TV a new IP** → it is found again by its MAC address
- **Lightweight**: the on/off hooks run only at those moments; the optional wake-on-input helper
  uses about 2 MB of RAM

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

**Use a network cable on the TV if you can.** Over Wi-Fi it works, but in testing a command was
occasionally lost (the TV ignored a power-off once, and did not wake up once). Over a cable every
test worked, and the TV woke up about 2 s after the first packet.

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
5. asks whether the TV should turn back on when you touch the mouse or keyboard after switching it off
   with the remote;
6. installs the hooks (see [How it works](#how-it-works)).

If the TV changes from Wi-Fi to cable (or the other way round), run the installer again: the TV gets a
new MAC address.

Installer options (run from an elevated PowerShell): `src\Install.ps1 -TvAddress 192.168.1.50 -OnRestart Keep -WakeOnInput Yes -SkipPowerTest`

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
| Mouse/keyboard while the TV is off (optional) | `SamsungTVWatcher.exe` runs in your session (task `SamsungTV-Companion - Wake on input`). It checks the TV every 10 s and, if the TV has been off for at least 15 s and there is new input, sends Wake-on-LAN. Uses about 2 MB of RAM and practically no CPU |

Technical details, including why the obvious approaches fail, are in [docs/how-it-works.md](docs/how-it-works.md).

## Troubleshooting

Check `C:\ProgramData\SamsungTV-Companion\SamsungTV.log` first.

**The TV does not turn on**
- Check that **Power On with Mobile** is on. Without it, the TV turns its network off in standby.
- Use a network cable. On Wi-Fi a packet is sometimes lost, and the router has to forward broadcast
  packets to wireless clients.
- Moved the TV from Wi-Fi to cable? Run the installer again: the cable has a different MAC address.

**The "Allow" prompt never appears / pairing fails**
- Set **Access Notification** to *First Time Only*.
- In **Device Connection Manager › Device List**, delete or allow the PC if it is there as denied.
- Restart the TV for real: hold the remote's power button until the Samsung logo appears.

**The TV does not turn off at shutdown**
- On a PC joined to a company domain, domain policies may override local shutdown scripts.
- Windows Home has not been tested yet.

**The TV turns back on by itself right after I switch it off with the remote**
- That is the wake-on-input helper seeing the mouse or keyboard. It waits 15 s after the TV goes off;
  raise `wakeOnInputGraceSeconds` in `config.json`, or reinstall with `-WakeOnInput No`.
- Its log is in `%LOCALAPPDATA%\SamsungTV-Companion\watcher.log`.

**The TV turns off when I restart**
- The restart type is read from Windows' event log in several languages. If yours is not recognised,
  please [open an issue](../../issues) with the output of
  `Get-WinEvent -FilterHashtable @{LogName='System';Id=1074} -MaxEvents 3 | % { $_.Properties[4].Value }`.

## Uninstall

Double-click **`Uninstall.cmd`**, or run `C:\ProgramData\SamsungTV-Companion\Uninstall.ps1` as
administrator. It removes the scheduled tasks, the wake-on-input helper, its own shutdown script entry
(other shutdown scripts are left untouched) and the installed files.

## Limitations and roadmap

- [ ] Turn the TV off when the PC **sleeps** (for now, use the TV's own *Auto Power Off / No Signal* setting)
- [ ] Turn the TV off when the display turns off due to inactivity
- [x] Turn the TV back on with the mouse/keyboard after it was switched off with the remote
- [ ] More than one TV per PC
- [ ] Test on Windows Home and more TV models

## Security and privacy

- Everything stays on your local network: no cloud, no Samsung account, no telemetry.
- The on/off hooks run as SYSTEM, so the install folder is writable only by Administrators and SYSTEM.
  The wake-on-input helper runs with your normal user rights.
- The pairing token is stored in `config.json` in that folder.
- The TV uses a self-signed certificate on port 8002, so the certificate is not validated
  (only for the connection to the TV).

## FAQ

**Why doesn't my Samsung TV turn on or off with my PC?**
TVs follow their sources through HDMI-CEC (Anynet+ on Samsung), but PC graphics cards (NVIDIA,
AMD, Intel) don't implement CEC. So the TV never learns that the PC shut down or woke up.
SamsungTV-Companion uses the network instead.

**Do I need a USB-CEC adapter, a Raspberry Pi, Home Assistant or SmartThings?**
No. It talks directly to the TV over your local network: no extra hardware, no cloud and no
Samsung account.

**Which Samsung TVs are supported?**
Smart TVs running Tizen (2016 and newer) that have *Power On with Mobile*. It has been tested on a
QN55Q70T (2020). Other models should work. Please [tell us](../../issues) either way.

**Is this LGTV Companion for Samsung?**
That is the idea: same goal, for Samsung TVs. It is a separate project with no shared code.

**Will the TV turn off when I restart Windows (for example after an update)?**
No, by default it stays on during restarts and only turns off when you shut down.

**Can I control the TV from a script, a hotkey or a Stream Deck?**
Yes, see [Manual control](#manual-control).

## Credits

- [LGTV Companion](https://github.com/JPersson77/LGTVCompanion): the inspiration, for LG TVs.
- [samsungtvws](https://github.com/xchwarze/samsung-tv-ws-api) and
  [samsungctl](https://github.com/kdschlosser/samsungctl): community documentation of the Samsung TV protocol.

## License

[MIT](LICENSE)
