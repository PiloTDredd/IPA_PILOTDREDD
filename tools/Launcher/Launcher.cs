// Запускатор IPA PILOTDREDD: IPA_PILOTDREDD.exe рядом с IPA_Dredd.ps1. Без консольного окна, с иконкой.
// Ничего не устанавливает и не пишет вне своей папки (portable). Собирается tools/Build-Launcher.ps1 (csc из .NET Framework).
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("IPA PILOTDREDD")]
[assembly: AssemblyProduct("IPA PILOTDREDD")]
[assembly: AssemblyCompany("PILOTDREDD")]
[assembly: AssemblyDescription("App Store purchase library and IPA downloader")]
[assembly: AssemblyCopyright("PILOTDREDD; based on IPA Downloader (kda2495), MIT")]
[assembly: AssemblyVersion(LauncherInfo.Version)]
[assembly: AssemblyFileVersion(LauncherInfo.Version)]

static class LauncherInfo
{
    public const string Version = "0.0.0.0"; // подставляется при сборке
}

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "IPA_Dredd.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("Рядом с программой нет файла IPA_Dredd.ps1.\nРаспакуйте архив целиком и запускайте IPA_PILOTDREDD.exe из распакованной папки.\n\nIPA_Dredd.ps1 was not found next to the program. Extract the whole archive.",
                "IPA PILOTDREDD", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        // Windows PowerShell 5.1 есть в каждой Windows 10/11; 64-битный процесс берёт 64-битную версию.
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(ps)) { ps = "powershell.exe"; }

        var sb = new StringBuilder("-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ");
        sb.Append(Quote(script));
        foreach (string a in args) { sb.Append(' ').Append(Quote(a)); }

        var psi = new ProcessStartInfo(ps, sb.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        try
        {
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("Не удалось запустить Windows PowerShell:\n" + ex.Message, "IPA PILOTDREDD", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static string Quote(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) { return s; }
        return "\"" + s.Replace("\\\"", "\\\\\"").Replace("\"", "\\\"") + "\"";
    }
}
