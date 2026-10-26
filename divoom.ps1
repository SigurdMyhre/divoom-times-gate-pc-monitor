# Divoom Times Gate helper: generate 128x128 images and push them to the 5 LCDs.
# API on this firmware: POST http://<ip>:9000/divoom_api
param(
    [string]$Ip = '192.168.2.169',
    [ValidateSet('random', 'image', 'anim')] [string]$Mode = 'random',
    [string]$ImagePath,           # used with -Mode image
    [string]$Screens = '0,1,2,3,4'   # comma-separated LCD indexes, left to right
)
$Lcds = [int[]]($Screens -split ',')

Add-Type -AssemblyName System.Drawing
$Api = "http://${Ip}:9000/divoom_api"
$Size = 128

function Invoke-Divoom($body) {
    # The device's server closes every connection, so never reuse one.
    Invoke-RestMethod -Uri $Api -Method Post -ContentType 'application/json' -DisableKeepAlive `
        -Body ($body | ConvertTo-Json -Compress -Depth 5) -TimeoutSec 10
}

# Base64 JPEG - this firmware ignores raw RGB (shows a loading spinner) but accepts JPEG.
function ConvertTo-PicData([System.Drawing.Bitmap]$bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    [Convert]::ToBase64String($ms.ToArray())
}

function New-Canvas { New-Object System.Drawing.Bitmap $Size, $Size }

function Get-RandomColor { [System.Drawing.Color]::FromArgb((Get-Random 256), (Get-Random 256), (Get-Random 256)) }

# A few procedural "random picture" styles
function New-RandomPicture([int]$style) {
    $bmp = New-Canvas
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    switch ($style % 5) {
        0 { # gradient + circles
            $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 0, 0, $Size, $Size), (Get-RandomColor), (Get-RandomColor), (Get-Random 360)
            $g.FillRectangle($br, 0, 0, $Size, $Size)
            1..12 | ForEach-Object {
                $r = Get-Random -Min 6 -Max 40
                $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(170, (Get-RandomColor)))), (Get-Random $Size) - $r, (Get-Random $Size) - $r, 2 * $r, 2 * $r)
            }
        }
        1 { # mondrian-ish blocks
            $g.Clear([System.Drawing.Color]::White)
            $pal = 'Red', 'Blue', 'Gold', 'White', 'White', 'Black' | ForEach-Object { [System.Drawing.Color]::FromName($_) }
            $grid = 4; $cell = $Size / $grid
            for ($x = 0; $x -lt $grid; $x++) { for ($y = 0; $y -lt $grid; $y++) {
                $g.FillRectangle((New-Object System.Drawing.SolidBrush ($pal | Get-Random)), $x * $cell, $y * $cell, $cell, $cell)
                $g.DrawRectangle((New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), 3), $x * $cell, $y * $cell, $cell, $cell)
            } }
        }
        2 { # plasma
            $a = Get-Random -Min 3 -Max 9; $b = Get-Random -Min 3 -Max 9; $ph = Get-Random 100
            for ($y = 0; $y -lt $Size; $y++) { for ($x = 0; $x -lt $Size; $x++) {
                $v = [Math]::Sin($x / $a + $ph) + [Math]::Sin($y / $b) + [Math]::Sin(($x + $y) / 11.0) + [Math]::Sin([Math]::Sqrt($x * $x + $y * $y) / 8.0)
                $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(
                    [int](128 + 127 * [Math]::Sin($v * 3.14)), [int](128 + 127 * [Math]::Sin($v * 3.14 + 2.1)), [int](128 + 127 * [Math]::Sin($v * 3.14 + 4.2))))
            } }
        }
        3 { # starfield + moon
            $g.Clear([System.Drawing.Color]::FromArgb(5, 5, 25))
            1..150 | ForEach-Object { $s = Get-Random 200; $bmp.SetPixel((Get-Random $Size), (Get-Random $Size), [System.Drawing.Color]::FromArgb(55 + $s, 55 + $s, 55 + $s)) }
            $g.FillEllipse([System.Drawing.Brushes]::LightYellow, 70, 18, 40, 40)
            $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(5, 5, 25))), 82, 12, 40, 40)
        }
        4 { # big text
            $g.Clear((Get-RandomColor))
            $txt = 'HI', 'YO', ':)', '<3', 'OK', '42', 'ZAP' | Get-Random
            $f = New-Object System.Drawing.Font 'Arial Black', 40, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
            $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
            $g.TextRenderingHint = 'AntiAlias'
            $g.DrawString($txt, $f, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, $Size, $Size), $sf)
        }
    }
    $g.Dispose()
    $bmp
}

function Load-Image([string]$path) {
    $src = [System.Drawing.Image]::FromFile((Resolve-Path $path))
    $bmp = New-Canvas
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage($src, 0, 0, $Size, $Size)
    $g.Dispose(); $src.Dispose()
    $bmp
}

# Push a list of frames (1 = still image) to the given screens.
function Send-Frames([System.Drawing.Bitmap[]]$frames, [int[]]$lcd, [int]$speed = 100) {
    # This firmware's GetHttpGifId reply has no PicId, so keep our own counter
    # (IDs restart at 1 after the ResetHttpGifId below).
    $script:NextId++
    $id = $script:NextId
    $lcdArray = 0..4 | ForEach-Object { [int]($lcd -contains $_) }
    for ($i = 0; $i -lt $frames.Count; $i++) {
        $r = Invoke-Divoom @{
            Command = 'Draw/SendHttpGif'; LcdArray = $lcdArray
            PicNum = $frames.Count; PicWidth = $Size; PicOffset = $i
            PicID = $id; PicSpeed = $speed; PicData = (ConvertTo-PicData $frames[$i])
        }
        if ($r.error_code -or $r.ReturnCode) { Write-Warning ($r | ConvertTo-Json -Compress) }
    }
}

# HTTP pictures only show on the "custom" channel (3).
Invoke-Divoom @{ Command = 'Channel/SetIndex'; SelectIndex = 3 } | Out-Null
Invoke-Divoom @{ Command = 'Draw/ResetHttpGifId' } | Out-Null
$script:NextId = 0

switch ($Mode) {
    'random' {
        foreach ($s in $Lcds) {
            $style = Get-Random 5
            Write-Host "Screen $s <- random style $style"
            Send-Frames @(New-RandomPicture $style) @($s)
        }
    }
    'image' {
        Write-Host "Sending $ImagePath to screens $($Lcds -join ',')"
        Send-Frames @(Load-Image $ImagePath) $Lcds
    }
    'anim' {
        # 8-frame bouncing ball, sent to all chosen screens
        $frames = 0..7 | ForEach-Object {
            $bmp = New-Canvas; $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::FromArgb(20, 20, 40))
            $y = 10 + [int](80 * [Math]::Abs([Math]::Sin($_ * [Math]::PI / 8)))
            $g.FillEllipse([System.Drawing.Brushes]::OrangeRed, 44, 90 - $y + 10, 40, 40)
            $g.Dispose(); $bmp
        }
        Write-Host "Sending 8-frame animation"
        Send-Frames $frames $Lcds 80
    }
}

