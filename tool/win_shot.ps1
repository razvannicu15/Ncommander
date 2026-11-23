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
# Demo files in the user folder (where the panels open).
$home0 = $env:USERPROFILE
$colors = @('SteelBlue','Coral','SeaGreen')
for ($i = 1; $i -le 3; $i++) {
  $bm = New-Object System.Drawing.Bitmap 320, 240
  $gr = [System.Drawing.Graphics]::FromImage($bm)
  $gr.Clear([System.Drawing.Color]::FromName($colors[$i-1]))
  $gr.FillEllipse([System.Drawing.Brushes]::White, 100, 60, 120, 120)
  $bm.Save((Join-Path $home0 "img$i.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $gr.Dispose(); $bm.Dispose()
}
"Ncommander demo" | Out-File (Join-Path $home0 "notes.txt")
@'
<?php
// Ncommander code view test
function salut(string $nume): string {
    return "Salut, " . htmlspecialchars($nume) . "!";
}
$lista = ['unu' => 1, 'doi' => 2];
foreach ($lista as $k => $v) {
    echo salut($k), " = $v<br>\n";
}
?>
<html><body><h1 class="titlu">Test</h1></body></html>
'@ | Out-File -Encoding utf8 (Join-Path $home0 "index.php")
New-Item -ItemType Directory -Force -Path (Join-Path $env:TEMP "zipsrc\docs") | Out-Null
"a" | Out-File (Join-Path $env:TEMP "zipsrc\docs\readme.md")
"b" | Out-File (Join-Path $env:TEMP "zipsrc\config.json")
Copy-Item (Join-Path $home0 "img1.png") (Join-Path $env:TEMP "zipsrc\photo.png")
Compress-Archive -Path (Join-Path $env:TEMP "zipsrc\*") -DestinationPath (Join-Path $home0 "demo.zip") -Force

# A PDF to preview, printed by Edge from a small page.
$html = Join-Path $env:TEMP "raport.html"
"<html><body style='font-family:Segoe UI;padding:40px'><h1>Raport lunar</h1><p>Ncommander quick view test.</p><ul><li>Venituri</li><li>Cheltuieli</li></ul></body></html>" | Out-File -Encoding utf8 $html
$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
if (Test-Path $edge) {
  & $edge --headless --disable-gpu --no-pdf-header-footer "--print-to-pdf=$(Join-Path $home0 'raport.pdf')" $html | Out-Null
  Start-Sleep -Seconds 5
}

# Word / PowerPoint samples (no Office on the runner: the built-in layout shows).
python -m pip install --quiet python-docx python-pptx 2>$null
$py = @'
import os, sys
from docx import Document
from docx.shared import Pt, RGBColor, Inches
from docx.enum.text import WD_ALIGN_PARAGRAPH
home = sys.argv[1]
d = Document()
d.add_heading('Scrisoare de ofertă', 0)
p = d.add_paragraph('Stimate client, vă transmitem oferta noastră pentru ')
r = p.add_run('serviciile de mentenanță'); r.bold = True
p.add_run(' pe anul 2027.')
d.add_heading('Detalii', level=1)
for t in ['Intervenție în 24 de ore', 'Verificare lunară', 'Raport trimestrial']:
    d.add_paragraph(t, style='List Bullet')
t = d.add_table(rows=1, cols=3); t.style = 'Table Grid'
h = t.rows[0].cells; h[0].text = 'Serviciu'; h[1].text = 'Cantitate'; h[2].text = 'Preț (lei)'
for row in [('Mentenanță', '12', '4.800'), ('Intervenții', '6', '1.500'), ('Rapoarte', '4', '600')]:
    c = t.add_row().cells
    for i, v in enumerate(row): c[i].text = v
c = d.add_paragraph('Total: 6.900 lei'); c.alignment = WD_ALIGN_PARAGRAPH.RIGHT; c.runs[0].bold = True
d.add_picture(os.path.join(home, 'img2.png'), width=Inches(2.5))
for i in range(30):
    d.add_paragraph(f'Paragraful {i+1}: text de umplutură ca documentul să aibă mai multe pagini, la fel ca în Word.')
d.save(os.path.join(home, 'scrisoare.docx'))
from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
pr = Presentation(); pr.slide_width = Inches(13.333); pr.slide_height = Inches(7.5)
s = pr.slides.add_slide(pr.slide_layouts[0])
s.shapes.title.text = 'Raport trimestrial'; s.placeholders[1].text = 'Echipa Ncommander · 2026'
s = pr.slides.add_slide(pr.slide_layouts[1])
s.shapes.title.text = 'Rezultate'
tf = s.placeholders[1].text_frame; tf.text = 'Vânzări +18%'
for t in ['Clienți noi: 42', 'Satisfacție: 4,7 / 5']: tf.add_paragraph().text = t
box = s.shapes.add_shape(1, Inches(9), Inches(2), Inches(3), Inches(1.5))
box.fill.solid(); box.fill.fore_color.rgb = RGBColor(0xD9, 0x82, 0x2B); box.text_frame.text = 'Obiectiv atins'
s.shapes.add_picture(os.path.join(home, 'img3.png'), Inches(9), Inches(4), width=Inches(3))
pr.save(os.path.join(home, 'prezentare.pptx'))
'@
$py | Out-File -Encoding utf8 (Join-Path $env:TEMP "mk.py")
python (Join-Path $env:TEMP "mk.py") $home0

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
$sh.SendKeys("^+{F1}")
Start-Sleep -Seconds 3
Shot "win_07_thumbnails"
$sh.SendKeys("^{F1}")
Start-Sleep -Seconds 1
$sh.SendKeys("^f")
Start-Sleep -Seconds 2
Shot "win_08_ftp"
$sh.SendKeys("{ESC}")
Start-Sleep -Seconds 1
$sh.SendKeys("{END}{F3}")
Start-Sleep -Seconds 5
Shot "win_13_docx"
$sh.SendKeys("{ESC}")
Start-Sleep -Seconds 2
$sh.SendKeys("{END}{UP}{F3}")
Start-Sleep -Seconds 4
Shot "win_10_pdf"
$sh.SendKeys("{ESC}")
Start-Sleep -Seconds 2
$sh.SendKeys("{END}{UP}{UP}{UP}{F3}")
Start-Sleep -Seconds 5
Shot "win_14_pptx"
$sh.SendKeys("{ESC}")
Start-Sleep -Seconds 2
$sh.SendKeys("{END}{UP}{UP}{UP}{UP}{UP}{F3}")
Start-Sleep -Seconds 3
Shot "win_11_code"
$sh.SendKeys("{ESC}")
Start-Sleep -Seconds 2
$sh.SendKeys("{END}{UP}{UP}{UP}{UP}{UP}{UP}{UP}{UP}{UP}{ENTER}")
Start-Sleep -Seconds 3
Shot "win_09_zip"
$sh.SendKeys("{HOME}{ENTER}")
Start-Sleep -Seconds 2
Shot "win_12_zip_out"
Start-Sleep -Seconds 2
[W]::ShowWindow($p.MainWindowHandle, 9) | Out-Null   # restore to default size
Start-Sleep -Seconds 2
Shot "win_05_window"
Stop-Process -Id $p.Id -Force
