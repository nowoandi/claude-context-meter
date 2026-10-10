// ClaudeContextMeter.exe - the widget's own face in Windows.
//
// The widget is a PowerShell script, and until 1.3.2 it ran inside powershell.exe. Task
// Manager names a process after its executable, so it showed up as "Windows PowerShell"
// with PowerShell's icon, indistinguishable from any other script; and its autostart was
// a scheduled task, which the Startup apps tab does not list at all. Andrej 10.10.2026:
// "мне кажется, что у меня там нет отображения ни имени, ни иконки".
//
// This executable carries the name, publisher and icon, and runs the script in-process on
// an STA thread instead of starting powershell.exe, so Task Manager sees one process that
// is called what it is. It is a windowed program, so there is no console to hide either -
// the job Start-ContextMeter.vbs used to do.
//
// If the in-process host cannot start (a machine whose policy refuses it, say), it falls
// back to the old way rather than leaving the user with nothing.

using System;
using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Threading;

[assembly: AssemblyTitle("Claude Context Meter")]
[assembly: AssemblyProduct("Claude Context Meter")]
[assembly: AssemblyCompany("Andrej Hermann")]
[assembly: AssemblyCopyright("Andrej Hermann")]
[assembly: AssemblyVersion(ClaudeContextMeter.Launcher.Version)]
[assembly: AssemblyFileVersion(ClaudeContextMeter.Launcher.Version)]
[assembly: AssemblyInformationalVersion(ClaudeContextMeter.Launcher.Version)]

namespace ClaudeContextMeter
{
    static class Launcher
    {
        public const string Version = "1.3.2.0";

        [STAThread]
        static int Main()
        {
            string here = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string script = Path.Combine(here, "ClaudeContextMeter.ps1");
            try
            {
                RunInProcess(script);
                return 0;
            }
            catch (Exception ex)
            {
                Log(here, "in-process host failed, falling back to powershell.exe: " + ex.Message);
                return RunExternal(script);
            }
        }

        static void RunInProcess(string script)
        {
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                // WPF needs STA, and the dispatcher loop the script starts must run on this
                // very thread - the one that owns the window.
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(script);
                    // Errors from inside the running widget are its own business and go to its
                    // log; only a host that never got going is worth falling back from, or a
                    // widget that crashed after an hour would be started a second time.
                    ps.Invoke();
                }
            }
        }

        static int RunExternal(string script)
        {
            ProcessStartInfo si = new ProcessStartInfo("powershell.exe",
                "-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + script + "\"");
            si.UseShellExecute = false;
            si.CreateNoWindow = true;
            Process.Start(si);
            return 0;
        }

        static void Log(string here, string line)
        {
            try
            {
                string dir = Environment.GetEnvironmentVariable("LOCALAPPDATA");
                string path = string.IsNullOrEmpty(dir) ? Path.Combine(here, "ClaudeContextMeter.log")
                                                        : Path.Combine(dir, "ClaudeContextMeter.log");
                File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  [launcher]  " + line + Environment.NewLine);
            }
            catch { }
        }
    }
}
