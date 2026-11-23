# Starts Ncommander.exe on the CI runner, maximizes it and saves screenshots
# (main window, then after a few key presses) for visual review.
param([string]$Exe, [string]$Out)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Write-Host "Screen: $($b.Width)x$($b.Height)"
function Shot($name) {
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $bmp.Save((Join-Path $Out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}
$p = Start-Process -FilePath $Exe -PassThru
Start-Sleep -Seconds 10
$p.Refresh()
[W]::ShowWindow($p.MainWindowHandle, 3) | Out-Null   # maximize
[W]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
Start-Sleep -Seconds 3
Shot "win_01_main"
$sh = New-Object -ComObject WScript.Shell
$sh.SendKeys("{DOWN}{DOWN}{INSERT}{INSERT}")
Start-Sleep -Seconds 2
Shot "win_02_selection"
$sh.SendKeys("{F2}")
Start-Sleep -Seconds 3
Shot "win_03_multirename"
$sh.SendKeys("{ESC}")
Start-Sleep -Seconds 2
$sh.SendKeys("^m")
Start-Sleep -Seconds 3
Shot "win_03b_ctrl_m"
$sh.SendKeys("{ESC}")
Start-Sleep -Seconds 1
$sh.SendKeys("{F7}")
Start-Sleep -Seconds 2
Shot "win_06_new"
$sh.SendKeys("{ESC}")
Start-Sleep -Seconds 1
$sh.SendKeys("%{F1}")
Start-Sleep -Seconds 2
Shot "win_04_locations"
$sh.SendKeys("{ESC}")
Start-Sleep -Seconds 1
[W]::ShowWindow($p.MainWindowHandle, 9) | Out-Null   # restore to default size
Start-Sleep -Seconds 2
Shot "win_05_window"
Stop-Process -Id $p.Id -Force
