Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
# WINDOW API
# ============================================================

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class WindowAPI
{
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(
        IntPtr hWnd,
        StringBuilder lpString,
        int nMaxCount
    );

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(
        IntPtr hWnd,
        int nCmdShow
    );

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(
        IntPtr hWnd
    );

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    public const int SW_MINIMIZE = 6;
    public const int SW_MAXIMIZE = 3;
}
"@

# ============================================================
# MOUSE API
# ============================================================

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class MouseAPI
{
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(
        int X,
        int Y
    );

    [DllImport("user32.dll")]
    public static extern void mouse_event(
        uint dwFlags,
        uint dx,
        uint dy,
        uint dwData,
        UIntPtr dwExtraInfo
    );

    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP   = 0x0004;
}
"@

# ============================================================
# CLICK-THROUGH RED CIRCLE
# ============================================================

Add-Type @"
using System;
using System.Drawing;
using System.Windows.Forms;

public class RedCircleForm : Form
{
    public RedCircleForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;

        BackColor = Color.Magenta;
        TransparencyKey = Color.Magenta;

        Width = 8;
        Height = 8;

        DoubleBuffered = true;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;

            // WS_EX_TOOLWINDOW
            cp.ExStyle |= 0x80;

            // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x08000000;

            // WS_EX_LAYERED
            cp.ExStyle |= 0x00080000;

            return cp;
        }
    }

    protected override bool ShowWithoutActivation
    {
        get
        {
            return true;
        }
    }

    protected override void WndProc(ref Message m)
    {
        // WM_NCHITTEST
        if (m.Msg == 0x84)
        {
            m.Result = new IntPtr(-1);
            return;
        }

        base.WndProc(ref m);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);

        e.Graphics.SmoothingMode =
            System.Drawing.Drawing2D.SmoothingMode.AntiAlias;

        using (Brush brush = new SolidBrush(Color.Red))
        {
            e.Graphics.FillEllipse(
                brush,
                0,
                0,
                Width - 1,
                Height - 1
            );
        }
    }
}
"@

# ============================================================
# PATHS
# ============================================================

$workspace = $env:GITHUB_WORKSPACE

if ([string]::IsNullOrWhiteSpace($workspace)) {
    $workspace = (Get-Location).Path
}

$outputDir = Join-Path $workspace "rdp-output"

New-Item `
    -ItemType Directory `
    -Path $outputDir `
    -Force |
    Out-Null

$videoPath = Join-Path $outputDir "rdp-click-video.mp4"
$screenshotPath = Join-Path $outputDir "rdp-click-screenshot.png"
$clickLog = Join-Path $outputDir "click-record.log"
$ffmpegOut = Join-Path $outputDir "ffmpeg-output.log"
$ffmpegErr = Join-Path $outputDir "ffmpeg-error.log"

Remove-Item `
    $videoPath,
    $screenshotPath,
    $clickLog,
    $ffmpegOut,
    $ffmpegErr `
    -Force `
    -ErrorAction SilentlyContinue

# ============================================================
# LOGGING
# ============================================================

function Log {
    param(
        [string]$Message
    )

    $line = "[{0}] {1}" -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"),
        $Message

    Write-Host $line

    Add-Content `
        -Path $clickLog `
        -Value $line
}

# ============================================================
# VARIABLES
# ============================================================

$ffmpegProcess = $null
$redCircle = $null

try {

    Log "========================================"
    Log "RDP RECORDING STARTED"
    Log "========================================"

    Log "Workspace: $workspace"
    Log "Output directory: $outputDir"

    # ========================================================
    # CHECK SCREEN
    # ========================================================

    Log "Checking primary screen..."

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen

    if ($null -eq $screen) {
        throw "PrimaryScreen is null."
    }

    $screenBounds = $screen.Bounds

    Log "Screen X=$($screenBounds.X)"
    Log "Screen Y=$($screenBounds.Y)"
    Log "Screen Width=$($screenBounds.Width)"
    Log "Screen Height=$($screenBounds.Height)"

    if ($screenBounds.Width -le 0 -or $screenBounds.Height -le 0) {
        throw "Invalid screen dimensions."
    }

    # ========================================================
    # FIND CHROME
    # ========================================================

    Log "Searching for Chrome..."

    $chromeProcesses = @(
        Get-Process chrome `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.MainWindowHandle -ne [IntPtr]::Zero
        }
    )

    if ($chromeProcesses.Count -eq 0) {
        throw "Chrome with a visible top-level window was not found."
    }

    Log "Chrome windows found: $($chromeProcesses.Count)"

    foreach ($p in $chromeProcesses) {
        Log "Chrome PID=$($p.Id) Handle=$($p.MainWindowHandle)"
    }

    $chrome = $chromeProcesses |
        Sort-Object StartTime -Descending |
        Select-Object -First 1

    $chromeWindow = $chrome.MainWindowHandle

    if ($chromeWindow -eq [IntPtr]::Zero) {
        throw "Chrome window handle is zero."
    }

    $titleBuilder =
        New-Object System.Text.StringBuilder 1024

    [WindowAPI]::GetWindowText(
        $chromeWindow,
        $titleBuilder,
        1024
    ) | Out-Null

    $chromeTitle = $titleBuilder.ToString()

    Log "Selected Chrome window: $chromeTitle"
    Log "Chrome PID: $($chrome.Id)"
    Log "Chrome Handle: $chromeWindow"

    # ========================================================
    # MINIMIZE OTHER WINDOWS
    # ========================================================

    Log "Minimizing other applications..."

    $allProcesses = Get-Process -ErrorAction SilentlyContinue

    foreach ($proc in $allProcesses) {

        try {

            if ($proc.MainWindowHandle -eq [IntPtr]::Zero) {
                continue
            }

            if ($proc.Id -eq $chrome.Id) {
                continue
            }

            $title = $proc.MainWindowTitle

            if ([string]::IsNullOrWhiteSpace($title)) {
                continue
            }

            Log "Minimizing: $title"

            [WindowAPI]::ShowWindow(
                $proc.MainWindowHandle,
                [WindowAPI]::SW_MINIMIZE
            ) | Out-Null

        }
        catch {
            Log "Could not minimize PID=$($proc.Id): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 1

    # ========================================================
    # MAXIMIZE CHROME
    # ========================================================

    Log "Maximizing Chrome..."

    [WindowAPI]::ShowWindow(
        $chromeWindow,
        [WindowAPI]::SW_MAXIMIZE
    ) | Out-Null

    Start-Sleep -Milliseconds 700

    [WindowAPI]::SetForegroundWindow(
        $chromeWindow
    ) | Out-Null

    Start-Sleep -Milliseconds 700

    [System.Windows.Forms.Application]::DoEvents()

    # ========================================================
    # RED CIRCLE
    # ========================================================

    Log "Creating red click marker..."

    $circleSize = 8

    $clickX = 84
    $clickY = 614

    $circleLeft = $clickX - [int]($circleSize / 2)
    $circleTop  = $clickY - [int]($circleSize / 2)

    $redCircle =
        New-Object RedCircleForm

    $redCircle.Width = $circleSize
    $redCircle.Height = $circleSize

    $redCircle.Location =
        New-Object System.Drawing.Point(
            $circleLeft,
            $circleTop
        )

    $redCircle.Show()

    [System.Windows.Forms.Application]::DoEvents()

    Log "Circle size: $circleSize x $circleSize"
    Log "Circle center: X=$clickX Y=$clickY"
    Log "Circle position: X=$circleLeft Y=$circleTop"

    Start-Sleep -Milliseconds 500

    # ========================================================
    # FIND FFMPEG
    # ========================================================

    Log "Searching for FFmpeg..."

    $ffmpegCommand =
        Get-Command ffmpeg.exe `
            -ErrorAction SilentlyContinue

    if ($null -eq $ffmpegCommand) {
        throw "ffmpeg.exe was not found in PATH."
    }

    $ffmpegPath = $ffmpegCommand.Source

    Log "FFmpeg path: $ffmpegPath"

    # ========================================================
    # START RECORDING
    # ========================================================

    Log "Starting FFmpeg desktop recording..."

    $ffmpegArgs = @(
        "-y"
        "-loglevel", "warning"

        "-f", "gdigrab"
        "-framerate", "10"
        "-draw_mouse", "1"
        "-i", "desktop"

        "-t", "15"

        "-c:v", "libx264"
        "-preset", "ultrafast"
        "-pix_fmt", "yuv420p"

        "-movflags", "+faststart"

        $videoPath
    )

    $ffmpegProcess =
        Start-Process `
            -FilePath $ffmpegPath `
            -ArgumentList $ffmpegArgs `
            -RedirectStandardOutput $ffmpegOut `
            -RedirectStandardError $ffmpegErr `
            -PassThru `
            -WindowStyle Hidden

    if ($null -eq $ffmpegProcess) {
        throw "FFmpeg process failed to start."
    }

    Log "FFmpeg PID: $($ffmpegProcess.Id)"

    # ========================================================
    # PRE-CLICK RECORDING
    # ========================================================

    Log "Recording 5 seconds before click..."

    Start-Sleep -Seconds 5

    # ========================================================
    # MOVE MOUSE
    # ========================================================

    Log "Moving mouse to X=$clickX Y=$clickY..."

    $mouseResult =
        [MouseAPI]::SetCursorPos(
            $clickX,
            $clickY
        )

    Log "SetCursorPos result: $mouseResult"

    Start-Sleep -Milliseconds 500

    # ========================================================
    # CLICK
    # ========================================================

    Log "Performing left click..."

    [MouseAPI]::mouse_event(
        [MouseAPI]::MOUSEEVENTF_LEFTDOWN,
        0,
        0,
        0,
        [UIntPtr]::Zero
    )

    Start-Sleep -Milliseconds 100

    [MouseAPI]::mouse_event(
        [MouseAPI]::MOUSEEVENTF_LEFTUP,
        0,
        0,
        0,
        [UIntPtr]::Zero
    )

    Log "CLICK COMPLETED."

    # ========================================================
    # SCREENSHOT
    # ========================================================

    Start-Sleep -Milliseconds 500

    [System.Windows.Forms.Application]::DoEvents()

    Log "Capturing screenshot..."

    $bitmap =
        New-Object System.Drawing.Bitmap(
            $screenBounds.Width,
            $screenBounds.Height
        )

    $graphics =
        [System.Drawing.Graphics]::FromImage(
            $bitmap
        )

    $graphics.CopyFromScreen(
        $screenBounds.Location,
        [System.Drawing.Point]::Empty,
        $screenBounds.Size
    )

    $bitmap.Save(
        $screenshotPath,
        [System.Drawing.Imaging.ImageFormat]::Png
    )

    $graphics.Dispose()
    $bitmap.Dispose()

    Log "Screenshot saved: $screenshotPath"

    # ========================================================
    # POST-CLICK RECORDING
    # ========================================================

    Log "Continuing recording..."

    Start-Sleep -Seconds 8

    # ========================================================
    # REMOVE CIRCLE
    # ========================================================

    if ($redCircle) {

        Log "Removing red circle..."

        $redCircle.Close()
        $redCircle.Dispose()

        $redCircle = $null

        [System.Windows.Forms.Application]::DoEvents()
    }

    # ========================================================
    # WAIT FOR FFMPEG
    # ========================================================

    if ($ffmpegProcess) {

        Log "Waiting for FFmpeg to exit..."

        $ffmpegProcess.WaitForExit()

        Log "FFmpeg exit code: $($ffmpegProcess.ExitCode)"

        if ($ffmpegProcess.ExitCode -ne 0) {

            Log "=== FFMPEG STDERR ==="

            if (Test-Path $ffmpegErr) {

                Get-Content $ffmpegErr |
                    ForEach-Object {
                        Log $_
                    }
            }

            throw `
                "FFmpeg failed with exit code $($ffmpegProcess.ExitCode)."
        }
    }

    # ========================================================
    # VERIFY VIDEO
    # ========================================================

    Log "Checking video file..."

    if (-not (Test-Path $videoPath)) {
        throw "Video file was not created: $videoPath"
    }

    $videoInfo =
        Get-Item $videoPath

    Log "Video size: $($videoInfo.Length) bytes"

    if ($videoInfo.Length -lt 10000) {
        throw "Video file is suspiciously small."
    }

    # ========================================================
    # VERIFY SCREENSHOT
    # ========================================================

    Log "Checking screenshot file..."

    if (-not (Test-Path $screenshotPath)) {
        throw "Screenshot file was not created: $screenshotPath"
    }

    $screenshotInfo =
        Get-Item $screenshotPath

    Log "Screenshot size: $($screenshotInfo.Length) bytes"

    # ========================================================
    # FFPROBE
    # ========================================================

    $ffprobeCommand =
        Get-Command ffprobe.exe `
            -ErrorAction SilentlyContinue

    if ($null -ne $ffprobeCommand) {

        Log "Running ffprobe..."

        $probe =
            & $ffprobeCommand.Source `
                -v error `
                -show_entries format=duration,size `
                -show_entries stream=codec_name,width,height,pix_fmt `
                -of default=noprint_wrappers=1 `
                $videoPath 2>&1

        foreach ($line in $probe) {
            Log "FFPROBE: $line"
        }
    }
    else {
        Log "ffprobe.exe not found. Skipping ffprobe."
    }

    # ========================================================
    # FINAL FILE LIST
    # ========================================================

    Log "========================================"
    Log "FINAL OUTPUT FILES"
    Log "========================================"

    Get-ChildItem `
        -Path $outputDir `
        -File |
        ForEach-Object {
            Log "$($_.Name) -> $($_.Length) bytes"
        }

    Log "========================================"
    Log "RECORDING SUCCESS"
    Log "========================================"

    exit 0
}
catch {

    Log "========================================"
    Log "FATAL ERROR"
    Log "========================================"

    Log $_.Exception.ToString()

    # --------------------------------------------------------
    # Remove circle
    # --------------------------------------------------------

    if ($redCircle) {

        try {
            $redCircle.Close()
            $redCircle.Dispose()
        }
        catch {}
    }

    # --------------------------------------------------------
    # Stop FFmpeg
    # --------------------------------------------------------

    if ($ffmpegProcess) {

        try {

            if (-not $ffmpegProcess.HasExited) {

                Log "Stopping FFmpeg..."

                Stop-Process `
                    -Id $ffmpegProcess.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

        }
        catch {}
    }

    # --------------------------------------------------------
    # Save any available FFmpeg error
    # --------------------------------------------------------

    if (Test-Path $ffmpegErr) {

        Log "=== FFMPEG ERROR LOG ==="

        Get-Content $ffmpegErr |
            ForEach-Object {
                Log $_
            }
    }

    # --------------------------------------------------------
    # Save final directory state
    # --------------------------------------------------------

    try {

        Log "========================================"
        Log "FILES PRESENT AFTER FAILURE"
        Log "========================================"

        Get-ChildItem `
            -Path $outputDir `
            -File `
            -ErrorAction SilentlyContinue |
            ForEach-Object {
                Log "$($_.Name) -> $($_.Length) bytes"
            }
    }
    catch {}

    exit 99
}
