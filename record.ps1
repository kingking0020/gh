$ErrorActionPreference = "Stop"

$logFile        = "C:\temp\click-record.log"
$videoFile      = "C:\temp\rdp-click-video.mp4"
$screenshotFile = "C:\temp\rdp-click-screenshot.png"
$ffmpegOutput   = "C:\temp\ffmpeg-output.log"
$ffmpegError    = "C:\temp\ffmpeg-error.log"

function Log($text) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')  $text"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeWin {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public const int SW_RESTORE = 9;
    public const int SW_MAXIMIZE = 3;
}
"@

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$screen = [System.Windows.Forms.Screen]::PrimaryScreen
if ($null -eq $screen) { throw "Primary screen null" }

$screenX = $screen.Bounds.X
$screenY = $screen.Bounds.Y
$width   = $screen.Bounds.Width
$height  = $screen.Bounds.Height

Log "Screen: X=$screenX Y=$screenY W=$width H=$height"

Log "Finding Chrome window..."
$chromeWindow = $null
for ($attempt = 1; $attempt -le 20; $attempt++) {
    $chromeWindow = Get-Process chrome -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1
    if ($null -ne $chromeWindow) { break }
    Start-Sleep -Milliseconds 500
}
if ($null -eq $chromeWindow) { throw "Chrome window not found" }

[NativeWin]::ShowWindow($chromeWindow.MainWindowHandle, [NativeWin]::SW_RESTORE) | Out-Null
Start-Sleep -Milliseconds 300
[NativeWin]::ShowWindow($chromeWindow.MainWindowHandle, [NativeWin]::SW_MAXIMIZE) | Out-Null
Start-Sleep -Milliseconds 500
[NativeWin]::SetForegroundWindow($chromeWindow.MainWindowHandle) | Out-Null
Start-Sleep -Seconds 1
Log "Chrome maximized."

Remove-Item $videoFile -Force -ErrorAction SilentlyContinue
Remove-Item $screenshotFile -Force -ErrorAction SilentlyContinue
Remove-Item $ffmpegOutput -Force -ErrorAction SilentlyContinue
Remove-Item $ffmpegError -Force -ErrorAction SilentlyContinue

Log "Starting 20s FFmpeg recording..."

$ffmpegArgs = @(
    "-y",
    "-f", "gdigrab",
    "-framerate", "30",
    "-draw_mouse", "1",
    "-i", "desktop",
    "-t", "20",
    "-c:v", "libx264",
    "-preset", "veryfast",
    "-pix_fmt", "yuv420p",
    $videoFile
)

$ffmpegProcess = Start-Process -FilePath "ffmpeg.exe" -ArgumentList $ffmpegArgs -PassThru -RedirectStandardOutput $ffmpegOutput -RedirectStandardError $ffmpegError
Log "FFmpeg PID = $($ffmpegProcess.Id)"

Log "Waiting 5 seconds before typing..."
Start-Sleep -Seconds 5

# ==========================================================
# TYPE INTO ELEMENT VIA CDP
# ==========================================================

$nanoAddress     = "nano_39zkq6o8tkqpmsg5f3csyzs4oy66sofuerbdyeagaxih5pzea3956q3619no"
$elementSelector = "address"

Log "Connecting to Chrome DevTools..."

$targets = $null
for ($i = 0; $i -lt 20; $i++) {
    try {
        $targets = Invoke-RestMethod "http://localhost:9222/json"
        if ($targets) { break }
    } catch {}
    Start-Sleep -Milliseconds 500
}
if (-not $targets) { throw "Cannot connect to debug port 9222" }

$page = $targets | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
if (-not $page) { throw "No active page" }
Log "Page: $($page.url)"

$wsUrl = $page.webSocketDebuggerUrl
Log "WS: $wsUrl"

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [System.Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$wsUrl, $ct).Wait()
Log "WS connected."

$js = "(function(){ var el = document.getElementById('" + $elementSelector + "'); if (!el) return 'NOT_FOUND'; el.focus(); var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set; setter.call(el, '" + $nanoAddress + "'); el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); el.dispatchEvent(new Event('blur', {bubbles:true})); return 'OK: ' + el.value; })()"

$msg = @{
    id = 1
    method = "Runtime.evaluate"
    params = @{ expression = $js; returnByValue = $true }
} | ConvertTo-Json -Compress -Depth 10

Log "Sending CDP command..."

$bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
$seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
$ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()

$buf = New-Object byte[] 16384
$recvSeg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)
$result = $ws.ReceiveAsync($recvSeg, $ct).Result
$resp = [System.Text.Encoding]::UTF8.GetString($buf, 0, $result.Count)

Log "CDP Response: $resp"

$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $ct).Wait()
$ws.Dispose()
Log "Typing COMPLETED."

Log "Waiting 10 more seconds..."
Start-Sleep -Seconds 10

Log "Waiting for FFmpeg..."
if (-not $ffmpegProcess.HasExited) { $ffmpegProcess.WaitForExit() }
Log "FFmpeg exit code = $($ffmpegProcess.ExitCode)"

if (-not (Test-Path $videoFile)) { throw "Video missing" }
Log "Video size = $((Get-Item $videoFile).Length) bytes"

# ==========================================================
# FINAL SCREENSHOT
# ==========================================================
Log "Final screenshot..."

$bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($screenX, $screenY, 0, 0, $screen.Bounds.Size)

$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Red, 3)
$brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(140, 255, 0, 0))

$dotX = [int]($width / 2)
$dotY = [int]($height / 2)
$radius = 8

$graphics.FillEllipse($brush, ($dotX - $radius), ($dotY - $radius), ($radius * 2), ($radius * 2))
$graphics.DrawEllipse($pen, ($dotX - $radius), ($dotY - $radius), ($radius * 2), ($radius * 2))

$bitmap.Save($screenshotFile, [System.Drawing.Imaging.ImageFormat]::Png)

$pen.Dispose()
$brush.Dispose()
$graphics.Dispose()
$bitmap.Dispose()

Log "Screenshot saved."
Log "ALL COMPLETED"
exit 0
