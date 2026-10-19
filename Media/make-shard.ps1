param([string]$OutDir, [string]$PreviewPath)
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null

$S = 512
function P($x, $y) { New-Object System.Drawing.PointF ([single]$x), ([single]$y) }
function C($a, $r, $g, $b) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }

# Irregular crystal outline (clockwise from the top tip) and an off-centre core point
# that the facets fan out from.
$outline = @( (P 268 18), (P 392 138), (P 432 292), (P 366 438), (P 246 496), (P 124 424), (P 82 262), (P 148 112) )
$core = P 252 250

# Light comes from the upper left: one shade per facet, starting with the top-right facet.
$shades = @(
	@(150, 100, 235), @(105, 55, 190), @(70, 30, 140), @(55, 20, 115),
	@(80, 35, 150), @(125, 75, 215), @(190, 150, 255), @(170, 125, 250)
)

function New-Canvas {
	$bmp = New-Object System.Drawing.Bitmap $S, $S, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp)
	$g.SmoothingMode = 'AntiAlias'
	$g.Clear([System.Drawing.Color]::Transparent)
	return $bmp, $g
}

function Fill-Facets($g, $alpha, $coreDarken) {
	for ($i = 0; $i -lt $outline.Count; $i++) {
		$a = $outline[$i]; $b = $outline[($i + 1) % $outline.Count]
		$tri = [System.Drawing.PointF[]]@($a, $b, $core)
		$mid = P (($a.X + $b.X) / 2) (($a.Y + $b.Y) / 2)
		$s = $shades[$i]
		$edge = C $alpha $s[0] $s[1] $s[2]
		$inner = C $alpha ([int]($s[0] * $coreDarken)) ([int]($s[1] * $coreDarken)) ([int]($s[2] * $coreDarken))
		$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $mid, $core, $edge, $inner
		$g.FillPolygon($brush, $tri)
		$brush.Dispose()
	}
}

function Save-Tga($bmp, $path) {
	$rect = New-Object System.Drawing.Rectangle 0, 0, $S, $S
	$data = $bmp.LockBits($rect, 'ReadOnly', ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb))
	$bytes = New-Object byte[] ($S * $S * 4)
	[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
	$bmp.UnlockBits($data)
	# Uncompressed true-colour TGA, BGRA pixels, top-left origin, 8 alpha bits.
	$header = [byte[]](0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, ($S -band 255), ($S -shr 8), ($S -band 255), ($S -shr 8), 32, 0x28)
	$fs = [System.IO.File]::Create($path)
	$fs.Write($header, 0, $header.Length)
	$fs.Write($bytes, 0, $bytes.Length)
	$fs.Close()
}

$poly = [System.Drawing.PointF[]]$outline

# Back: the solid body, with a dark heart where the ghost floats.
$back, $g = New-Canvas
Fill-Facets $g 255 0.55
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddPolygon($poly)
$heart = New-Object System.Drawing.Drawing2D.PathGradientBrush $path
$heart.CenterPoint = $core
$heart.CenterColor = C 235 18 4 34
$heart.SurroundColors = [System.Drawing.Color[]]@((C 0 18 4 34))
$heart.FocusScales = New-Object System.Drawing.PointF 0.35, 0.35
$g.FillPath($heart, $path)
$g.DrawPolygon((New-Object System.Drawing.Pen (C 255 40 10 70), 4), $poly)
$g.Dispose()
Save-Tga $back (Join-Path $OutDir 'ShardBack.tga')

# Front: faint facet tint plus crisp edges and highlights, drawn over the ghost.
$front, $g = New-Canvas
Fill-Facets $g 48 0.8
$facetPen = New-Object System.Drawing.Pen (C 110 230 210 255), 2
foreach ($pt in $outline) { $g.DrawLine($facetPen, $pt, $core) }
$g.DrawPolygon((New-Object System.Drawing.Pen (C 230 235 220 255), 3), $poly)
$streak = [System.Drawing.PointF[]]@((P 160 128), (P 250 40), (P 262 58), (P 176 150))
$g.FillPolygon((New-Object System.Drawing.SolidBrush (C 150 255 255 255)), $streak)
$streak2 = [System.Drawing.PointF[]]@((P 104 262), (P 140 150), (P 150 160), (P 118 268))
$g.FillPolygon((New-Object System.Drawing.SolidBrush (C 90 255 255 255)), $streak2)
foreach ($spark in @(@(266, 22, 16), @(392, 140, 10), @(126, 422, 8))) {
	$x = $spark[0]; $y = $spark[1]; $r = $spark[2]
	$sparkPen = New-Object System.Drawing.Pen (C 230 255 255 255), 2
	$g.DrawLine($sparkPen, (P ($x - $r) $y), (P ($x + $r) $y))
	$g.DrawLine($sparkPen, (P $x ($y - $r)), (P $x ($y + $r)))
}
$g.Dispose()
Save-Tga $front (Join-Path $OutDir 'ShardFront.tga')

# Glow: a soft halo around the outline, built up from wide translucent strokes.
$glow, $g = New-Canvas
for ($w = 64; $w -ge 4; $w -= 4) {
	$pen = New-Object System.Drawing.Pen (C 14 170 90 255), $w
	$pen.LineJoin = 'Round'
	$g.DrawPolygon($pen, $poly)
}
$g.Dispose()
Save-Tga $glow (Join-Path $OutDir 'ShardGlow.tga')

# Preview: the three layers composited on a dark panel, for checking the art.
$preview, $g = New-Canvas
$g.Clear((C 255 20 18 24))
$g.DrawImage($glow, 0, 0)
$g.DrawImage($back, 0, 0)
$g.DrawImage($front, 0, 0)
$g.Dispose()
$preview.Save($PreviewPath, [System.Drawing.Imaging.ImageFormat]::Png)
"done"
