// SamsungTVWatcher - turns the Samsung TV back on when you touch the mouse or keyboard after the
// TV was switched off (for example with the remote, before leaving the PC).
//
// Runs in the user's session without a window. Every few seconds it asks the TV whether it is on
// (GET http://<tv>:8001/api/v2/); when there is new input and the TV has been off for a while,
// it sends Wake-on-LAN until the TV reports it is on.
//
// Compiled at install time with the C# compiler that ships with Windows (.NET Framework 4.x),
// so it is C# 5: no string interpolation, no expression-bodied members.
//
// Usage: SamsungTVWatcher.exe [path\to\config.json]   (default: config.json next to the exe)

using System;
using System.IO;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

static class Program
{
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

    const int PollSeconds = 10;          // how often the TV state is checked
    const int WakeTimeoutSeconds = 60;   // how long to keep sending Wake-on-LAN
    const int RetryPauseMinutes = 5;     // after a failed wake, wait before trying again

    static string configPath;
    static string logPath;
    static string tvIp = "";
    static byte[] tvMac;
    static int graceSeconds = 15;        // TV must be off this long before input wakes it
    static DateTime configReadAt = DateTime.MinValue;

    static int Main(string[] args)
    {
        bool first;
        using (Mutex mutex = new Mutex(true, @"Local\SamsungTV-Companion-Watcher", out first))
        {
            if (!first) return 0;   // already running in this session

            configPath = args.Length > 0 ? args[0] : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "config.json");
            string logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SamsungTV-Companion");
            Directory.CreateDirectory(logDir);
            logPath = Path.Combine(logDir, "watcher.log");

            if (!ReadConfig()) { Log("cannot read " + configPath); return 1; }
            Log("started, TV " + tvIp);
            Run();
        }
        return 0;
    }

    static void Run()
    {
        DateTime nextPoll = DateTime.MinValue;
        DateTime offSince = DateTime.MinValue;   // MinValue = TV is on (or unknown)
        DateTime pausedUntil = DateTime.MinValue;
        uint lastInput = LastInputTick();

        while (true)
        {
            Thread.Sleep(500);
            DateTime now = DateTime.UtcNow;

            if (now >= nextPoll)
            {
                if ((now - configReadAt).TotalSeconds > 60) ReadConfig();
                bool on = IsTvOn();
                if (on) offSince = DateTime.MinValue;
                else if (offSince == DateTime.MinValue) offSince = now;
                nextPoll = now.AddSeconds(PollSeconds);
            }

            uint input = LastInputTick();
            bool touched = input != lastInput;
            lastInput = input;

            if (!touched || offSince == DateTime.MinValue || now < pausedUntil) continue;
            if ((now - offSince).TotalSeconds < graceSeconds) continue;   // just turned off: let the user leave
            if (IsTvOn()) { offSince = DateTime.MinValue; continue; }

            Log("input while the TV is off - waking it");
            if (Wake()) { Log("TV on"); offSince = DateTime.MinValue; }
            else { Log("TV did not turn on, pausing " + RetryPauseMinutes + " min"); pausedUntil = DateTime.UtcNow.AddMinutes(RetryPauseMinutes); }
            nextPoll = DateTime.UtcNow.AddSeconds(PollSeconds);
            lastInput = LastInputTick();
        }
    }

    static uint LastInputTick()
    {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        return GetLastInputInfo(ref info) ? info.dwTime : 0;
    }

    static bool ReadConfig()
    {
        configReadAt = DateTime.UtcNow;
        try
        {
            string json = File.ReadAllText(configPath);
            Match ip = Regex.Match(json, "\"ip\"\\s*:\\s*\"([^\"]*)\"");
            Match mac = Regex.Match(json, "\"mac\"\\s*:\\s*\"([0-9A-Fa-f:-]{17})\"");
            Match grace = Regex.Match(json, "\"wakeOnInputGraceSeconds\"\\s*:\\s*(\\d+)");
            if (!ip.Success || !mac.Success) return false;
            tvIp = ip.Groups[1].Value;
            string[] parts = mac.Groups[1].Value.Split(':', '-');
            byte[] m = new byte[6];
            for (int i = 0; i < 6; i++) m[i] = Convert.ToByte(parts[i], 16);
            tvMac = m;
            if (grace.Success) graceSeconds = int.Parse(grace.Groups[1].Value);
            return true;
        }
        catch { return tvMac != null; }
    }

    static bool IsTvOn()
    {
        // Plain HTTP/1.0 over a socket: loading the HttpWebRequest stack costs ~10 MB of RAM.
        try
        {
            using (TcpClient tcp = new TcpClient())
            {
                IAsyncResult ar = tcp.BeginConnect(tvIp, 8001, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(1500) || !tcp.Connected) return false;
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
                if (!text.StartsWith("HTTP/1.1 200") && !text.StartsWith("HTTP/1.0 200")) return false;
                Match m = Regex.Match(text, "\"PowerState\"\\s*:\\s*\"(\\w+)\"");
                return !m.Success || m.Groups[1].Value == "on";   // models without PowerState: reachable = on
            }
        }
        catch { return false; }
        finally { Trim(); }
    }

    [DllImport("kernel32.dll")]
    static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr min, IntPtr max);

    static void Trim()
    {
        // Give idle pages back to Windows between checks; the watcher sleeps 99.9% of the time.
        SetProcessWorkingSetSize(System.Diagnostics.Process.GetCurrentProcess().Handle, (IntPtr)(-1), (IntPtr)(-1));
    }

    static bool Wake()
    {
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
                Thread.Sleep(2000);
                if (IsTvOn()) return true;
            }
        }
        return false;
    }

    static void Send(UdpClient udp, byte[] packet, string host, int port)
    {
        try { udp.Send(packet, packet.Length, host, port); } catch { }
    }

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
