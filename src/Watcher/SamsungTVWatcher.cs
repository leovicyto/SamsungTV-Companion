// SamsungTVWatcher - runs in the user's session without a window and does two things:
//
// 1. Keep the TV off. Switched off with the REMOTE, a Samsung TV drops the HDMI hot-plug line about
//    20-35 s later; Windows removes the display, the graphics driver reacts, and that wakes the TV up
//    again. Switched off over the NETWORK, the TV does not do that. So if the TV comes back on by
//    itself shortly after going off, and nobody touched the PC meanwhile, the watcher switches it off
//    again over the network and it stays off.
//
// 2. Wake on input. When the mouse or keyboard is used while the TV is off, it sends Wake-on-LAN
//    until the TV reports it is on.
//
// The TV state comes from GET http://<tv>:8001/api/v2/ ("on", "standby", or no answer = "offline").
// Power-off is KEY_POWER over the TV remote-control WebSocket (wss://<tv>:8002), with the pairing
// token from config.json.
//
// Compiled at install time with the C# compiler that ships with Windows (.NET Framework 4.x),
// so it is C# 5: no string interpolation, no expression-bodied members.
//
// Usage: SamsungTVWatcher.exe [path\to\config.json]   (default: config.json next to the exe)

using System;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

static class Program
{
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

    [DllImport("kernel32.dll")]
    static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr min, IntPtr max);

    const int PollSeconds = 10;          // TV state check interval
    const int FastPollSeconds = 2;       // ...right after the TV went off, to catch a self-wake quickly
    const int SelfWakeWindowSeconds = 90;
    const int WakeTimeoutSeconds = 60;   // how long to keep sending Wake-on-LAN
    const int RetryPauseMinutes = 5;     // after a failed wake, wait before trying again

    static string configPath;
    static string logPath;
    static string tvIp = "";
    static byte[] tvMac;
    static string clientName = "SamsungTV-Companion";
    static string token = "";
    static int graceSeconds = 15;        // TV must be off this long before input wakes it
    static bool wakeOnInput = true;
    static bool keepOff = true;
    static DateTime configReadAt = DateTime.MinValue;

    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--off")
        {
            // One-shot: switch the TV off over the network and exit (also handy for a hotkey).
            configPath = args.Length > 1 ? args[1] : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "config.json");
            logPath = Path.Combine(Path.GetTempPath(), "SamsungTVWatcher-off.log");
            if (!ReadConfig()) return 1;
            return PowerOff() ? 0 : 2;
        }

        bool first;
        using (Mutex mutex = new Mutex(true, @"Local\SamsungTV-Companion-Watcher", out first))
        {
            if (!first) return 0;   // already running in this session

            configPath = args.Length > 0 ? args[0] : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "config.json");
            string logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SamsungTV-Companion");
            Directory.CreateDirectory(logDir);
            logPath = Path.Combine(logDir, "watcher.log");

            if (!ReadConfig()) { Log("cannot read " + configPath); return 1; }
            Log("started, TV " + tvIp + " (wake on input: " + wakeOnInput + ", keep off: " + keepOff + ")");
            Run();
        }
        return 0;
    }

    static void Run()
    {
        DateTime nextPoll = DateTime.MinValue;
        DateTime offSince = DateTime.MinValue;   // MinValue = TV is on (or unknown)
        DateTime pausedUntil = DateTime.MinValue;
        string lastState = "";
        bool graceLogged = false;
        uint lastInput = LastInputTick();
        uint inputWhenOff = 0;                   // input tick when the TV went off
        bool keptOff = false;                    // already switched it off again in this cycle

        while (true)
        {
            Thread.Sleep(500);
            DateTime now = DateTime.UtcNow;

            if (now >= nextPoll)
            {
                if ((now - configReadAt).TotalSeconds > 60) ReadConfig();
                string state = TvState();
                if (state != lastState) Log("TV state: " + state);

                if (state == "on")
                {
                    bool selfWake = keepOff && !keptOff && offSince != DateTime.MinValue &&
                                    (now - offSince).TotalSeconds < SelfWakeWindowSeconds &&
                                    LastInputTick() == inputWhenOff && !DeliberateWakeRecently();
                    if (selfWake)
                    {
                        Log("TV came back on by itself " + (int)(now - offSince).TotalSeconds + " s after going off - switching it off over the network");
                        keptOff = true;
                        Log(PowerOff() ? "TV off (network standby, it should stay off now)" : "could not switch the TV off");
                        state = TvState();
                    }
                    else
                    {
                        offSince = DateTime.MinValue;
                        graceLogged = false;
                        keptOff = false;
                    }
                }
                else if (offSince == DateTime.MinValue)
                {
                    offSince = now;
                    inputWhenOff = LastInputTick();
                }

                lastState = state;
                bool recentlyOff = offSince != DateTime.MinValue && (now - offSince).TotalSeconds < SelfWakeWindowSeconds;
                nextPoll = DateTime.UtcNow.AddSeconds(recentlyOff && keepOff && !keptOff ? FastPollSeconds : PollSeconds);
            }

            uint input = LastInputTick();
            bool touched = input != lastInput;
            lastInput = input;

            if (!wakeOnInput || !touched || offSince == DateTime.MinValue || now < pausedUntil) continue;
            if ((now - offSince).TotalSeconds < graceSeconds)
            {
                // just turned off: let the user leave
                if (!graceLogged) { Log("input ignored, TV off for less than " + graceSeconds + " s"); graceLogged = true; }
                continue;
            }
            if (TvState() == "on") { offSince = DateTime.MinValue; continue; }

            Log("input while the TV is off - sending Wake-on-LAN");
            DateTime started = DateTime.UtcNow;
            int bursts;
            bool woke = Wake(out bursts);
            string took = ((int)(DateTime.UtcNow - started).TotalSeconds) + " s, " + bursts + " packet bursts";
            if (woke) { Log("TV on after " + took); lastState = "on"; offSince = DateTime.MinValue; graceLogged = false; keptOff = false; }
            else { Log("TV did not turn on after " + took + ", pausing " + RetryPauseMinutes + " min"); pausedUntil = DateTime.UtcNow.AddMinutes(RetryPauseMinutes); }
            nextPoll = DateTime.UtcNow.AddSeconds(PollSeconds);
            lastInput = LastInputTick();
        }
    }

    static bool DeliberateWakeRecently()
    {
        // SamsungTV.ps1 / the installer touch this file whenever they turn the TV on on purpose
        // (boot, logon, resume, power test), so that is not mistaken for the TV waking up by itself.
        try
        {
            string marker = Path.Combine(Path.GetDirectoryName(configPath), "last-wake.txt");
            return File.Exists(marker) && (DateTime.UtcNow - File.GetLastWriteTimeUtc(marker)).TotalSeconds < 120;
        }
        catch { return false; }
    }

    static uint LastInputTick()
    {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        return GetLastInputInfo(ref info) ? info.dwTime : 0;
    }

    // ------------------------------------------------------------------ config

    static bool ReadConfig()
    {
        configReadAt = DateTime.UtcNow;
        try
        {
            string json = File.ReadAllText(configPath);
            Match ip = Regex.Match(json, "\"ip\"\\s*:\\s*\"([^\"]*)\"");
            Match mac = Regex.Match(json, "\"mac\"\\s*:\\s*\"([0-9A-Fa-f:-]{17})\"");
            if (!ip.Success || !mac.Success) return false;
            tvIp = ip.Groups[1].Value;
            string[] parts = mac.Groups[1].Value.Split(':', '-');
            byte[] m = new byte[6];
            for (int i = 0; i < 6; i++) m[i] = Convert.ToByte(parts[i], 16);
            tvMac = m;

            Match name = Regex.Match(json, "\"name\"\\s*:\\s*\"([^\"]*)\"");
            Match tok = Regex.Match(json, "\"token\"\\s*:\\s*\"([^\"]*)\"");
            Match grace = Regex.Match(json, "\"wakeOnInputGraceSeconds\"\\s*:\\s*(\\d+)");
            Match wake = Regex.Match(json, "\"wakeOnInput\"\\s*:\\s*(true|false)");
            Match keep = Regex.Match(json, "\"keepOffAfterRemote\"\\s*:\\s*(true|false)");
            if (name.Success) clientName = name.Groups[1].Value;
            if (tok.Success) token = tok.Groups[1].Value;
            if (grace.Success) graceSeconds = int.Parse(grace.Groups[1].Value);
            if (wake.Success) wakeOnInput = wake.Groups[1].Value == "true";
            if (keep.Success) keepOff = keep.Groups[1].Value == "true";
            return true;
        }
        catch { return tvMac != null; }
    }

    // ------------------------------------------------------------------ TV state

    // "on", "standby" (TV answers but the screen is off) or "offline" (no answer at all)
    static string TvState()
    {
        // Plain HTTP/1.0 over a socket: loading the HttpWebRequest stack costs ~10 MB of RAM.
        try
        {
            using (TcpClient tcp = new TcpClient())
            {
                IAsyncResult ar = tcp.BeginConnect(tvIp, 8001, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(1500) || !tcp.Connected) return "offline";
                tcp.EndConnect(ar);
                tcp.ReceiveTimeout = 1500;
                NetworkStream s = tcp.GetStream();
                byte[] req = Encoding.ASCII.GetBytes("GET /api/v2/ HTTP/1.0\r\nHost: " + tvIp + "\r\n\r\n");
                s.Write(req, 0, req.Length);
                MemoryStream body = new MemoryStream();
                byte[] buf = new byte[4096];
                int n;
                while ((n = s.Read(buf, 0, buf.Length)) > 0) body.Write(buf, 0, n);
                string text = Encoding.UTF8.GetString(body.ToArray());
                if (!text.StartsWith("HTTP/1.1 200") && !text.StartsWith("HTTP/1.0 200")) return "offline";
                Match m = Regex.Match(text, "\"PowerState\"\\s*:\\s*\"(\\w+)\"");
                return m.Success ? m.Groups[1].Value : "on";   // models without PowerState: reachable = on
            }
        }
        catch { return "offline"; }
        finally { Trim(); }
    }

    static void Trim()
    {
        // Give idle pages back to Windows between checks; the watcher sleeps 99.9% of the time.
        SetProcessWorkingSetSize(System.Diagnostics.Process.GetCurrentProcess().Handle, (IntPtr)(-1), (IntPtr)(-1));
    }

    // ------------------------------------------------------------------ power on (Wake-on-LAN)

    static bool Wake(out int bursts)
    {
        bursts = 0;
        byte[] packet = new byte[102];
        for (int i = 0; i < 6; i++) packet[i] = 0xFF;
        for (int i = 6; i < 102; i++) packet[i] = tvMac[(i - 6) % 6];

        string subnetBroadcast = null;
        string[] o = tvIp.Split('.');
        if (o.Length == 4) subnetBroadcast = o[0] + "." + o[1] + "." + o[2] + ".255";

        DateTime until = DateTime.UtcNow.AddSeconds(WakeTimeoutSeconds);
        using (UdpClient udp = new UdpClient())
        {
            udp.EnableBroadcast = true;
            while (DateTime.UtcNow < until)
            {
                foreach (int port in new int[] { 9, 7 })
                {
                    Send(udp, packet, "255.255.255.255", port);
                    if (subnetBroadcast != null) Send(udp, packet, subnetBroadcast, port);
                    Send(udp, packet, tvIp, port);
                }
                bursts++;
                Thread.Sleep(2000);
                if (TvState() == "on") return true;
            }
        }
        return false;
    }

    static void Send(UdpClient udp, byte[] packet, string host, int port)
    {
        try { udp.Send(packet, packet.Length, host, port); } catch { }
    }

    // ------------------------------------------------------------------ power off (KEY_POWER)

    static bool PowerOff()
    {
        // Right after waking up the TV may take a few seconds to accept remote connections.
        DateTime until = DateTime.UtcNow.AddSeconds(20);
        while (DateTime.UtcNow < until)
        {
            if (TvState() != "on") return true;
            if (SendKey("KEY_POWER"))
            {
                for (int i = 0; i < 6; i++)
                {
                    Thread.Sleep(1000);
                    if (TvState() != "on") return true;
                }
            }
            else Thread.Sleep(2000);
        }
        return false;
    }

    static bool AcceptAnyCertificate(object sender, System.Security.Cryptography.X509Certificates.X509Certificate cert,
                                     System.Security.Cryptography.X509Certificates.X509Chain chain, SslPolicyErrors errors)
    {
        return true;   // the TV uses a self-signed certificate on port 8002
    }

    static bool SendKey(string key)
    {
        // Minimal WebSocket client: .NET Framework's ClientWebSocket loses the TV's first frame.
        try
        {
            using (TcpClient tcp = new TcpClient())
            {
                IAsyncResult ar = tcp.BeginConnect(tvIp, 8002, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(3000) || !tcp.Connected) return false;
                tcp.EndConnect(ar);
                tcp.ReceiveTimeout = 5000;
                using (SslStream ssl = new SslStream(tcp.GetStream(), false, AcceptAnyCertificate))
                {
                    ssl.AuthenticateAsClient(tvIp, null, SslProtocols.Tls12, false);

                    string path = "/api/v2/channels/samsung.remote.control?name=" + Convert.ToBase64String(Encoding.UTF8.GetBytes(clientName));
                    if (token.Length > 0) path += "&token=" + token;
                    string req = "GET " + path + " HTTP/1.1\r\nHost: " + tvIp + ":8002\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                                 "Sec-WebSocket-Key: " + Convert.ToBase64String(Guid.NewGuid().ToByteArray()) + "\r\nSec-WebSocket-Version: 13\r\n\r\n";
                    byte[] b = Encoding.ASCII.GetBytes(req);
                    ssl.Write(b, 0, b.Length);

                    // HTTP headers byte by byte, so the first WebSocket frame is not swallowed
                    StringBuilder hdr = new StringBuilder();
                    while (!hdr.ToString().EndsWith("\r\n\r\n"))
                    {
                        int c = ssl.ReadByte();
                        if (c < 0) return false;
                        hdr.Append((char)c);
                    }
                    if (!hdr.ToString().StartsWith("HTTP/1.1 101")) return false;

                    // wait for ms.channel.connect
                    for (int i = 0; i < 5; i++)
                    {
                        string msg = ReadFrame(ssl);
                        if (msg == null) return false;
                        if (msg.Contains("ms.channel.unauthorized")) { Log("TV refused the connection (pairing token?)"); return false; }
                        if (msg.Contains("ms.channel.connect")) break;
                        if (i == 4) return false;
                    }

                    // A key sent right after "connect" is sometimes ignored; give the TV a moment,
                    // and keep the connection open a little after sending.
                    Thread.Sleep(1000);
                    string cmd = "{\"method\":\"ms.remote.control\",\"params\":{\"Cmd\":\"Click\",\"DataOfCmd\":\"" + key +
                                 "\",\"Option\":\"false\",\"TypeOfRemote\":\"SendRemoteKey\"}}";
                    WriteFrame(ssl, Encoding.UTF8.GetBytes(cmd), 1);
                    Thread.Sleep(1500);
                    try { WriteFrame(ssl, new byte[] { 0x03, 0xE8 }, 8); } catch { }
                    return true;
                }
            }
        }
        catch { return false; }
        finally { Trim(); }
    }

    static string ReadFrame(Stream s)
    {
        byte[] h = ReadExact(s, 2);
        if (h == null) return null;
        long len = h[1] & 0x7F;
        if (len == 126) { byte[] e = ReadExact(s, 2); if (e == null) return null; len = (e[0] << 8) | e[1]; }
        else if (len == 127) { byte[] e = ReadExact(s, 8); if (e == null) return null; len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | e[i]; }
        byte[] data = len > 0 ? ReadExact(s, (int)len) : new byte[0];
        if (data == null) return null;
        return Encoding.UTF8.GetString(data);
    }

    static byte[] ReadExact(Stream s, int count)
    {
        byte[] buf = new byte[count];
        int read = 0;
        while (read < count)
        {
            int n = s.Read(buf, read, count - read);
            if (n <= 0) return null;
            read += n;
        }
        return buf;
    }

    static void WriteFrame(Stream s, byte[] data, int opcode)
    {
        MemoryStream f = new MemoryStream();
        f.WriteByte((byte)(0x80 | opcode));
        if (data.Length < 126) f.WriteByte((byte)(0x80 | data.Length));
        else { f.WriteByte(0x80 | 126); f.WriteByte((byte)(data.Length >> 8)); f.WriteByte((byte)(data.Length & 0xFF)); }
        byte[] mask = Guid.NewGuid().ToByteArray();
        f.Write(mask, 0, 4);
        for (int i = 0; i < data.Length; i++) f.WriteByte((byte)(data[i] ^ mask[i % 4]));
        byte[] a = f.ToArray();
        s.Write(a, 0, a.Length);
        s.Flush();
    }

    // ------------------------------------------------------------------ log

    static void Log(string message)
    {
        try
        {
            FileInfo f = new FileInfo(logPath);
            if (f.Exists && f.Length > 200000) f.Delete();
            File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine);
        }
        catch { }
    }
}
