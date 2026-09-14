Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

$logFile = "C:\temp\click-record.log"

function Log {
    param(
        [string]$Message
    )

    $line = "[{0}] {1}" -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), `
        $Message

    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

$ffmpegProcess = $null
$redDot = $null

try {

    Log "========================================"
    Log "Recording script started"
    Log "========================================"

    # --------------------------------------------------------
    # FIND CHROME
    # --------------------------------------------------------

    $chromeProcesses = Get-Process chrome -ErrorAction SilentlyContinue

    if (-not $chromeProcesses) {
        throw "Chrome process was not found."
    }

    $chromePids = @(
        $chromeProcesses |
        Select-Object -ExpandProperty Id
    )

    Log "Chrome PIDs: $($chromePids -join ', ')"

    # --------------------------------------------------------
    # MINIMIZE OTHER WINDOWS
    # --------------------------------------------------------

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

                $title = $titleBuilder.ToString()

                if ([string]::IsNullOrWhiteSpace($title)) {
                    return $true
                }

                [uint32]$windowProcessId = 0

                [WindowAPI]::GetWindowThreadProcessId(
                    $hWnd,
                    [ref]$windowProcessId
                ) | Out-Null

                if ($chromePids -contains [int]$windowProcessId) {
                    return $true
                }

                Log "Minimizing window: $title"

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

    # --------------------------------------------------------
    # FIND CHROME WINDOW
    # --------------------------------------------------------

    $chromeWindow = [IntPtr]::Zero

    [WindowAPI]::EnumWindows(
        {
            param(
                [IntPtr]$hWnd,
                [IntPtr]$lParam
            )

            if (-not [WindowAPI]::IsWindowVisible($hWnd)) {
                return $true
            }

            [uint32]$windowProcessId = 0

            [WindowAPI]::GetWindowThreadProcessId(
                $hWnd,
                [ref]$windowProcessId
            ) | Out-Null

            if ($chromePids -contains [int]$windowProcessId) {

                $titleBuilder =
                    New-Object System.Text.StringBuilder 512

                [WindowAPI]::GetWindowText(
                    $hWnd,
                    $titleBuilder,
                    512
                ) | Out-Null

                $title = $titleBuilder.ToString()

                if (-not [string]::IsNullOrWhiteSpace($title)) {

                    $script:chromeWindow = $hWnd

                    Log "Chrome window found: $title"

                    return $false
                }
            }

            return $true
        },
        [IntPtr]::Zero
    ) | Out-Null

    if ($chromeWindow -eq [IntPtr]::Zero) {
        throw "Chrome top-level window was not found."
    }

    # --------------------------------------------------------
    # MAXIMIZE CHROME
    # --------------------------------------------------------

    [WindowAPI]::ShowWindow(
        $chromeWindow,
        [WindowAPI]::SW_MAXIMIZE
    ) | Out-Null

    Start-Sleep -Milliseconds 500

    [WindowAPI]::SetForegroundWindow(
        $chromeWindow
    ) | Out-Null

    Start-Sleep -Milliseconds 500

    # --------------------------------------------------------
    # RED DOT
    # Center = exactly 84,614
    # --------------------------------------------------------

    Log "Creating red click marker."

    $redDot =
        New-Object System.Windows.Forms.Form

    $redDot.FormBorderStyle =
        [System.Windows.Forms.FormBorderStyle]::None

    $redDot.StartPosition =
        [System.Windows.Forms.FormStartPosition]::Manual

    $redDot.Location =
        New-Object System.Drawing.Point(79,609)

    $redDot.Size =
        New-Object System.Drawing.Size(10,10)

    $redDot.BackColor =
        [System.Drawing.Color]::Red

    $redDot.TopMost = $true
    $redDot.ShowInTaskbar = $false

    $redDot.Show()

    [System.Windows.Forms.Application]::DoEvents()

    Log "Red dot center = X=84 Y=614"

    # --------------------------------------------------------
    # FILES
    # --------------------------------------------------------

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

    # --------------------------------------------------------
    # START FFMPEG
    # --------------------------------------------------------

    Log "Starting FFmpeg."

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

    $ffmpegProcess = Start-Process `
        -FilePath "ffmpeg.exe" `
        -ArgumentList $ffmpegArgs `
        -RedirectStandardOutput $ffmpegOut `
        -RedirectStandardError $ffmpegErr `
        -PassThru `
        -WindowStyle Hidden

    if (-not $ffmpegProcess) {
        throw "Could not start FFmpeg."
    }

    Log "FFmpeg PID: $($ffmpegProcess.Id)"

    # --------------------------------------------------------
    # WAIT 5 SECONDS
    # --------------------------------------------------------

    Log "Waiting 5 seconds..."

    Start-Sleep -Seconds 5

    # --------------------------------------------------------
    # CLICK EXACTLY 84,614
    # --------------------------------------------------------

    Log "Moving cursor to X=84 Y=614."

    [MouseAPI]::SetCursorPos(
        84,
        614
    ) | Out-Null

    Start-Sleep -Milliseconds 250

    Log "LEFT DOWN."

    [MouseAPI]::mouse_event(
        [MouseAPI]::MOUSEEVENTF_LEFTDOWN,
        0,
        0,
        0,
        [UIntPtr]::Zero
    )

    Start-Sleep -Milliseconds 80

    Log "LEFT UP."

    [MouseAPI]::mouse_event(
        [MouseAPI]::MOUSEEVENTF_LEFTUP,
        0,
        0,
        0,
        [UIntPtr]::Zero
    )

    Log "Click completed."

    # --------------------------------------------------------
    # SCREENSHOT
    # --------------------------------------------------------

    Start-Sleep -Milliseconds 500

    Log "Taking screenshot."

    $screenBounds =
        [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

    $bitmap =
        New-Object System.Drawing.Bitmap(
            $screenBounds.Width,
            $screenBounds.Height
        )

    $graphics =
        [System.Drawing.Graphics]::FromImage($bitmap)

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

    # --------------------------------------------------------
    # CONTINUE RECORDING 10 SECONDS
    # --------------------------------------------------------

    Log "Waiting remaining 10 seconds."

    Start-Sleep -Seconds 10

    # --------------------------------------------------------
    # CLOSE RED DOT
    # --------------------------------------------------------

    if ($redDot) {

        Log "Closing red dot."

        $redDot.Close()
        $redDot.Dispose()

        $redDot = $null
    }

    # --------------------------------------------------------
    # WAIT FFMPEG
    # --------------------------------------------------------

    if ($ffmpegProcess) {

        Log "Waiting for FFmpeg."

        $ffmpegProcess.WaitForExit()

        Log "FFmpeg exit code: $($ffmpegProcess.ExitCode)"
    }

    # --------------------------------------------------------
    # VERIFY VIDEO
    # --------------------------------------------------------

    if (-not (Test-Path $videoPath)) {
        throw "Video file was not created."
    }

    $videoInfo = Get-Item $videoPath

    Log "Video size: $($videoInfo.Length) bytes"

    if ($videoInfo.Length -lt 10000) {
        throw "Video file is suspiciously small."
    }

    # --------------------------------------------------------
    # VERIFY SCREENSHOT
    # --------------------------------------------------------

    if (-not (Test-Path $screenshotPath)) {
        throw "Screenshot was not created."
    }

    $screenshotInfo =
        Get-Item $screenshotPath

    Log "Screenshot size: $($screenshotInfo.Length) bytes"

    # --------------------------------------------------------
    # FFPROBE
    # --------------------------------------------------------

    Log "Running ffprobe."

    $ffprobeOutput = & ffprobe `
        -v error `
        -show_entries format=duration,size `
        -of default=noprint_wrappers=1 `
        $videoPath 2>&1

    Add-Content `
        -Path $logFile `
        -Value ($ffprobeOutput -join [Environment]::NewLine)

    Log "========================================"
    Log "Recording completed successfully."
    Log "========================================"

    exit 0
}
catch {

    Log "========================================"
    Log "ERROR"
    Log $_.Exception.Message
    Log "========================================"

    if ($redDot) {
        try {
            $redDot.Close()
            $redDot.Dispose()
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
