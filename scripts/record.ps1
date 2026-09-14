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
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(
        EnumWindowsProc lpEnumFunc,
        IntPtr lParam
    );

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(
        IntPtr hWnd
    );

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(
        IntPtr hWnd,
        StringBuilder lpString,
        int nMaxCount
    );

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(
        IntPtr hWnd,
        out uint lpdwProcessId
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
# CLICK-THROUGH CIRCLE WINDOW
# ============================================================

Add-Type @"
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
        // HTTRANSPARENT
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

        using (Brush brush = new SolidBrush(Color.Red))
        {
            e.Graphics.SmoothingMode =
                System.Drawing.Drawing2D.SmoothingMode.AntiAlias;

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
# LOG
# ============================================================

$logFile = "C:\temp\click-record.log"

function Log {
    param(
        [string]$Message
    )

    $line = "[{0}] {1}" -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), `
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

    New-Item `
        -ItemType Directory `
        -Path "C:\temp" `
        -Force |
        Out-Null

    Log "========================================"
    Log "RECORDING SCRIPT STARTED"
    Log "========================================"

    # ========================================================
    # FIND CHROME
    # ========================================================

    $chromeProcesses =
        Get-Process chrome `
        -ErrorAction SilentlyContinue

    if (-not $chromeProcesses) {
        throw "Chrome process was not found."
    }

    $chromePids = @(
        $chromeProcesses |
        Select-Object -ExpandProperty Id
    )

    Log "Chrome process count: $($chromePids.Count)"

    foreach ($chromePid in $chromePids) {
        Log "Chrome PID: $chromePid"
    }

    # ========================================================
    # MINIMIZE EVERYTHING EXCEPT CHROME
    # ========================================================

    Log "Minimizing non-Chrome windows..."

    [WindowAPI]::EnumWindows(
        {
            param(
                [IntPtr]$hWnd,
                [IntPtr]$lParam
            )

            try {

                if (-not [WindowAPI]::IsWindowVisible($hWnd)) {
                    return $true
                }

                $titleBuilder =
                    New-Object System.Text.StringBuilder 512

                [WindowAPI]::GetWindowText(
                    $hWnd,
                    $titleBuilder,
                    512
                ) | Out-Null

                $title =
                    $titleBuilder.ToString()

                if ([string]::IsNullOrWhiteSpace($title)) {
                    return $true
                }

                [uint32]$windowProcessId = 0

                [WindowAPI]::GetWindowThreadProcessId(
                    $hWnd,
                    [ref]$windowProcessId
                ) | Out-Null

                if (
                    $chromePids -contains
                    [int]$windowProcessId
                ) {
                    return $true
                }

                Log "Minimizing: $title"

                [WindowAPI]::ShowWindow(
                    $hWnd,
                    [WindowAPI]::SW_MINIMIZE
                ) | Out-Null

            }
            catch {

                Log "Window error: $($_.Exception.Message)"
            }

            return $true

        },
        [IntPtr]::Zero
    ) | Out-Null

    Start-Sleep -Seconds 1

    # ========================================================
    # FIND CHROME WINDOW
    # ========================================================

    $chromeWindow =
        [IntPtr]::Zero

    [WindowAPI]::EnumWindows(
        {
            param(
                [IntPtr]$hWnd,
                [IntPtr]$lParam
            )

            if (
                -not
                [WindowAPI]::IsWindowVisible($hWnd)
            ) {
                return $true
            }

            [uint32]$windowProcessId = 0

            [WindowAPI]::GetWindowThreadProcessId(
                $hWnd,
                [ref]$windowProcessId
            ) | Out-Null

            if (
                $chromePids -contains
                [int]$windowProcessId
            ) {

                $titleBuilder =
                    New-Object System.Text.StringBuilder 512

                [WindowAPI]::GetWindowText(
                    $hWnd,
                    $titleBuilder,
                    512
                ) | Out-Null

                $title =
                    $titleBuilder.ToString()

                if (
                    -not
                    [string]::IsNullOrWhiteSpace($title)
                ) {

                    $script:chromeWindow = $hWnd

                    Log "Chrome window found: $title"

                    return $false
                }
            }

            return $true

        },
        [IntPtr]::Zero
    ) | Out-Null

    if (
        $chromeWindow -eq
        [IntPtr]::Zero
    ) {
        throw "Chrome top-level window was not found."
    }

    # ========================================================
    # MAXIMIZE CHROME
    # ========================================================

    Log "Maximizing Chrome..."

    [WindowAPI]::ShowWindow(
        $chromeWindow,
        [WindowAPI]::SW_MAXIMIZE
    ) | Out-Null

    Start-Sleep -Milliseconds 500

    [WindowAPI]::SetForegroundWindow(
        $chromeWindow
    ) | Out-Null

    Start-Sleep -Milliseconds 500

    # ========================================================
    # CREATE VERY SMALL RED CIRCLE
    # ========================================================

    Log "Creating small red circle..."

    $redCircle =
        New-Object RedCircleForm

    # --------------------------------------------------------
    # Circle size
    # --------------------------------------------------------
    #
    # 8x8 pixels
    #
    # Center = 84,614
    #
    # Left = 84 - 4 = 80
    # Top  = 614 - 4 = 610
    #
    # --------------------------------------------------------

    $redCircle.Width = 8
    $redCircle.Height = 8

    $redCircle.Location =
        New-Object System.Drawing.Point(
            80,
            610
        )

    $redCircle.Show()

    [System.Windows.Forms.Application]::DoEvents()

    Log "Small circular marker center = X=84 Y=614"

    # ========================================================
    # OUTPUT FILES
    # ========================================================

    $videoPath =
        "C:\temp\rdp-click-video.mp4"

    $screenshotPath =
        "C:\temp\rdp-click-screenshot.png"

    $ffmpegOut =
        "C:\temp\ffmpeg-output.log"

    $ffmpegErr =
        "C:\temp\ffmpeg-error.log"

    Remove-Item `
        $videoPath,
        $screenshotPath,
        $ffmpegOut,
        $ffmpegErr `
        -Force `
        -ErrorAction SilentlyContinue

    # ========================================================
    # START FFMPEG
    # ========================================================

    Log "Starting FFmpeg..."

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
            -FilePath "ffmpeg.exe" `
            -ArgumentList $ffmpegArgs `
            -RedirectStandardOutput $ffmpegOut `
            -RedirectStandardError $ffmpegErr `
            -PassThru `
            -WindowStyle Hidden

    if (-not $ffmpegProcess) {
        throw "FFmpeg failed to start."
    }

    Log "FFmpeg PID: $($ffmpegProcess.Id)"

    # ========================================================
    # 5 SECONDS BEFORE CLICK
    # ========================================================

    Log "Recording 5 seconds before click..."

    Start-Sleep -Seconds 5

    # ========================================================
    # MOVE CURSOR
    # ========================================================

    Log "Moving mouse to X=84 Y=614..."

    [MouseAPI]::SetCursorPos(
        84,
        614
    ) | Out-Null

    Start-Sleep -Milliseconds 300

    # ========================================================
    # CLICK
    # ========================================================

    Log "Clicking X=84 Y=614..."

    [MouseAPI]::mouse_event(
        [MouseAPI]::MOUSEEVENTF_LEFTDOWN,
        0,
        0,
        0,
        [UIntPtr]::Zero
    )

    Start-Sleep -Milliseconds 80

    [MouseAPI]::mouse_event(
        [MouseAPI]::MOUSEEVENTF_LEFTUP,
        0,
        0,
        0,
        [UIntPtr]::Zero
    )

    Log "Click completed."

    # ========================================================
    # SCREENSHOT 0.5 SEC AFTER CLICK
    # ========================================================

    Start-Sleep -Milliseconds 500

    Log "Taking screenshot..."

    $screenBounds =
        [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

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

    Log "Screenshot saved."

    # ========================================================
    # 10 SECONDS AFTER CLICK
    # ========================================================

    Log "Continuing recording for 10 seconds..."

    Start-Sleep -Seconds 10

    # ========================================================
    # REMOVE RED CIRCLE
    # ========================================================

    if ($redCircle) {

        Log "Removing red circle..."

        $redCircle.Close()

        $redCircle.Dispose()

        $redCircle = $null
    }

    # ========================================================
    # WAIT FOR FFMPEG
    # ========================================================

    if ($ffmpegProcess) {

        Log "Waiting for FFmpeg..."

        $ffmpegProcess.WaitForExit()

        Log "FFmpeg exit code: $($ffmpegProcess.ExitCode)"

        if (
            $ffmpegProcess.ExitCode -ne 0
        ) {

            if (Test-Path $ffmpegErr) {

                Log "=== FFMPEG ERROR ==="

                Get-Content `
                    $ffmpegErr |
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

    if (-not (Test-Path $videoPath)) {

        throw "Video file was not created."
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

    if (-not (Test-Path $screenshotPath)) {

        throw "Screenshot was not created."
    }

    $screenshotInfo =
        Get-Item $screenshotPath

    Log "Screenshot size: $($screenshotInfo.Length) bytes"

    # ========================================================
    # FFPROBE
    # ========================================================

    Log "Running ffprobe..."

    $probe =
        & ffprobe `
            -v error `
            -show_entries format=duration,size `
            -show_entries stream=codec_name,width,height,pix_fmt `
            -of default=noprint_wrappers=1 `
            $videoPath 2>&1

    foreach ($line in $probe) {
        Log "FFPROBE: $line"
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

                Stop-Process `
                    -Id $ffmpegProcess.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

        }
        catch {}
    }

    exit 99
}
