// Запускатор IPA PILOTDREDD: IPA_PILOTDREDD.exe рядом с IPA_Dredd.ps1, с иконкой.
// С 4.5.1 скрипт выполняется внутри этого процесса (встроенный Windows PowerShell 5.1, System.Management.Automation),
// без запуска скрытого powershell.exe с -ExecutionPolicy Bypass -WindowStyle Hidden: такая командная строка
// типична для вредоносных программ, и антивирусы по ней ложно срабатывали.
// Ничего не устанавливает и не пишет вне своей папки (portable). Собирается tools/Build-Launcher.ps1 (csc из .NET Framework 4).
// Версия файла постоянная: тот же exe переходит из релиза в релиз, чтобы у него копилась репутация в SmartScreen/Defender.
using System;
using System.Collections.Generic;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("IPA PILOTDREDD")]
[assembly: AssemblyProduct("IPA PILOTDREDD")]
[assembly: AssemblyCompany("PILOTDREDD")]
[assembly: AssemblyDescription("App Store purchase library and IPA downloader (launcher)")]
[assembly: AssemblyCopyright("PILOTDREDD; based on IPA Downloader (kda2495), MIT")]
[assembly: AssemblyVersion("2.0.0.0")]
[assembly: AssemblyFileVersion("2.0.0.0")]

static class Program
{
    const string Title = "IPA PILOTDREDD";

    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "IPA_Dredd.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("Рядом с программой нет файла IPA_Dredd.ps1.\nРаспакуйте архив целиком и запускайте IPA_PILOTDREDD.exe из папки программы.",
                Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        Directory.SetCurrentDirectory(dir);
        // Политика выполнения только для этого процесса (как «-ExecutionPolicy Bypass»): фоновые runspace программы
        // загружают модуль из папки программы. Системные настройки не меняются.
        Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass");
        try
        {
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            iss.ApartmentState = ApartmentState.STA;   // WPF требует STA
            iss.ThreadOptions = PSThreadOptions.UseCurrentThread;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    Command cmd = new Command(script, false, true);
                    AddArguments(cmd, args);
                    ps.Commands.AddCommand(cmd);
                    ps.Invoke();
                    // Ошибки запуска IPA_Dredd.ps1 показывает сам (trap → окно и Logs/startup-error.log).
                    if (ps.HadErrors && ps.Streams.Error.Count > 0 && ps.InvocationStateInfo.State == PSInvocationState.Failed)
                    {
                        Fail(ps.Streams.Error[0].ToString());
                        return 1;
                    }
                }
                // «exit N» в скрипте → код возврата exe (нужен самопроверке -SelfTest).
                object code = rs.SessionStateProxy.GetVariable("LASTEXITCODE");
                return code is int ? (int)code : 0;
            }
        }
        catch (Exception ex)
        {
            Fail(ex.Message);
            return 1;
        }
    }

    // Аргументы exe → параметры скрипта: «-Имя значение» или переключатель «-Имя».
    static void AddArguments(Command cmd, string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            if (a.Length > 1 && a[0] == '-')
            {
                string name = a.Substring(1);
                if (i + 1 < args.Length && !(args[i + 1].Length > 1 && args[i + 1][0] == '-'))
                {
                    cmd.Parameters.Add(name, args[i + 1]);
                    i++;
                }
                else { cmd.Parameters.Add(name, true); }
            }
            else { cmd.Parameters.Add(null, a); }
        }
    }

    static void Fail(string message)
    {
        try
        {
            string logDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Logs");
            Directory.CreateDirectory(logDir);
            File.AppendAllText(Path.Combine(logDir, "startup-error.log"),
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [launcher] " + message + Environment.NewLine, Encoding.UTF8);
        }
        catch { }
        MessageBox.Show("IPA PILOTDREDD could not start:\n\n" + message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
