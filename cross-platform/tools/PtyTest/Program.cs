using System;
using System.Text;
using System.Threading;
using RemoteStuff.Services.Terminal;

var pty = new UnixPtyProcess();
pty.Start("/bin/sh", new[] { "-c", "echo hello-from-pty && tty && exit 7" }, 80, 24);

var sb = new StringBuilder();
var buf = new byte[4096];
var sw = System.Diagnostics.Stopwatch.StartNew();
while (sw.Elapsed.TotalSeconds < 3)
{
    var n = pty.Read(buf);
    if (n <= 0) break;
    sb.Append(Encoding.UTF8.GetString(buf, 0, n));
}

Console.WriteLine("---- PTY OUTPUT ----");
Console.Write(sb.ToString());
Console.WriteLine("\n---- END ----");

int? code = null;
for (var i = 0; i < 20 && code == null; i++) { code = pty.TryReap(); Thread.Sleep(50); }
Console.WriteLine($"Exit code: {code}");
Console.WriteLine(sb.ToString().Contains("hello-from-pty") ? "PASS: output captured" : "FAIL: no output");
Console.WriteLine(sb.ToString().Contains("/dev/") ? "PASS: real tty present" : "WARN: no tty line");
pty.Dispose();
