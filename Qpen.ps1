# Qpen: エクスプローラー上で Ctrl+Q を押すと、選択中のファイルを既定のアプリでまとめて開く。
# トレイに常駐し、起動するとサインイン時の自動起動も登録する。トレイの「終了」で自動起動も解除。
# 起動時と、トレイの「更新を確認」を押したときに GitHub の Releases を確認し、新しい版があれば自動で更新する。
$Version = '1.4.0'
$AppName = 'Qpen'

$ps1 = $MyInvocation.MyCommand.Path
$appDir = Split-Path $ps1
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"
$installedFlag = Join-Path $appDir 'installed.flag'    # install.ps1 が置く。初回起動時に通知を出す
$updatedFlag = Join-Path $appDir 'updated.flag'        # 自動更新で置く。中身は新しいバージョン
$rolledBackFlag = Join-Path $appDir 'rolledback.flag'  # 更新した版が起動できず元に戻したときに置く。中身はその版
$skipFile = Join-Path $appDir 'skip-version.txt'       # 起動できなかった版。この版には自動では更新しない
$backupPs1 = Join-Path $appDir 'Qpen.backup.ps1'       # 更新前の版（起動できなかったときに戻す）
$Repo = 'ogura-ryoya/Qpen'                             # 自動更新の取得元（GitHub の Releases）

# Qpen を画面なしで起動する命令。自動起動のショートカットと、更新後の起動し直しで共通に使う
$conhost = "$env:WINDIR\System32\conhost.exe"
$launchArgs = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps1`""

function New-Shortcut($path) {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
    $s.TargetPath = $conhost
    $s.Arguments = $launchArgs
    $s.WindowStyle = 7
    $s.Save()
}

function Start-Qpen { Start-Process $conhost -ArgumentList $launchArgs }

# 直接実行された場合（ショートカット経由でない場合）は、ターミナルを閉じても止まらないよう
# エクスプローラー経由で起動し直す
$parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
if ((Get-CimInstance Win32_Process -Filter "ProcessId=$parentId").Name -ne 'conhost.exe') {
    New-Shortcut $startupLnk
    explorer.exe $startupLnk
    # エクスプローラー経由で起動しなかった場合は、直接起動する
    $m = $null
    for ($i = 0; $i -lt 10 -and -not [System.Threading.Mutex]::TryOpenExisting('Local\Qpen', [ref]$m); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not $m) { Start-Qpen }
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

# 起動するたびに自動起動を登録し直す。登録できなかったときは、トレイが出てから通知する
$autostartFailed = $false
try { New-Shortcut $startupLnk } catch { $autostartFailed = $true }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
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
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);

    public static IntPtr Foreground() { return GetForegroundWindow(); }
    public static string Title(IntPtr h) { var s = new StringBuilder(1024); GetWindowText(h, s, 1024); return s.ToString(); }

    // 画面の拡大率（125%・150% など）に合わせて、アイコンやメニューをぼやけずに表示する。ウィンドウを作る前に呼ぶ
    public static void EnableDpiAwareness() { SetProcessDPIAware(); }

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

    // アイコン：上から下へ明るい青から濃い青になる角丸の四角に、線で描いた白い「Q」。
    // 文字のフォントに頼らず図形で描くので、どの大きさでもくっきり表示される。32×32 を基準に拡大・縮小して描く
    public static Bitmap Render(int size) {
        var b = new Bitmap(size, size);
        using (var g = Graphics.FromImage(b)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            float s = size / 32f;
            g.ScaleTransform(s, s);
            using (var tile = RoundRect(1f, 1f, 30f, 30f, 8f))
            using (var bg = new LinearGradientBrush(new PointF(0f, 1f), new PointF(0f, 31f), Color.FromArgb(0x4C, 0xA8, 0xF5), Color.FromArgb(0x0A, 0x5C, 0xC4))) {
                g.FillPath(bg, tile);
            }
            using (var pen = new Pen(Color.White, 3.6f)) {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                g.DrawEllipse(pen, 7.5f, 7f, 15f, 15f);
                g.DrawLine(pen, 18f, 17.5f, 24.5f, 24f);
            }
        }
        return b;
    }

    public static Icon MakeIcon(int size) {
        using (var b = Render(size)) { return Icon.FromHandle(b.GetHicon()); }
    }

    static GraphicsPath RoundRect(float x, float y, float w, float h, float r) {
        var p = new GraphicsPath();
        float d = r * 2f;
        p.AddArc(x, y, d, d, 180f, 90f);
        p.AddArc(x + w - d, y, d, d, 270f, 90f);
        p.AddArc(x + w - d, y + h - d, d, d, 0f, 90f);
        p.AddArc(x, y + h - d, d, d, 90f, 90f);
        p.CloseFigure();
        return p;
    }
}
"@

[ExplorerHotkey]::EnableDpiAwareness()

$shell = New-Object -ComObject Shell.Application
$hk = New-Object ExplorerHotkey
$Warning = [System.Windows.Forms.ToolTipIcon]::Warning
$Info = [System.Windows.Forms.ToolTipIcon]::Info

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
    } catch {
        $tray.ShowBalloonTip(5000, '選択中のファイルを取得できませんでした', 'もう一度 Ctrl+Q を押してください。', $Warning)
        return
    }
    # 開けないファイルがあっても残りのファイルは開き、最後に開けなかったファイルを通知する
    $failedNames = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        # フォルダは開かない（IsFolder は ZIP も true になるため、実際のフォルダかどうかで判定する）
        if ([System.IO.Directory]::Exists($item.Path)) { continue }
        try { Start-Process -FilePath $item.Path } catch { $failedNames.Add($item.Name) }
        Start-Sleep -Milliseconds 300
    }
    if ($failedNames.Count -gt 0) {
        $names = ($failedNames | Select-Object -First 3) -join '、'
        if ($failedNames.Count -gt 3) { $names += " ほか $($failedNames.Count - 3) 件" }
        $tray.ShowBalloonTip(6000, "$($failedNames.Count) 個のファイルを開けませんでした", $names, $Warning)
    }
})

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [ExplorerHotkey]::MakeIcon([System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
$Usage = 'Ctrl+Q でまとめて開く'
$tray.Text = "$AppName v$Version`n$Usage"  # 63 文字以内（NotifyIcon の上限）
$menu = New-Object System.Windows.Forms.ContextMenuStrip

# 名前（太字）、バージョン、使い方を縦に並べる。表示だけなので押せないようにする。
# 押せるのは「GitHub を開く」「更新を確認」「終了」
$nameItem = New-Object System.Windows.Forms.ToolStripMenuItem $AppName
$nameItem.Font = New-Object System.Drawing.Font($nameItem.Font, [System.Drawing.FontStyle]::Bold)
$versionItem = New-Object System.Windows.Forms.ToolStripMenuItem "v$Version"
$hotkeyItem = New-Object System.Windows.Forms.ToolStripMenuItem $Usage
foreach ($mi in $nameItem, $versionItem, $hotkeyItem) { $mi.Enabled = $false }
$githubItem = New-Object System.Windows.Forms.ToolStripMenuItem 'GitHub を開く'
$updateItem = New-Object System.Windows.Forms.ToolStripMenuItem '更新を確認'
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem '終了（自動起動も解除）'
[void]$menu.Items.Add($nameItem)
[void]$menu.Items.Add($versionItem)
[void]$menu.Items.Add($hotkeyItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($githubItem)
[void]$menu.Items.Add($updateItem)
[void]$menu.Items.Add($exitItem)
$tray.ContextMenuStrip = $menu

$githubItem.add_Click({ Start-Process "https://github.com/$Repo" })

$exitItem.add_Click({
    Remove-Item $startupLnk -ErrorAction SilentlyContinue
    $updateTimer.Stop()
    $tray.Visible = $false
    $hk.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# ---- 自動更新 ----
# GitHub の最新リリースの Qpen.ps1 を一時フォルダにダウンロードし、中に書かれたバージョンで新しいかを判断する。
# （タグはファイルの取得先にだけ使う。タグの番号とファイルのバージョンがずれていても誤動作しない）
# 通信で画面が固まらないよう、別のスレッド（ランスペース）で実行する。
# 新しい版がなければ $null を返し、通信の失敗やファイルが壊れているときは例外を投げる。
# $skip は以前に起動できなかった版。自動の確認（$manual が false）では、この版には更新しない
$checkUpdate = {
    param($repo, $current, $skip, $manual)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'Qpen' } -TimeoutSec 15
    $tmp = Join-Path $env:TEMP 'Qpen-update.ps1'
    Invoke-WebRequest "https://raw.githubusercontent.com/$repo/$($release.tag_name)/Qpen.ps1" -OutFile $tmp -UseBasicParsing -TimeoutSec 30

    # 壊れたファイルで上書きしないよう、構文エラーがなく、バージョンが読み取れることを確かめる
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errors)
    $match = [regex]::Match([IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8), "(?m)^\`$Version = '(\d+\.\d+\.\d+)'")
    if ($errors.Count -gt 0 -or -not $match.Success) {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        throw 'ダウンロードした Qpen.ps1 が壊れています'
    }
    $latest = [version]$match.Groups[1].Value
    if ($latest -le [version]$current -or (-not $manual -and "$latest" -eq $skip)) {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        return $null
    }
    [pscustomobject]@{ Version = "$latest"; Path = $tmp }
}

# 新しい版に入れ替えて起動し直す。ミューテックスを手放してから新しい Qpen を起動し、
# 新しい Qpen が起動を知らせてくる（QpenReady）のを最大 60 秒待つ。来なければ新しい版を止めて元の版に戻す
$applyUpdate = {
    param($update)
    Copy-Item $ps1 $backupPs1 -Force
    Copy-Item $update.Path $ps1 -Force
    Remove-Item $update.Path -ErrorAction SilentlyContinue
    Set-Content $updatedFlag $update.Version -Encoding UTF8
    $updateTimer.Stop()
    $tray.Visible = $false
    $hk.Dispose()
    $ready = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\QpenReady')
    [void]$ready.Reset()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Start-Qpen
    if (-not $ready.WaitOne(60000)) {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*\Qpen.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Copy-Item $backupPs1 $ps1 -Force
        Remove-Item $updatedFlag -ErrorAction SilentlyContinue
        Set-Content $skipFile $update.Version -Encoding UTF8
        Set-Content $rolledBackFlag $update.Version -Encoding UTF8
        Start-Qpen
    }
    $ready.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

# 確認を始める。$manual は「更新を確認」が押されたとき。押したときは、更新がなくても結果を通知する
$startCheck = {
    param($manual)
    if ($script:checking) { return }  # 確認中
    $updateItem.Enabled = $false
    $updateItem.Text = '更新を確認中…'
    $skip = if (Test-Path $skipFile) { (Get-Content $skipFile -Encoding UTF8 -TotalCount 1) } else { '' }
    $shellForCheck = [powershell]::Create().AddScript($checkUpdate).AddArgument($Repo).AddArgument($Version).AddArgument($skip).AddArgument($manual)
    $script:checking = @{ Shell = $shellForCheck; Async = $shellForCheck.BeginInvoke(); Manual = $manual }
}
$updateItem.add_Click({ & $startCheck $true })

# 確認は起動した直後の 1 回と、「更新を確認」を押したときだけ行う。
# 起動直後はネットワークがまだつながっていないことがあるので、起動時の確認に失敗したら
# 1 分後にやり直す（最大 5 回）。5 回とも失敗したら 1 度だけ通知する。
# タイマーは 1 秒ごとに、起動時の確認の時刻と、確認が終わったかを見る
$script:startupCheckAt = Get-Date
$script:startupRetries = 5
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
        try { & $applyUpdate $update } catch {
            $tray.ShowBalloonTip(5000, '更新できませんでした', "v$($update.Version) に入れ替えられませんでした。v$Version のまま使えます。", $Warning)
        }
    } elseif ($failed -and -not $manual -and $script:startupRetries -gt 0) {
        $script:startupRetries--
        $script:startupCheckAt = (Get-Date).AddMinutes(1)
    } elseif ($failed) {
        $tray.ShowBalloonTip(5000, '更新を確認できませんでした', 'インターネットの接続を確認して、あとでトレイの「更新を確認」からもう一度お試しください。', $Warning)
    } elseif ($manual) {
        $tray.ShowBalloonTip(5000, "$AppName は最新版です", "v$Version", $Info)
    }
})
$updateTimer.Start()

$tray.Visible = $true

# 起動できたことを知らせる（更新した直後は、前の Qpen がこれを待っている）
$readySignal = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\QpenReady')
[void]$readySignal.Set()
Remove-Item $backupPs1 -ErrorAction SilentlyContinue

if (Test-Path $installedFlag) {
    Remove-Item $installedFlag -ErrorAction SilentlyContinue
    $tray.ShowBalloonTip(8000, "$AppName をインストールしました",
        'エクスプローラーでファイルを選んで Ctrl+Q を押すと、まとめて開けます。', $Info)
} elseif (Test-Path $updatedFlag) {
    $newVersion = (Get-Content $updatedFlag -Encoding UTF8 -TotalCount 1)
    Remove-Item $updatedFlag -ErrorAction SilentlyContinue
    Remove-Item $skipFile -ErrorAction SilentlyContinue
    $tray.ShowBalloonTip(8000, "$AppName を v$newVersion に更新しました",
        '引き続き、エクスプローラーで Ctrl+Q を押すとまとめて開けます。', $Info)
} elseif (Test-Path $rolledBackFlag) {
    $failedVersion = (Get-Content $rolledBackFlag -Encoding UTF8 -TotalCount 1)
    Remove-Item $rolledBackFlag -ErrorAction SilentlyContinue
    $tray.ShowBalloonTip(8000, "v$failedVersion に更新できませんでした",
        "新しい版が起動できなかったため、v$Version に戻しました。この版には自動では更新しません。", $Warning)
} elseif ($autostartFailed) {
    $tray.ShowBalloonTip(8000, '自動起動を登録できませんでした',
        '次にサインインしたとき、Qpen が自動で起動しないことがあります。もう一度インストールしてください。', $Warning)
}
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
