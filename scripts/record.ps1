# ============================================================
# ASSEMBLIES
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
# WINDOW API
# ============================================================

Add-Type -ReferencedAssemblies @(
    "System.Windows.Forms.dll",
    "System.Drawing.dll"
) @"
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
# RED CIRCLE WINDOW
# ============================================================

Add-Type -ReferencedAssemblies @(
    "System.Windows.Forms.dll",
    "System.Drawing.dll"
) @"
using System;
using System.Drawing;
using System.Windows.Forms;

public class RedCircleForm : Form
{
    public RedCircleForm()
    {
        this.FormBorderStyle = FormBorderStyle.None;
        this.StartPosition = FormStartPosition.Manual;
        this.ShowInTaskbar = false;
        this.TopMost = true;

        this.BackColor = Color.Magenta;
        this.TransparencyKey = Color.Magenta;

        this.Width = 8;
        this.Height = 8;

        this.DoubleBuffered = true;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;

            cp.ExStyle |= 0x80;
            cp.ExStyle |= 0x08000000;
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
                this.Width - 1,
                this.Height - 1
            );
        }
    }
}
"@

# ============================================================
# PATHS
# ============================================================

$videoPath = "C:\temp\rdp-click-video.mp4"
$screenshotPath = "C:\temp\rdp-click-screenshot.png"
$logFile = "C:\temp\click-record.log"
$ffmpegOut = "C:\temp\ffmpeg-output.log"
$ffmpegErr = "C:\temp\ffmpeg-error.log"

New-Item `
    -ItemType Directory `
    -Path "C:\temp" `
    -Force |
    Out-Null

# ============================================================
# LOG
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
        -Path $logFile `
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

    Log "Video: $videoPath"
    Log "Screenshot: $screenshotPath"
    Log "Log: $logFile"

    # ========================================================
    # SCREEN
    # ========================================================

    Log "Checking primary screen..."

    $screen =
        [System.Windows.Forms.Screen]::PrimaryScreen

    if ($null -eq $screen) {
        throw "PrimaryScreen is null."
    }

    $screenBounds = $screen.Bounds

    Log "Screen X=$($screenBounds.X)"
    Log "Screen Y=$($screenBounds.Y)"
    Log "Screen Width=$($screenBounds.Width)"
    Log "Screen Height=$($screenBounds.Height)"

    if (
        $screenBounds.Width -le 0 -or
        $screenBounds.Height -le 0
    ) {
        throw "Invalid screen dimensions."
    }

    # ========================================================
    # CLICK COORDINATES
    # ========================================================

    $clickX = 84
    $clickY = 614

    if ($env:CLICK_X) {
        [int]$clickX = $env:CLICK_X
    }

    if ($env:CLICK_Y) {
        [int]$clickY = $env:CLICK_Y
    }

    Log "Click coordinates: X=$clickX Y=$clickY"

    if (
        $clickX -lt 0 -or
        $clickY -lt 0 -or
        $clickX -ge $screenBounds.Width -or
        $clickY -ge $screenBounds.Height
    ) {
        throw "Click coordinates are outside the primary screen."
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

    $chrome =
        $chromeProcesses |
        Sort-Object StartTime -Descending |
        Select-Object -First 1

    $chromeWindow =
        $chrome.MainWindowHandle

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

    $chromeTitle =
        $titleBuilder.ToString()

    Log "Selected Chrome window: $chromeTitle"
    Log "Chrome PID: $($chrome.Id)"
    Log "Chrome Handle: $chromeWindow"

    # ========================================================
    # MINIMIZE OTHER APPLICATIONS
    # ========================================================

    Log "Minimizing other applications..."

    $allProcesses =
        Get-Process -ErrorAction SilentlyContinue

    foreach ($proc in $allProcesses) {

        try {

            if ($proc.MainWindowHandle -eq [IntPtr]::Zero) {
                continue
            }

            if ($proc.Id -eq $chrome.Id) {
                continue
            }

            $title =
                $proc.MainWindowTitle

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
    # CREATE RED CIRCLE
    # ========================================================

    Log "Creating red click marker..."

    $circleSize = 8

    $circleLeft =
        $clickX - [int]($circleSize / 2)

    $circleTop =
        $clickY - [int]($circleSize / 2)

    $redCircle =
        New-Object RedCircleForm

    $redCircle.Width =
        $circleSize

    $redCircle.Height =
        $circleSize

    $redCircle.Location =
        New-Object System.Drawing.Point(
            $circleLeft,
            $circleTop
        )

    $redCircle.Show()

    [System.Windows.Forms.Application]::DoEvents()

    Log "Circle created successfully."
    Log "Circle size: $circleSize x $circleSize"
    Log "Circle center: X=$clickX Y=$clickY"
    Log "Circle top-left: X=$circleLeft Y=$circleTop"

    Start-Sleep -Milliseconds 700

    # ========================================================
    # CHECK FFMPEG
    # ========================================================

    Log "Searching for FFmpeg..."

    $ffmpegCommand =
        Get-Command ffmpeg.exe `
            -ErrorAction SilentlyContinue

    if ($null -eq $ffmpegCommand) {
        throw "ffmpeg.exe was not found in PATH."
    }

    $ffmpegPath =
        $ffmpegCommand.Source

    Log "FFmpeg path: $ffmpegPath"

    # ========================================================
    # START FFMPEG
    # ========================================================

    Log "Starting FFmpeg desktop capture..."

    $ffmpegArgs = @(
        "-y"
        "-hide_banner"
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

    Log "FFmpeg command:"
    Log "ffmpeg $($ffmpegArgs -join ' ')"

    $ffmpegProcess =
        Start-Process `
            -FilePath $ffmpegPath `
            -ArgumentList $ffmpegArgs `
            -RedirectStandardOutput $ffmpegOut `
            -RedirectStandardError $ffmpegErr `
            -PassThru `
            -WindowStyle Hidden

    if ($null -eq $ffmpegProcess) {
        throw "FFmpeg failed to start."
    }

    Log "FFmpeg PID: $($ffmpegProcess.Id)"

    # ========================================================
    # RECORD BEFORE CLICK
    # ========================================================

    Log "Recording 5 seconds before click..."

    Start-Sleep -Seconds 5

    # ========================================================
    # MOVE CURSOR
    # ========================================================

    Log "Moving cursor to X=$clickX Y=$clickY..."

    $cursorResult =
        [MouseAPI]::SetCursorPos(
            $clickX,
            $clickY
        )

    Log "SetCursorPos result: $cursorResult"

    Start-Sleep -Milliseconds 500

    # ========================================================
    # CLICK
    # ========================================================

    Log "CLICKING..."

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

    Log "Taking screenshot..."

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

    Log "Screenshot saved successfully."

    # ========================================================
    # REMAINING RECORDING
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

        Log "Red circle removed."
    }

    # ========================================================
    # WAIT FOR FFMPEG
    # ========================================================

    if ($ffmpegProcess) {

        Log "Waiting for FFmpeg..."

        $ffmpegProcess.WaitForExit()

        Log "FFmpeg exit code: $($ffmpegProcess.ExitCode)"

        if ($ffmpegProcess.ExitCode -ne 0) {

            Log "=== FFMPEG ERROR ==="

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

    Log "Checking video..."

    if (-not (Test-Path $videoPath)) {
        throw "Video was not created: $videoPath"
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

    Log "Checking screenshot..."

    if (-not (Test-Path $screenshotPath)) {
        throw "Screenshot was not created: $screenshotPath"
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

    # ========================================================
    # SUCCESS
    # ========================================================

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

    if ($redCircle) {

        try {
            $redCircle.Close()
            $redCircle.Dispose()
        }
        catch {}
    }

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

    if (Test-Path $ffmpegErr) {

        Log "=== FFMPEG ERROR LOG ==="

        Get-Content $ffmpegErr |
            ForEach-Object {
                Log $_
            }
    }

    Log "========================================"
    Log "FILES PRESENT AFTER FAILURE"
    Log "========================================"

    Get-ChildItem `
        "C:\temp" `
        -File `
        -ErrorAction SilentlyContinue |
        ForEach-Object {

            Log "$($_.Name) -> $($_.Length) bytes"
        }

    exit 99
}
