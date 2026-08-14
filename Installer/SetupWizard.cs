using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;

class MigratorSetup : Form
{
    Label title = new Label(), text = new Label(), step = new Label();
    Button next = new Button(), back = new Button(), cancel = new Button();
    ProgressBar progress = new ProgressBar();
    int page;

    [STAThread] static void Main(string[] args)
    {
        bool silent = Array.Exists(args, delegate(string arg) { return arg.Equals("/silent", StringComparison.OrdinalIgnoreCase) || arg.Equals("/quiet", StringComparison.OrdinalIgnoreCase); });
        if (silent) { Environment.ExitCode = RunInstaller(true); return; }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MigratorSetup());
    }

    MigratorSetup()
    {
        Text = "Win11Migrator Setup"; ClientSize = new Size(640, 430); FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen; BackColor = Color.White; Font = new Font("Segoe UI", 9);
        Panel banner = new Panel { Dock = DockStyle.Top, Height = 92, BackColor = Color.FromArgb(105, 28, 38) };
        title.SetBounds(30, 20, 570, 36); title.Font = new Font("Segoe UI Semibold", 19); title.ForeColor = Color.White;
        step.SetBounds(32, 60, 560, 20); step.ForeColor = Color.FromArgb(242, 211, 141);
        banner.Controls.Add(title); banner.Controls.Add(step); Controls.Add(banner);
        text.SetBounds(38, 125, 560, 160); text.Font = new Font("Segoe UI", 10);
        progress.SetBounds(38, 285, 560, 22); progress.Style = ProgressBarStyle.Marquee; progress.Visible = false;
        Controls.Add(text); Controls.Add(progress);
        Panel footer = new Panel { Dock = DockStyle.Bottom, Height = 72, BackColor = Color.FromArgb(247, 247, 247) };
        back.SetBounds(330, 19, 88, 34); back.Text = "< Back"; back.Click += delegate { page = 0; RenderPage(); };
        next.SetBounds(426, 19, 88, 34); next.Click += NextPage;
        cancel.SetBounds(522, 19, 88, 34); cancel.Text = "Cancel"; cancel.Click += delegate { Close(); };
        footer.Controls.Add(back); footer.Controls.Add(next); footer.Controls.Add(cancel); Controls.Add(footer); RenderPage();
    }

    void RenderPage()
    {
        progress.Visible = false; back.Enabled = page == 1; cancel.Enabled = page < 2;
        if (page == 0) { title.Text = "Welcome to Win11Migrator Setup"; step.Text = "AuthorityGate Win11Migrator 1.0.3"; text.Text = "This wizard installs or upgrades Win11Migrator.\r\n\r\nMove applications, user data, browser profiles, and supported Windows settings through a guided Windows 11 migration workflow.\r\n\r\nClick Next to continue."; next.Text = "Next >"; }
        else if (page == 1) { title.Text = "Ready to install"; step.Text = "Install or upgrade"; text.Text = "Setup will install the newest Win11Migrator version under Program Files, create shortcuts, and register it in Windows Apps & Features.\r\n\r\nYour migration data is not removed during this upgrade."; next.Text = "Install"; }
        else { title.Text = "Setup complete"; step.Text = "Win11Migrator 1.0.3 is installed"; text.Text = "The newest Win11Migrator version was installed successfully."; next.Text = "Finish"; back.Enabled = false; }
    }

    async void NextPage(object sender, EventArgs e)
    {
        if (page == 0) { page = 1; RenderPage(); return; }
        if (page == 2) { Close(); return; }
        title.Text = "Installing Win11Migrator"; step.Text = "Please wait"; text.Text = "Installing the signed application package…";
        progress.Visible = true; next.Enabled = back.Enabled = cancel.Enabled = false;
        try { int code = await Task.Run(delegate { return RunInstaller(false); }); if (code != 0) throw new Exception("Installer exited with code " + code); page = 2; next.Enabled = true; RenderPage(); }
        catch (Win32Exception) { MessageBox.Show("Administrator approval is required.", "Win11Migrator Setup", MessageBoxButtons.OK, MessageBoxIcon.Warning); page = 1; next.Enabled = cancel.Enabled = true; RenderPage(); }
        catch (Exception ex) { MessageBox.Show("Setup could not complete.\r\n\r\n" + ex.Message, "Win11Migrator Setup", MessageBoxButtons.OK, MessageBoxIcon.Error); page = 1; next.Enabled = cancel.Enabled = true; RenderPage(); }
    }

    static int RunInstaller(bool silent)
    {
        string script = Path.Combine(Path.GetTempPath(), "Win11Migrator-" + Guid.NewGuid().ToString("N") + ".ps1");
        using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("InstallerScript"))
        using (FileStream target = File.Create(script)) source.CopyTo(target);
        try { ProcessStartInfo info = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"" + (silent ? " -Silent" : "")) { UseShellExecute = true, Verb = "runas", WindowStyle = silent ? ProcessWindowStyle.Hidden : ProcessWindowStyle.Normal }; using (Process process = Process.Start(info)) { process.WaitForExit(); return process.ExitCode; } }
        finally { try { File.Delete(script); } catch { } }
    }
}
