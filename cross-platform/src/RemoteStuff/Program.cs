using Avalonia;
using Avalonia.WebView.Desktop;
using System;
using System.IO;
using System.Threading.Tasks;
using Velopack;

namespace RemoteStuff;

internal sealed class Program
{
    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called: things aren't
    // initialized yet and stuff might break.
    [STAThread]
    public static void Main(string[] args)
    {
        // Must run before any other code: Velopack intercepts install / update /
        // uninstall hooks that (re)launch the app, and exits early when handling one.
        VelopackApp.Build().Run();

        InstallCrashLogging();
        try
        {
            BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }
        catch (Exception ex)
        {
            LogCrash("StartWithClassicDesktopLifetime", ex);
            throw;
        }
    }

    /// <summary>Path to a persistent crash log that survives app relaunches
    /// (unlike the truncated stdout log), so a crash's stack trace can be recovered.
    /// Uses the same data directory convention as the rest of the app.</summary>
    private static string CrashLogPath
    {
        get
        {
            var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(baseDir))
                baseDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
            return Path.Combine(baseDir, "RemoteStuff", "crash.log");
        }
    }

    private static void InstallCrashLogging()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            LogCrash("AppDomain.UnhandledException", e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            LogCrash("TaskScheduler.UnobservedTaskException", e.Exception);
            e.SetObserved();
        };
    }

    private static void LogCrash(string source, Exception? ex)
    {
        try
        {
            var path = CrashLogPath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.AppendAllText(path,
                $"\n===== {DateTimeOffset.Now:O}  [{source}] =====\n{ex}\n");
        }
        catch { /* logging must never itself crash the app */ }
    }

    // Avalonia configuration, don't remove; also used by visual designer.
    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
            // macOS: prefer the Metal backend, falling back to software rendering.
            // The default OpenGL/IOSurface path (AvnGlRenderingSession / presentSurface)
            // can null-deref on the render thread when a surface is presented while the
            // GL session is being torn down — e.g. when a context menu popup opens over a
            // terminal, or a full-screen TUI (btop) repaints on Ctrl+C — crashing the
            // whole app with a native SIGSEGV. Skipping OpenGl avoids that class of crash.
            .With(new AvaloniaNativePlatformOptions
            {
                RenderingMode = new[]
                {
                    AvaloniaNativeRenderingMode.Metal,
                    AvaloniaNativeRenderingMode.Software,
                }
            })
            .WithInterFont()
            .UseDesktopWebView()
            .LogToTrace();
}
