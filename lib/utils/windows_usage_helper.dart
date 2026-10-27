/// The elevated helper IRNet runs on Windows to see per-app traffic.
///
/// Windows reports per-process network bytes only through kernel event
/// tracing (ETW), which needs administrator rights. The helper is a
/// PowerShell script that compiles a small C# ETW consumer (C# 5, as built
/// into Windows PowerShell 5.1), listens to the Microsoft-Windows-Kernel-
/// Network provider and every few seconds drops a JSON sample file:
///
///     {"t": <epoch ms>, "flows": [{"pid": 1234, "name": "Google Chrome",
///       "exe": "C:\\...\\chrome.exe", "ip": "1.2.3.4", "port": 443,
///       "iface": "Wi-Fi", "kind": "physical", "rx": 100, "tx": 20}]}
///
/// It writes `ready` once tracing runs, `error.txt` if it can't, and exits
/// (stopping the trace session) when IRNet exits or a `stop` file appears.
library;

const windowsHelperScript = r"""
param([int]$ParentPid, [string]$OutDir)
$ErrorActionPreference = 'Stop'
try {
    if (-not ('IrNetEtw' -as [type])) {
        Add-Type -TypeDefinition @'
__CSHARP__
'@
    }
    [IrNetEtw]::Run($ParentPid, $OutDir)
} catch {
    try { [IO.File]::WriteAllText((Join-Path $OutDir 'error.txt'), $_.Exception.Message) } catch {}
    exit 1
}
""";

/// C# 5 (no interpolation, `?.`, expression bodies…): what Windows
/// PowerShell 5.1's Add-Type compiles. Struct layouts are written as raw
/// x64 offsets, documented next to each access.
const windowsHelperCSharp = r'''
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class IrNetEtw
{
    const string SessionName = "IRNet-Usage";
    const int WNODE_FLAG_TRACED_GUID = 0x00020000;
    const int EVENT_TRACE_REAL_TIME_MODE = 0x00000100;
    const int PROCESS_TRACE_MODE_REAL_TIME = 0x00000100;
    const int PROCESS_TRACE_MODE_EVENT_RECORD = 0x10000000;
    const uint EVENT_TRACE_CONTROL_STOP = 1;
    const uint EVENT_CONTROL_CODE_ENABLE_PROVIDER = 1;
    const byte TRACE_LEVEL_INFORMATION = 4;
    const ulong KEYWORD_IPV4_AND_IPV6 = 0x30;

    // EVENT_TRACE_PROPERTIES is 120 bytes on x64; the logger name follows it.
    const int PropertiesSize = 120;
    const int PropertiesBufferSize = PropertiesSize + 1024;
    // EVENT_TRACE_LOGFILEW is 448 bytes on x64.
    const int LogFileSize = 512;

    static readonly Guid KernelNetwork = new Guid("7DD42A49-5329-4832-8DFD-43D979153A88");

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern uint StartTraceW(out ulong handle, string name, IntPtr properties);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern uint ControlTraceW(ulong handle, string name, IntPtr properties, uint code);

    [DllImport("advapi32.dll")]
    static extern uint EnableTraceEx2(ulong handle, ref Guid provider, uint code, byte level,
        ulong matchAnyKeyword, ulong matchAllKeyword, uint timeout, IntPtr parameters);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern ulong OpenTraceW(IntPtr logFile);

    [DllImport("advapi32.dll")]
    static extern uint ProcessTrace(ulong[] handles, uint count, IntPtr startTime, IntPtr endTime);

    [DllImport("advapi32.dll")]
    static extern uint CloseTrace(ulong handle);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void EventRecordCallback(IntPtr record);

    static EventRecordCallback callback; // kept alive while tracing
    static readonly object gate = new object();
    static Dictionary<string, long[]> flows = new Dictionary<string, long[]>();
    static Dictionary<string, string[]> localAddresses = new Dictionary<string, string[]>();
    static readonly Dictionary<int, string[]> processes = new Dictionary<int, string[]>();

    public static void Run(int parentPid, string outDir)
    {
        if (IntPtr.Size != 8) throw new Exception("64-bit PowerShell is required");
        Directory.CreateDirectory(outDir);
        RefreshLocalAddresses();

        // A session left behind by a helper that crashed blocks the name.
        IntPtr stale = NewProperties();
        ControlTraceW(0, SessionName, stale, EVENT_TRACE_CONTROL_STOP);
        Marshal.FreeHGlobal(stale);

        IntPtr properties = NewProperties();
        ulong session;
        uint rc = StartTraceW(out session, SessionName, properties);
        if (rc != 0)
        {
            Marshal.FreeHGlobal(properties);
            throw new Exception("Starting the trace failed (error " + rc + (rc == 5 ? ": administrator rights are needed" : "") + ")");
        }
        ulong trace = ulong.MaxValue;
        try
        {
            Guid provider = KernelNetwork;
            rc = EnableTraceEx2(session, ref provider, EVENT_CONTROL_CODE_ENABLE_PROVIDER, TRACE_LEVEL_INFORMATION,
                KEYWORD_IPV4_AND_IPV6, 0, 0, IntPtr.Zero);
            if (rc != 0) throw new Exception("Enabling the network provider failed (error " + rc + ")");
            trace = Open();
            ulong[] handles = new ulong[] { trace };
            Thread pump = new Thread(delegate() { ProcessTrace(handles, 1, IntPtr.Zero, IntPtr.Zero); });
            pump.IsBackground = true;
            pump.Start();
            File.WriteAllText(Path.Combine(outDir, "ready"), DateTime.UtcNow.ToString("o"));

            int seq = 0;
            DateTime refreshed = DateTime.UtcNow;
            while (true)
            {
                Thread.Sleep(5000);
                if (ParentGone(parentPid) || File.Exists(Path.Combine(outDir, "stop"))) break;
                if ((DateTime.UtcNow - refreshed).TotalSeconds > 30)
                {
                    RefreshLocalAddresses();
                    refreshed = DateTime.UtcNow;
                }
                WriteSample(outDir, ++seq);
            }
        }
        finally
        {
            if (trace != ulong.MaxValue) CloseTrace(trace);
            ControlTraceW(session, null, properties, EVENT_TRACE_CONTROL_STOP);
            Marshal.FreeHGlobal(properties);
        }
    }

    static IntPtr NewProperties()
    {
        IntPtr p = Marshal.AllocHGlobal(PropertiesBufferSize);
        for (int i = 0; i < PropertiesBufferSize; i++) Marshal.WriteByte(p, i, 0);
        Marshal.WriteInt32(p, 0, PropertiesBufferSize);       // Wnode.BufferSize
        Marshal.WriteInt32(p, 40, 1);                         // Wnode.ClientContext: QPC clock
        Marshal.WriteInt32(p, 44, WNODE_FLAG_TRACED_GUID);    // Wnode.Flags
        Marshal.WriteInt32(p, 64, EVENT_TRACE_REAL_TIME_MODE); // LogFileMode
        Marshal.WriteInt32(p, 68, 1);                         // FlushTimer (s)
        Marshal.WriteInt32(p, 116, PropertiesSize);           // LoggerNameOffset
        return p;
    }

    static ulong Open()
    {
        IntPtr logFile = Marshal.AllocHGlobal(LogFileSize);
        for (int i = 0; i < LogFileSize; i++) Marshal.WriteByte(logFile, i, 0);
        Marshal.WriteIntPtr(logFile, 8, Marshal.StringToHGlobalUni(SessionName));   // LoggerName
        Marshal.WriteInt32(logFile, 28, PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD); // ProcessTraceMode
        callback = new EventRecordCallback(OnEvent);
        Marshal.WriteIntPtr(logFile, 424, Marshal.GetFunctionPointerForDelegate(callback)); // EventRecordCallback
        ulong handle = OpenTraceW(logFile);
        if (handle == ulong.MaxValue) throw new Exception("Opening the trace failed (error " + Marshal.GetLastWin32Error() + ")");
        return handle;
    }

    // EVENT_RECORD (x64): EventHeader.EventDescriptor.Id at 40, UserDataLength at 86,
    // UserData at 96. Kernel-Network TCP/UDP send/receive payload: PID @0,
    // size @4, daddr @8, saddr @12 (IPv6: @24), dport @16 (IPv6: @40),
    // sport @18 (IPv6: @42), ports in network byte order.
    static void OnEvent(IntPtr record)
    {
        try
        {
            int id = Marshal.ReadInt16(record, 40) & 0xFFFF;
            bool send;
            bool v6;
            switch (id)
            {
                case 10: case 42: send = true; v6 = false; break;
                case 11: case 43: send = false; v6 = false; break;
                case 26: case 58: send = true; v6 = true; break;
                case 27: case 59: send = false; v6 = true; break;
                default: return;
            }
            int length = Marshal.ReadInt16(record, 86) & 0xFFFF;
            IntPtr data = Marshal.ReadIntPtr(record, 96);
            if (data == IntPtr.Zero || length < (v6 ? 44 : 20)) return;
            int pid = Marshal.ReadInt32(data, 0);
            long size = Marshal.ReadInt32(data, 4) & 0xFFFFFFFFL;
            byte[] daddr = new byte[v6 ? 16 : 4];
            byte[] saddr = new byte[v6 ? 16 : 4];
            Marshal.Copy(new IntPtr(data.ToInt64() + 8), daddr, 0, daddr.Length);
            Marshal.Copy(new IntPtr(data.ToInt64() + (v6 ? 24 : 12)), saddr, 0, saddr.Length);
            int dport = Port(data, v6 ? 40 : 16);
            int sport = Port(data, v6 ? 42 : 18);
            string d = new IPAddress(daddr).ToString();
            string s = new IPAddress(saddr).ToString();
            lock (gate)
            {
                // Whichever end isn't one of ours is the remote one.
                bool dLocal = localAddresses.ContainsKey(d);
                string remote = dLocal && !localAddresses.ContainsKey(s) ? s : d;
                int remotePort = remote == s ? sport : dport;
                string local = remote == s ? d : s;
                string key = pid + "|" + remote + "|" + remotePort + "|" + local;
                long[] sums;
                if (!flows.TryGetValue(key, out sums))
                {
                    sums = new long[2];
                    flows[key] = sums;
                }
                if (send) sums[1] += size; else sums[0] += size;
            }
        }
        catch
        {
        }
    }

    static int Port(IntPtr data, int offset)
    {
        int raw = Marshal.ReadInt16(data, offset) & 0xFFFF;
        return ((raw & 0xFF) << 8) | (raw >> 8);
    }

    static bool ParentGone(int pid)
    {
        try
        {
            return Process.GetProcessById(pid).HasExited;
        }
        catch (ArgumentException)
        {
            return true;
        }
    }

    static void RefreshLocalAddresses()
    {
        Dictionary<string, string[]> map = new Dictionary<string, string[]>();
        foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            string text = (ni.Name + " " + ni.Description).ToLowerInvariant();
            string kind = ni.NetworkInterfaceType == NetworkInterfaceType.Loopback ? "loopback"
                : (ni.NetworkInterfaceType == NetworkInterfaceType.Tunnel || text.Contains("tap") || text.Contains("tun")
                    || text.Contains("wireguard") || text.Contains("vpn") || text.Contains("wintun")) ? "tunnel" : "physical";
            foreach (UnicastIPAddressInformation a in ni.GetIPProperties().UnicastAddresses)
            {
                IPAddress address = a.Address;
                if (address.IsIPv6LinkLocal) address = new IPAddress(address.GetAddressBytes());
                map[address.ToString()] = new string[] { ni.Name, kind };
            }
        }
        lock (gate) localAddresses = map;
    }

    static string[] DescribeProcess(int pid)
    {
        string[] known;
        if (processes.TryGetValue(pid, out known)) return known;
        string exe = "";
        string name = pid == 4 ? "Windows (System)" : "";
        try
        {
            Process p = Process.GetProcessById(pid);
            if (name.Length == 0) name = p.ProcessName;
            try
            {
                exe = p.MainModule.FileName;
                FileVersionInfo info = FileVersionInfo.GetVersionInfo(exe);
                if (!string.IsNullOrEmpty(info.FileDescription)) name = info.FileDescription;
                else if (!string.IsNullOrEmpty(info.ProductName)) name = info.ProductName;
            }
            catch
            {
            }
        }
        catch
        {
        }
        known = new string[] { name, exe };
        if (processes.Count > 2000) processes.Clear();
        processes[pid] = known;
        return known;
    }

    static void WriteSample(string outDir, int seq)
    {
        Dictionary<string, long[]> taken;
        Dictionary<string, string[]> addresses;
        lock (gate)
        {
            taken = flows;
            flows = new Dictionary<string, long[]>();
            addresses = localAddresses;
        }
        StringBuilder json = new StringBuilder();
        json.Append("{\"t\":").Append((long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds).Append(",\"flows\":[");
        bool first = true;
        foreach (KeyValuePair<string, long[]> e in taken)
        {
            string[] parts = e.Key.Split('|');
            int pid = int.Parse(parts[0]);
            string[] iface;
            if (!addresses.TryGetValue(parts[3], out iface)) iface = new string[] { "", "other" };
            if (iface[1] == "loopback" || parts[1] == "127.0.0.1" || parts[1] == "::1") continue;
            string[] process = DescribeProcess(pid);
            if (!first) json.Append(',');
            first = false;
            json.Append("{\"pid\":").Append(pid)
                .Append(",\"name\":").Append(Quote(process[0]))
                .Append(",\"exe\":").Append(Quote(process[1]))
                .Append(",\"ip\":").Append(Quote(parts[1]))
                .Append(",\"port\":").Append(parts[2])
                .Append(",\"iface\":").Append(Quote(iface[0]))
                .Append(",\"kind\":").Append(Quote(iface[1]))
                .Append(",\"rx\":").Append(e.Value[0])
                .Append(",\"tx\":").Append(e.Value[1])
                .Append('}');
        }
        json.Append("]}");
        string name = "sample-" + DateTime.UtcNow.Ticks + "-" + seq;
        string temp = Path.Combine(outDir, name + ".tmp");
        File.WriteAllText(temp, json.ToString(), new UTF8Encoding(false));
        File.Move(temp, Path.Combine(outDir, name + ".json"));
    }

    static string Quote(string value)
    {
        StringBuilder b = new StringBuilder("\"");
        foreach (char c in value ?? "")
        {
            if (c == '"' || c == '\\') b.Append('\\').Append(c);
            else if (c < ' ') b.Append("\\u").Append(((int)c).ToString("x4"));
            else b.Append(c);
        }
        return b.Append('"').ToString();
    }
}
''';

/// The full helper script (PowerShell with the C# source inlined).
String buildWindowsHelperScript() => windowsHelperScript.replaceFirst('__CSHARP__', windowsHelperCSharp.trim());
