# Qpen: エクスプローラー上で Ctrl+Q を押すと、選択中のファイルを既定のアプリでまとめて開く。
# トレイに常駐し、起動するとサインイン時の自動起動も登録する。トレイの「終了」で自動起動も解除。
# 起動時と、トレイの「更新を確認」を押したときに GitHub の Releases を確認し、新しい版があれば自動で更新する。
$Version = '1.2.0'
$AppName = 'Qpen'

$ps1 = $MyInvocation.MyCommand.Path
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"
$installedFlag = Join-Path (Split-Path $ps1) 'installed.flag'  # install.ps1 が置く。初回起動時に通知を出す
$updatedFlag = Join-Path (Split-Path $ps1) 'updated.flag'      # 自動更新で置く。中身は新しいバージョン
$Repo = 'ogura-ryoya/Qpen'                                       # 自動更新の取得元（GitHub の Releases）

function New-Shortcut($path) {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
    $s.TargetPath = "$env:WINDIR\System32\conhost.exe"
    $s.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`""
    $s.WindowStyle = 7
    $s.Save()
}

# 直接実行された場合（ショートカット経由でない場合）は、ターミナルを閉じても止まらないよう
# エクスプローラー経由で起動し直す
$parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
if ((Get-CimInstance Win32_Process -Filter "ProcessId=$parentId").Name -ne 'conhost.exe') {
    New-Shortcut $startupLnk
    explorer.exe $startupLnk
    # エクスプローラー経由で起動しなかった場合は、直接起動する
    $m = $null
    for ($i = 0; $i -lt 10 -and -not [System.Threading.Mutex]::TryOpenExisting('Local\Qpen', [ref]$m); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $m) { Start-Process $startupLnk }
    return
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\Qpen')
try {
    $acquired = $mutex.WaitOne(0)
} catch {
    # 前の Qpen が強制終了された（インストールで上書きされた）場合は AbandonedMutexException になる。
    # このとき所有権はこちらに移っているので続行する（PowerShell が例外を包むことがあるので内側も見る）
    $ex = $_.Exception
    $acquired = ($ex -is [System.Threading.AbandonedMutexException]) -or ($ex.InnerException -is [System.Threading.AbandonedMutexException])
}
if (-not $acquired) { exit }  # すでに起動している

New-Shortcut $startupLnk  # 起動するたびに自動起動を登録し直す

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

// エクスプローラーのウィンドウ（CabinetWClass）が前面にある間だけ Ctrl+Q を登録する。
// ほかのアプリの Ctrl+Q には影響しない。
public class ExplorerHotkey : NativeWindow, IDisposable {
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr h);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);

    public static IntPtr Foreground() { return GetForegroundWindow(); }
    public static string Title(IntPtr h) { var s = new StringBuilder(1024); GetWindowText(h, s, 1024); return s.ToString(); }

    const uint EVENT_SYSTEM_FOREGROUND = 3, MOD_CONTROL = 2, MOD_NOREPEAT = 0x4000, VK_Q = 0x51;
    readonly WinEventProc proc;
    readonly IntPtr hook;
    bool registered;
    public event EventHandler Pressed;

    public ExplorerHotkey() {
        CreateHandle(new CreateParams());
        proc = (h, e, hwnd, o, c, t, tm) => Update(hwnd);
        hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, proc, 0, 0, 0);
        Update(GetForegroundWindow());
    }

    static bool IsExplorer(IntPtr h) {
        var s = new StringBuilder(64);
        GetClassName(h, s, 64);
        return s.ToString() == "CabinetWClass";
    }

    void Update(IntPtr fg) {
        bool want = IsExplorer(fg);
        if (want && !registered) registered = RegisterHotKey(Handle, 1, MOD_CONTROL | MOD_NOREPEAT, VK_Q);
        else if (!want && registered) { UnregisterHotKey(Handle, 1); registered = false; }
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(this, EventArgs.Empty);
        base.WndProc(ref m);
    }

    public void Dispose() {
        if (registered) UnregisterHotKey(Handle, 1);
        UnhookWinEvent(hook);
        DestroyHandle();
    }

    // トレイアイコン：青い角丸の四角に白い「Q」
    public static Icon MakeIcon() {
        var b = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(b))
        using (var path = new GraphicsPath())
        using (var bg = new SolidBrush(Color.FromArgb(0, 120, 212)))
        using (var font = new Font("Yu Gothic UI", 20, FontStyle.Bold, GraphicsUnit.Pixel))
        using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center }) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            int r = 12;
            path.AddArc(0, 0, r, r, 180, 90);
            path.AddArc(32 - r, 0, r, r, 270, 90);
            path.AddArc(32 - r, 32 - r, r, r, 0, 90);
            path.AddArc(0, 32 - r, r, r, 90, 90);
            path.CloseFigure();
            g.FillPath(bg, path);
            g.DrawString("Q", font, Brushes.White, new RectangleF(0, 1, 32, 32), sf);
        }
        return Icon.FromHandle(b.GetHicon());
    }
}
"@

$shell = New-Object -ComObject Shell.Application
$hk = New-Object ExplorerHotkey

$hk.add_Pressed({
    try {
        $fg = [ExplorerHotkey]::Foreground()
        $wins = @($shell.Windows() | Where-Object { $_.HWND -eq $fg.ToInt64() })
        if ($wins.Count -eq 0) { return }
        # Windows 11 のタブは同じウィンドウハンドルを共有するので、ウィンドウタイトルからいま表示中のタブを選ぶ。
        # タイトルは「フォルダ名 - エクスプローラー」や「フォルダ名 と他 2 個のタブ - エクスプローラー」の形になる
        $title = [ExplorerHotkey]::Title($fg)
        $w = $wins | Where-Object { $t = $_.Document.Folder.Title; $title -eq $t -or $title.StartsWith("$t ") } | Select-Object -First 1
        if (-not $w) { $w = $wins[0] }
        $items = @($w.Document.SelectedItems())
    } catch { return }
    foreach ($item in $items) {
        # フォルダは開かない（IsFolder は ZIP も true になるため、実際のフォルダかどうかで判定する）
        if ([System.IO.Directory]::Exists($item.Path)) { continue }
        # 開けないファイルがあっても、残りのファイルは開く
        try { Start-Process -FilePath $item.Path } catch {}
        Start-Sleep -Milliseconds 300
    }
})

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [ExplorerHotkey]::MakeIcon()
$Usage = 'Ctrl+Q でまとめて開く'
$tray.Text = "$AppName v$Version`n$Usage"  # 63 文字以内（NotifyIcon の上限）
$menu = New-Object System.Windows.Forms.ContextMenuStrip

# 名前（太字）、バージョン、使い方を縦に並べる。表示だけなので押せないようにする。押せるのは「更新を確認」と「終了」
$nameItem = New-Object System.Windows.Forms.ToolStripMenuItem $AppName
$nameItem.Font = New-Object System.Drawing.Font($nameItem.Font, [System.Drawing.FontStyle]::Bold)
$versionItem = New-Object System.Windows.Forms.ToolStripMenuItem "v$Version"
$hotkeyItem = New-Object System.Windows.Forms.ToolStripMenuItem $Usage
foreach ($mi in $nameItem, $versionItem, $hotkeyItem) { $mi.Enabled = $false }
$updateItem = New-Object System.Windows.Forms.ToolStripMenuItem '更新を確認'
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem '終了（自動起動も解除）'
[void]$menu.Items.Add($nameItem)
[void]$menu.Items.Add($versionItem)
[void]$menu.Items.Add($hotkeyItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($updateItem)
[void]$menu.Items.Add($exitItem)
$tray.ContextMenuStrip = $menu

$exitItem.add_Click({
    Remove-Item $startupLnk -ErrorAction SilentlyContinue
    $updateTimer.Stop()
    $tray.Visible = $false
    $hk.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# ---- 自動更新 ----
# GitHub の最新リリースを確認し、新しい版があれば Qpen.ps1 を一時フォルダにダウンロードして検証する。
# 通信で画面が固まらないよう、別のスレッド（ランスペース）で実行する。新しい版がなければ $null を返す
$checkUpdate = {
    param($repo, $current)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'Qpen' } -TimeoutSec 15
    $tag = $release.tag_name
    $latest = [version]($tag.TrimStart('v'))
    if ($latest -le [version]$current) { return $null }

    $tmp = Join-Path $env:TEMP "Qpen-$latest.ps1"
    Invoke-WebRequest "https://raw.githubusercontent.com/$repo/$tag/Qpen.ps1" -OutFile $tmp -UseBasicParsing -TimeoutSec 30
    # 壊れたファイルで上書きしないよう、構文エラーがなく、中のバージョンがタグと一致することを確かめる
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errors)
    $text = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
    if ($errors.Count -gt 0 -or $text -notmatch "(?m)^\`$Version = '$([regex]::Escape("$latest"))'") {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        return $null
    }
    [pscustomobject]@{ Version = "$latest"; Path = $tmp }
}

# 新しい版に入れ替えて起動し直す。ミューテックスを手放してから新しい Qpen を起動し、自分は終了する
$applyUpdate = {
    param($update)
    Copy-Item $update.Path $ps1 -Force
    Remove-Item $update.Path -ErrorAction SilentlyContinue
    Set-Content $updatedFlag $update.Version -Encoding UTF8
    $updateTimer.Stop()
    $tray.Visible = $false
    $hk.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Start-Process $startupLnk
    [System.Windows.Forms.Application]::Exit()
}

# 確認を始める。$manual は「更新を確認」が押されたとき。押したときは、更新がなくても結果を通知する
$startCheck = {
    param($manual)
    if ($script:checking) { return }  # 確認中
    $updateItem.Enabled = $false
    $updateItem.Text = '更新を確認中…'
    $shellForCheck = [powershell]::Create().AddScript($checkUpdate).AddArgument($Repo).AddArgument($Version)
    $script:checking = @{ Shell = $shellForCheck; Async = $shellForCheck.BeginInvoke(); Manual = $manual }
}
$updateItem.add_Click({ & $startCheck $true })

# 確認は起動 1 分後の 1 回と、「更新を確認」を押したときだけ行う。
# タイマーは 1 秒ごとに、起動時の確認の時刻と、確認が終わったかを見る
$script:startupCheckAt = (Get-Date).AddMinutes(1)
$script:checking = $null
$updateTimer = New-Object System.Windows.Forms.Timer
$updateTimer.Interval = 1000
$updateTimer.add_Tick({
    if ($script:startupCheckAt -and (Get-Date) -ge $script:startupCheckAt) {
        $script:startupCheckAt = $null
        & $startCheck $false
    }
    if (-not $script:checking -or -not $script:checking.Async.IsCompleted) { return }

    $manual = $script:checking.Manual
    $update = $null
    $failed = $false
    try { $update = @($script:checking.Shell.EndInvoke($script:checking.Async)) | Where-Object { $_ } | Select-Object -First 1 } catch { $failed = $true }
    $script:checking.Shell.Dispose()
    $script:checking = $null
    $updateItem.Text = '更新を確認'
    $updateItem.Enabled = $true

    if ($update) {
        try { & $applyUpdate $update } catch {}
    } elseif ($manual -and $failed) {
        $tray.ShowBalloonTip(5000, '更新を確認できませんでした', 'インターネットに接続されているか確認してください。', [System.Windows.Forms.ToolTipIcon]::Warning)
    } elseif ($manual) {
        $tray.ShowBalloonTip(5000, "$AppName は最新版です", "v$Version", [System.Windows.Forms.ToolTipIcon]::Info)
    }
})
$updateTimer.Start()

$tray.Visible = $true
if (Test-Path $installedFlag) {
    Remove-Item $installedFlag -ErrorAction SilentlyContinue
    $tray.ShowBalloonTip(8000, "$AppName をインストールしました",
        'エクスプローラーでファイルを選んで Ctrl+Q を押すと、まとめて開けます。', [System.Windows.Forms.ToolTipIcon]::Info)
} elseif (Test-Path $updatedFlag) {
    $newVersion = (Get-Content $updatedFlag -Encoding UTF8 -TotalCount 1)
    Remove-Item $updatedFlag -ErrorAction SilentlyContinue
    $tray.ShowBalloonTip(8000, "$AppName を v$newVersion に更新しました",
        '引き続き、エクスプローラーで Ctrl+Q を押すとまとめて開けます。', [System.Windows.Forms.ToolTipIcon]::Info)
}
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
