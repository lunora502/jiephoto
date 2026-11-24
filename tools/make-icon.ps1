# generate Assets/icon.ico (multi-size PNG entries) + preview png — run once, commit output
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = "$PSScriptRoot\.."
$assets = Join-Path $root "src\JieDraw\Assets"
New-Item -ItemType Directory -Force -Path $assets | Out-Null

function New-IconPng([int]$size) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $s = $size / 64.0   # design in 64-unit space
  # dark rounded square background
  $bgPath = New-Object System.Drawing.Drawing2D.GraphicsPath
  $r = 14 * $s; $x = 3 * $s; $w = $size - 6 * $s
  $bgPath.AddArc($x, $x, $r, $r, 180, 90)
  $bgPath.AddArc($x + $w - $r, $x, $r, $r, 270, 90)
  $bgPath.AddArc($x + $w - $r, $x + $w - $r, $r, $r, 0, 90)
  $bgPath.AddArc($x, $x + $w - $r, $r, $r, 90, 90)
  $bgPath.CloseFigure()
  $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 32, 33, 36))), $bgPath)
  # blue pen wave
  $pts = @(
    (New-Object System.Drawing.PointF((16*$s), (44*$s))),
    (New-Object System.Drawing.PointF((26*$s), (22*$s))),
    (New-Object System.Drawing.PointF((38*$s), (40*$s))),
    (New-Object System.Drawing.PointF((48*$s), (20*$s)))
  )
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 90, 156, 248), (7*$s))
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  $g.DrawCurve($pen, $pts)
  # orange dot accent (top-right)
  $dot = 6 * $s
  $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 245, 158, 11))), (44*$s), (10*$s), $dot, $dot)
  $g.Dispose()
  return $bmp
}

$entries = @()
foreach ($size in @(256, 48, 32, 16)) {
  $bmp = New-IconPng $size
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $entries += @{ Size = $size; Data = $ms.ToArray() }
  if ($size -eq 256) { $bmp.Save((Join-Path $assets "icon-256.png"), [System.Drawing.Imaging.ImageFormat]::Png) }
  $bmp.Dispose()
}

# assemble ICO (PNG-compressed entries, valid on Vista+)
$fs = [System.IO.File]::Create((Join-Path $assets "icon.ico"))
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$entries.Count)  # ICONDIR
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
  $sz = if ($e.Size -ge 256) { 0 } else { $e.Size }
  $bw.Write([byte]$sz); $bw.Write([byte]$sz); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([UInt16]1); $bw.Write([UInt16]32)
  $bw.Write([UInt32]$e.Data.Length); $bw.Write([UInt32]$offset)
  $offset += $e.Data.Length
}
foreach ($e in $entries) { $bw.Write($e.Data) }
$bw.Close(); $fs.Close()
Write-Host ("icon.ico written: " + (Get-Item (Join-Path $assets "icon.ico")).Length + " bytes")
