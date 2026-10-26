# PC status dashboard for the Divoom Times Gate (5 x 128x128 LCDs).
#   .\pcmon.ps1            run forever, refreshing all tiles every -Interval seconds
#   .\pcmon.ps1 -Preview   render the tiles once to .\preview\tile0..4.png and exit
# Tiles, left to right: CPU, GPU, memory & disks, network, clock & system.
param(
    [string]$Ip = '192.168.2.169',
    [double]$Interval = 0,                              # pause between refresh cycles
    [string]$LhmUrl = 'http://localhost:8085/data.json', # LibreHardwareMonitor web server (CPU temp)
    [int]$Quality = 92,                                 # JPEG quality; lower = smaller = faster decode on the device
    [switch]$FixedIds,                                  # reuse PicID 1..5 per screen instead of a new ID per update
    [double]$Gap = 0,                                   # optional pause after each picture
    [string]$Order = '0,1,2,3,4',                       # which screens to send, and in what order
    [string]$Layout = '0,1,2,3,4',                      # tile shown on each screen (0 cpu, 1 gpu, 2 mem, 3 net, 4 clock)
    [int]$PicSpeed = 1000,                              # frame time (ms) the device is told for the 1-frame picture
    [int]$MinBytes = 6000,                              # pad smaller JPEGs with a comment segment (0 = off).
                                                        # JPEGs under ~5 KB make the device flash a loading spinner...
    [int]$MaxBytes = 6500,                              # ...and so do ones over ~7 KB: lower the quality until it fits.
    [switch]$Log,                                       # print each send with its duration
    [ValidateSet('detail', 'big', 'duo', 'gauge', 'retro')]
    [string]$Style = 'retro',                           # tile design (see the style functions below)
    [switch]$Demo,                                      # cycle through all styles, 20 s each
    [switch]$Preview
)
$Styles = 'retro', 'big', 'duo', 'gauge', 'detail'

Add-Type -AssemblyName System.Drawing
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$Api = "http://${Ip}:9000/divoom_api"
$Size = 128
$Deg = [string][char]0xB0 + 'C'   # avoid non-ASCII literals: PS 5.1 reads this file as ANSI
$NbNo = [Globalization.CultureInfo]'nb-NO'
$LogicalCores = [Environment]::ProcessorCount
$BaseMhz = (Get-CimInstance Win32_Processor).MaxClockSpeed
$CpuName = ((Get-CimInstance Win32_Processor).Name -replace 'Intel\(R\) Core\(TM\) |AMD |\(R\)|\(TM\)| CPU.*', '').Trim()
$GpuName = ((Get-CimInstance Win32_VideoController | Where-Object Name -match 'NVIDIA|Radeon|Arc' | Select-Object -First 1).Name -replace 'NVIDIA |GeForce |AMD |Radeon ', '').Trim()

# ---------- palette ----------
function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$Col = @{
    bg = C '#0B0E14'; panel = C '#161B26'; track = C '#232A3A'; text = C '#F1F5F9'; muted = C '#8B95A7'
    cpu = C '#38BDF8'; gpu = C '#4ADE80'; mem = C '#A78BFA'; net = C '#FB923C'; clock = C '#FACC15'
    good = C '#4ADE80'; warn = C '#FBBF24'; bad = C '#F87171'
}
function Get-LevelColor([double]$v, [double]$warnAt, [double]$badAt) {
    if ($v -ge $badAt) { return $Col.bad }; if ($v -ge $warnAt) { return $Col.warn }; $Col.good
}

# ---------- drawing helpers ----------
$FontCache = @{}
function Font([single]$px, [bool]$bold = $true, [string]$family = 'Segoe UI') {
    $key = "$family|$px|$bold"
    if (-not $FontCache[$key]) {
        $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
        $FontCache[$key] = New-Object System.Drawing.Font $family, $px, $style, ([System.Drawing.GraphicsUnit]::Pixel)
    }
    $FontCache[$key]
}
function Brush([System.Drawing.Color]$c) { New-Object System.Drawing.SolidBrush $c }
# align: L, R or C (horizontal); y is the top of the text box
function Text($g, [string]$s, $font, [System.Drawing.Color]$c, [single]$x, [single]$y, [string]$align = 'L') {
    $sz = $g.MeasureString($s, $font)
    $sf = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
    switch ($align) { 'R' { $x = $x - $sz.Width + 4 } 'C' { $x = $x - $sz.Width / 2 + 2 } }
    $g.DrawString($s, $font, (Brush $c), $x, $y, $sf)
}
function Bar($g, [single]$x, [single]$y, [single]$w, [single]$h, [double]$pct, [System.Drawing.Color]$c) {
    $pct = [Math]::Max(0, [Math]::Min(100, $pct))
    $g.FillRectangle((Brush $Col.track), $x, $y, $w, $h)
    $fw = [Math]::Round($w * $pct / 100)
    if ($fw -gt 0) { $g.FillRectangle((Brush $c), $x, $y, $fw, $h) }
}
# Circular gauge: 270-degree arc, open at the bottom
function Ring($g, [single]$cx, [single]$cy, [single]$r, [single]$th, [double]$pct, [System.Drawing.Color]$c) {
    $pct = [Math]::Max(0, [Math]::Min(100, $pct))
    $rect = New-Object System.Drawing.RectangleF ($cx - $r), ($cy - $r), (2 * $r), (2 * $r)
    $pen = New-Object System.Drawing.Pen $Col.track, $th; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawArc($pen, $rect, 135, 270)
    if ($pct -gt 0) {
        $pen = New-Object System.Drawing.Pen $c, $th; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
        $g.DrawArc($pen, $rect, 135, [single](270 * $pct / 100))
    }
}
function Header($g, [string]$title, [string]$right, [System.Drawing.Color]$accent) {
    $g.FillRectangle((Brush $Col.panel), 0, 0, $Size, 15)
    $g.FillRectangle((Brush $accent), 0, 0, 3, 15)
    Text $g $title (Font 9) $Col.text 6 2
    if ($right) { Text $g $right (Font 8 $false) $Col.muted 126 3 'R' }
}
function New-Tile {
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear($Col.bg)
    @($bmp, $g)
}
function Fmt([double]$v, [int]$dec = 1) { $v.ToString("F$dec") }
function FmtRate([double]$bps) {   # bytes/s -> "12.4 MB/s"-style pair (value, unit)
    if ($bps -ge 1MB) { return @((Fmt ($bps / 1MB) 1), 'MB/s') }
    if ($bps -ge 1KB) { return @((Fmt ($bps / 1KB) 0), 'KB/s') }
    @(([int]$bps).ToString(), 'B/s')
}

# ---------- data collection ----------
$script:NetHist = New-Object System.Collections.Generic.List[double]
$script:CpuHist = New-Object System.Collections.Generic.List[double]
$script:PrevProc = @{}; $script:PrevProcTime = Get-Date

function Get-LhmTemps {
    # Returns @{cpu=<deg C or $null>; cpuPower=<W or $null>} from LibreHardwareMonitor's JSON tree.
    $r = @{ cpu = $null; cpuPower = $null }
    try { $root = Invoke-RestMethod -Uri $LhmUrl -TimeoutSec 2 } catch { return $r }
    # Values look like "54,0 °C" / "17,1 W" (locale decimal separator, degree sign); keep the number only.
    $temps = @{}; $watts = @{}
    $stack = New-Object System.Collections.Stack; $stack.Push($root)
    while ($stack.Count) {
        $n = $stack.Pop()
        if ($n.Value -match '^([\d.,]+)\s*(\S*C|W)$') {
            $v = [double]($Matches[1] -replace ',', '.')
            if ($Matches[2] -eq 'W') { if (-not $watts[$n.Text]) { $watts[$n.Text] = $v } }
            elseif (-not $temps[$n.Text]) { $temps[$n.Text] = $v }
        }
        foreach ($ch in $n.Children) { $stack.Push($ch) }
    }
    foreach ($k in 'CPU Package', 'Core (Tctl/Tdie)', 'Core Max', 'CPU Core') { if ($temps[$k]) { $r.cpu = $temps[$k]; break } }
    foreach ($k in 'CPU Package', 'Package') { if ($watts[$k]) { $r.cpuPower = $watts[$k]; break } }
    $r
}
function Get-Gpu {
    $r = @{ ok = $false }
    try {
        $line = & nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,clocks.sm,power.draw,power.limit,memory.used,memory.total,fan.speed --format=csv,noheader,nounits 2>$null
        if ($line) {
            $v = $line.Split(',') | ForEach-Object { $_.Trim() }
            $r = @{ ok = $true; temp = [double]$v[0]; util = [double]$v[1]; clock = [double]$v[2]; power = [double]$v[3]; plimit = [double]$v[4]; vused = [double]$v[5]; vtotal = [double]$v[6]; fan = [double]$v[7] }
        }
    } catch {}
    $r
}
function Get-TopProcess {
    # CPU % per process since the previous call, from cumulative processor time.
    $now = Get-Date; $elapsed = ($now - $script:PrevProcTime).TotalSeconds
    $cur = @{}; $best = $null; $bestPct = 0
    foreach ($p in (Get-Process | Where-Object { $_.Name -notin 'Idle', 'System' })) {
        try { $t = $p.TotalProcessorTime.TotalSeconds } catch { continue }
        $cur[$p.Id] = $t
        if ($script:PrevProc.ContainsKey($p.Id) -and $elapsed -gt 0) {
            $pct = ($t - $script:PrevProc[$p.Id]) / $elapsed / $LogicalCores * 100
            if ($pct -gt $bestPct) { $bestPct = $pct; $best = $p.Name }
        }
    }
    $script:PrevProc = $cur; $script:PrevProcTime = $now
    @{ name = $best; pct = $bestPct }
}
function Get-Stats {
    $s = @{}
    $pi = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation
    $tot = $pi | Where-Object Name -eq '_Total'
    $s.cpuLoad = [Math]::Min(100, [double]$tot.PercentProcessorUtility)
    $s.cpuGhz = $BaseMhz * [double]$tot.PercentProcessorPerformance / 100 / 1000
    $s.cores = @($pi | Where-Object { $_.Name -match '^\d+,\d+$' } | Sort-Object { [int]($_.Name.Split(',')[1]) } | ForEach-Object { [Math]::Min(100, [double]$_.PercentProcessorUtility) })
    $lhm = Get-LhmTemps; $s.cpuTemp = $lhm.cpu; $s.cpuPower = $lhm.cpuPower
    $s.gpu = Get-Gpu
    $os = Get-CimInstance Win32_OperatingSystem
    $s.ramTotal = $os.TotalVisibleMemorySize / 1MB; $s.ramUsed = ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB
    $s.uptime = (Get-Date) - $os.LastBootUpTime
    $s.disks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object { @{ id = $_.DeviceID.TrimEnd(':'); size = $_.Size / 1GB; free = $_.FreeSpace / 1GB } })
    $dp = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
    $s.diskAct = [Math]::Max(0, 100 - [double]$dp.PercentIdleTime)
    $ni = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface | Where-Object { $_.CurrentBandwidth -gt 0 -and $_.Name -notmatch 'Loopback|isatap|Virtual|VMware|Hyper-V|WSL' }
    $s.netDown = ($ni | Measure-Object BytesReceivedPersec -Sum).Sum; $s.netUp = ($ni | Measure-Object BytesSentPersec -Sum).Sum
    $s.top = Get-TopProcess
    $script:NetHist.Add([double]$s.netDown); if ($script:NetHist.Count -gt 60) { $script:NetHist.RemoveAt(0) }
    $script:CpuHist.Add($s.cpuLoad);          if ($script:CpuHist.Count -gt 60) { $script:CpuHist.RemoveAt(0) }
    $s
}

# ---------- tiles ----------
function Arrow($g, [single]$cx, [single]$cy, [bool]$up, [System.Drawing.Color]$c) {
    $dy = if ($up) { -5 } else { 5 }
    $pts = @((New-Object System.Drawing.PointF ($cx - 6), ($cy - $dy)), (New-Object System.Drawing.PointF ($cx + 6), ($cy - $dy)), (New-Object System.Drawing.PointF $cx, ($cy + $dy)))
    $g.FillPolygon((Brush $c), $pts)
}
function Sparkline($g, [double[]]$hist, [single]$x, [single]$y, [single]$w, [single]$h, [System.Drawing.Color]$c, [double]$max) {
    $g.FillRectangle((Brush $Col.panel), $x, $y, $w, $h)
    if ($hist.Count -lt 2 -or $max -le 0) { return }
    $pts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    $pts.Add((New-Object System.Drawing.PointF $x, ($y + $h)))
    for ($i = 0; $i -lt $hist.Count; $i++) {
        $px = $x + $w * $i / 59; $py = $y + $h - [Math]::Min(1, $hist[$i] / $max) * ($h - 1)
        $pts.Add((New-Object System.Drawing.PointF $px, $py))
    }
    $pts.Add((New-Object System.Drawing.PointF ($x + $w * ($hist.Count - 1) / 59), ($y + $h)))
    $g.FillPolygon((Brush ([System.Drawing.Color]::FromArgb(90, $c))), $pts.ToArray())
    $g.DrawLines((New-Object System.Drawing.Pen $c, 1.5), $pts.GetRange(1, $hist.Count).ToArray())
}

function Tile-Cpu($s) {
    $bmp, $g = New-Tile
    Header $g 'CPU' $CpuName $Col.cpu
    $lc = Get-LevelColor $s.cpuLoad 60 85
    Ring $g 32 52 25 7 $s.cpuLoad $lc
    Text $g ([int]$s.cpuLoad).ToString() (Font 21) $Col.text 32 39 'C'
    Text $g '%' (Font 8 $false) $Col.muted 32 61 'C'
    Text $g 'CLOCK' (Font 7 $false) $Col.muted 68 20
    Text $g (Fmt $s.cpuGhz 2) (Font 19) $Col.text 68 27
    Text $g 'GHz' (Font 8 $false) $Col.muted 126 37 'R'
    Text $g 'TEMP' (Font 7 $false) $Col.muted 68 50
    if ($s.cpuTemp -ne $null) {
        Text $g ([int]$s.cpuTemp).ToString() (Font 19) (Get-LevelColor $s.cpuTemp 70 85) 68 57
        Text $g $Deg (Font 8 $false) $Col.muted 126 67 'R'
    } else { Text $g '--' (Font 19) $Col.muted 68 57 }
    if ($s.cpuPower) { Text $g "$([int]$s.cpuPower) W" (Font 8 $false) $Col.muted 126 82 'R' }
    Text $g "$($s.cores.Count) THREADS" (Font 7 $false) $Col.muted 4 82
    $n = [Math]::Max(1, $s.cores.Count); $bw = [Math]::Floor(120 / $n)
    for ($i = 0; $i -lt $n; $i++) {
        $v = $s.cores[$i]; $h = [Math]::Max(1, [Math]::Round(32 * $v / 100))
        $g.FillRectangle((Brush $Col.track), 4 + $i * $bw, 92, $bw - 1, 32)
        $g.FillRectangle((Brush (Get-LevelColor $v 60 85)), 4 + $i * $bw, 124 - $h, $bw - 1, $h)
    }
    $g.Dispose(); $bmp
}
function Tile-Gpu($s) {
    $bmp, $g = New-Tile
    Header $g 'GPU' $GpuName $Col.gpu
    $gp = $s.gpu
    if (-not $gp.ok) { Text $g 'no nvidia-smi' (Font 10 $false) $Col.muted 64 56 'C'; $g.Dispose(); return $bmp }
    Ring $g 32 52 25 7 $gp.util (Get-LevelColor $gp.util 60 85)
    Text $g ([int]$gp.util).ToString() (Font 21) $Col.text 32 39 'C'
    Text $g '%' (Font 8 $false) $Col.muted 32 61 'C'
    Text $g 'TEMP' (Font 7 $false) $Col.muted 68 20
    Text $g ([int]$gp.temp).ToString() (Font 19) (Get-LevelColor $gp.temp 70 83) 68 27
    Text $g $Deg (Font 8 $false) $Col.muted 126 37 'R'
    Text $g 'CLOCK' (Font 7 $false) $Col.muted 68 50
    Text $g ([int]$gp.clock).ToString() (Font 19) $Col.text 68 57
    Text $g 'MHz' (Font 8 $false) $Col.muted 126 67 'R'
    $vp = 100 * $gp.vused / $gp.vtotal
    Text $g 'VRAM' (Font 7 $false) $Col.muted 4 82
    Text $g "$(Fmt ($gp.vused/1024) 1) / $([int]($gp.vtotal/1024)) GB" (Font 8 $false) $Col.text 126 81 'R'
    Bar $g 4 92 120 9 $vp $Col.gpu
    $pp = 100 * $gp.power / $gp.plimit
    Text $g 'POWER' (Font 7 $false) $Col.muted 4 104
    Text $g "$([int]$gp.power) / $([int]$gp.plimit) W" (Font 8 $false) $Col.text 126 103 'R'
    Bar $g 4 114 120 9 $pp (Get-LevelColor $pp 70 90)
    $g.Dispose(); $bmp
}
function Tile-Mem($s) {
    $bmp, $g = New-Tile
    Header $g 'MEMORY' 'disks' $Col.mem
    $rp = 100 * $s.ramUsed / $s.ramTotal
    Text $g ([int]$rp).ToString() (Font 26) $Col.text 4 18
    Text $g '%' (Font 9 $false) $Col.muted 38 33
    Text $g 'RAM' (Font 7 $false) $Col.muted 126 20 'R'
    Text $g "$(Fmt $s.ramUsed 1) / $([int]$s.ramTotal) GB" (Font 8 $false) $Col.text 126 30 'R'
    Bar $g 4 48 120 10 $rp (Get-LevelColor $rp 75 90)
    $y = 66
    foreach ($d in ($s.disks | Select-Object -First 2)) {
        $used = 100 * ($d.size - $d.free) / $d.size
        Text $g "$($d.id):" (Font 9) $Col.text 4 $y
        Text $g "$([int]$d.free) GB free" (Font 8 $false) $Col.muted 126 ($y + 1) 'R'
        Bar $g 4 ($y + 12) 120 7 $used (Get-LevelColor $used 80 92)
        $y += 24
    }
    Text $g 'DISK ACTIVITY' (Font 7 $false) $Col.muted 4 114
    Text $g "$([int]$s.diskAct)%" (Font 8 $false) $Col.text 126 113 'R'
    Bar $g 70 116 32 6 $s.diskAct $Col.mem
    $g.Dispose(); $bmp
}
function Tile-Net($s) {
    $bmp, $g = New-Tile
    Header $g 'NETWORK' '' $Col.net
    $d = FmtRate $s.netDown; $u = FmtRate $s.netUp
    Arrow $g 10 30 $false $Col.net
    Text $g $d[0] (Font 22) $Col.text 20 18
    Text $g $d[1] (Font 8 $false) $Col.muted 126 31 'R'
    Arrow $g 10 58 $true $Col.cpu
    Text $g $u[0] (Font 22) $Col.text 20 46
    Text $g $u[1] (Font 8 $false) $Col.muted 126 59 'R'
    $max = ($script:NetHist | Measure-Object -Maximum).Maximum
    Text $g 'DOWNLOAD, LAST 2 MIN' (Font 7 $false) $Col.muted 4 78
    Sparkline $g $script:NetHist.ToArray() 4 88 120 36 $Col.net $max
    $g.Dispose(); $bmp
}
function Tile-Clock($s) {
    $bmp, $g = New-Tile
    $now = Get-Date
    Header $g 'SYSTEM' $env:COMPUTERNAME $Col.clock
    Text $g $now.ToString('HH:mm') (Font 40) $Col.text 64 16 'C'
    Text $g $now.ToString('dddd d. MMMM', $NbNo) (Font 9 $false) $Col.muted 64 60 'C'
    $g.FillRectangle((Brush $Col.panel), 4, 76, 120, 1)
    $up = $s.uptime
    $upTxt = if ($up.Days -gt 0) { "$($up.Days)d $($up.Hours)h" } else { "$($up.Hours)h $($up.Minutes)m" }
    Text $g 'UPTIME' (Font 7 $false) $Col.muted 4 81
    Text $g $upTxt (Font 9) $Col.text 126 80 'R'
    Text $g 'CPU 2 MIN' (Font 7 $false) $Col.muted 4 95
    Sparkline $g $script:CpuHist.ToArray() 50 95 74 10 $Col.cpu 100
    Text $g 'TOP' (Font 7 $false) $Col.muted 4 112
    if ($s.top.name) {
        $nm = $s.top.name; if ($nm.Length -gt 12) { $nm = $nm.Substring(0, 12) }
        Text $g $nm (Font 9) $Col.text 26 110
        Text $g "$([int]$s.top.pct)%" (Font 9) $Col.clock 126 110 'R'
    }
    $g.Dispose(); $bmp
}

# ---------- style "big": one hero number per tile ----------
$Dot = ' ' + [string][char]0xB7 + ' '
function RoundBar($g, [single]$x, [single]$y, [single]$w, [single]$h, [double]$pct, [System.Drawing.Color]$c) {
    $pct = [Math]::Max(0, [Math]::Min(100, $pct))
    $track = New-Object System.Drawing.Drawing2D.GraphicsPath
    $track.AddArc($x, $y, $h, $h, 90, 180); $track.AddArc($x + $w - $h, $y, $h, $h, 270, 180); $track.CloseFigure()
    $g.FillPath((Brush (C '#1C222E')), $track)
    $fw = $w * $pct / 100
    if ($fw -lt $h) { if ($pct -gt 0) { $g.FillEllipse((Brush $c), $x, $y, $h, $h) }; return }
    $fill = New-Object System.Drawing.Drawing2D.GraphicsPath
    $fill.AddArc($x, $y, $h, $h, 90, 180); $fill.AddArc($x + $fw - $h, $y, $h, $h, 270, 180); $fill.CloseFigure()
    $g.FillPath((Brush $c), $fill)
}
# Title top-left, a 52 px number in the middle, one context line, a thick rounded bar at the bottom.
function Hero($g, [string]$title, [System.Drawing.Color]$accent, [string]$value, [string]$unit, [System.Drawing.Color]$vcol, [string]$sub, [double]$barPct, [System.Drawing.Color]$barCol) {
    Text $g $title (Font 13 $true 'Bahnschrift SemiBold') $accent 6 5
    $f = Font 54 $true 'Bahnschrift SemiBold'
    if ($value.Length -gt 3) { $f = Font 54 $true 'Bahnschrift SemiBold Condensed' }
    $w = $g.MeasureString($value, $f).Width
    $uf = Font 18 $true 'Bahnschrift SemiBold Condensed'
    $uw = 0; if ($unit) { $uw = $g.MeasureString($unit, $uf).Width - 2 }
    $x = ($Size - $w - $uw) / 2 + 3
    Text $g $value $f $vcol $x 20
    if ($unit) { Text $g $unit $uf $Col.muted ($x + $w - 6) 48 }
    if ($sub) { Text $g $sub (Font 15 $true 'Bahnschrift SemiBold Condensed') $Col.text 64 82 'C' }
    if ($barPct -ge 0) { RoundBar $g 6 108 116 12 $barPct $barCol }
}
function Big-Cpu($s) {
    $bmp, $g = New-Tile
    $t = if ($s.cpuTemp -ne $null) { "$([int]$s.cpuTemp)$Deg" } else { '--' }
    Hero $g 'CPU' $Col.cpu ([int]$s.cpuLoad).ToString() '%' (Get-LevelColor $s.cpuLoad 60 85) "$(Fmt $s.cpuGhz 1) GHz$Dot$t" $s.cpuLoad (Get-LevelColor $s.cpuLoad 60 85)
    $g.Dispose(); $bmp
}
function Big-Gpu($s) {
    $bmp, $g = New-Tile; $gp = $s.gpu
    if ($gp.ok) { Hero $g 'GPU' $Col.gpu ([int]$gp.util).ToString() '%' (Get-LevelColor $gp.util 60 85) "$([int]$gp.temp)$Deg$Dot$([int]$gp.clock) MHz" (100 * $gp.power / $gp.plimit) $Col.gpu }
    else { Hero $g 'GPU' $Col.gpu '--' '' $Col.muted '' -1 $Col.gpu }
    $g.Dispose(); $bmp
}
function Big-Mem($s) {
    $bmp, $g = New-Tile
    $rp = 100 * $s.ramUsed / $s.ramTotal
    Hero $g 'RAM' $Col.mem ([int]$rp).ToString() '%' (Get-LevelColor $rp 75 90) "$(Fmt $s.ramUsed 1) / $([int]$s.ramTotal) GB" $rp $Col.mem
    $g.Dispose(); $bmp
}
function Big-Net($s) {
    $bmp, $g = New-Tile
    $d = FmtRate $s.netDown; $u = FmtRate $s.netUp
    $max = ($script:NetHist | Measure-Object -Maximum).Maximum
    $pct = if ($max -gt 0) { 100 * $s.netDown / $max } else { 0 }
    Hero $g 'DOWN' $Col.net $d[0] $d[1] $Col.text "UP $($u[0]) $($u[1])" $pct $Col.net
    $g.Dispose(); $bmp
}
function Big-Clock($s) {
    $bmp, $g = New-Tile; $now = Get-Date
    Text $g $now.ToString('dddd', $NbNo).ToUpper() (Font 13 $true 'Bahnschrift SemiBold') $Col.clock 6 5
    Text $g $now.ToString('HH:mm') (Font 54 $true 'Bahnschrift SemiBold') $Col.text 64 20 'C'
    Text $g $now.ToString('d. MMMM', $NbNo) (Font 15 $true 'Bahnschrift SemiBold Condensed') $Col.text 64 82 'C'
    $up = $s.uptime; $upTxt = if ($up.Days -gt 0) { "$($up.Days)d $($up.Hours)h" } else { "$($up.Hours)h $($up.Minutes)m" }
    Text $g "UPTIME $upTxt" (Font 13 $true 'Bahnschrift SemiBold Condensed') $Col.muted 64 106 'C'
    $g.Dispose(); $bmp
}

# ---------- style "duo": two large values per tile ----------
function Duo($g, [string]$title, [System.Drawing.Color]$accent, [string]$l1, [string]$v1, [string]$u1, [System.Drawing.Color]$c1, [string]$l2, [string]$v2, [string]$u2, [System.Drawing.Color]$c2, [double]$barPct) {
    $g.FillRectangle((Brush $accent), 0, 0, 3, $Size)
    Text $g $title (Font 9) $accent 8 3
    foreach ($row in @(@($l1, $v1, $u1, $c1, 14), @($l2, $v2, $u2, $c2, 66))) {
        $y = $row[4]
        Text $g $row[0] (Font 9 $false) $Col.muted 8 ($y + 2)
        $f = Font 32; $w = $g.MeasureString($row[1], $f).Width
        $uw = 0; if ($row[2]) { $uw = $g.MeasureString($row[2], (Font 11)).Width - 2 }
        Text $g $row[1] $f $row[3] (124 - $w + 4 - $uw) ($y + 8)
        if ($row[2]) { Text $g $row[2] (Font 11) $Col.muted 126 ($y + 28) 'R' }
    }
    $g.FillRectangle((Brush $Col.panel), 8, 62, 116, 1)
    if ($barPct -ge 0) { Bar $g 8 118 116 6 $barPct $accent }
}
function Duo-Cpu($s) {
    $bmp, $g = New-Tile
    $t = if ($s.cpuTemp -ne $null) { ([int]$s.cpuTemp).ToString() } else { '--' }
    $tc = if ($s.cpuTemp -ne $null) { Get-LevelColor $s.cpuTemp 70 85 } else { $Col.muted }
    Duo $g 'CPU' $Col.cpu 'LOAD' ([int]$s.cpuLoad).ToString() '%' (Get-LevelColor $s.cpuLoad 60 85) 'TEMP' $t $Deg $tc $s.cpuLoad
    $g.Dispose(); $bmp
}
function Duo-Gpu($s) {
    $bmp, $g = New-Tile; $gp = $s.gpu
    if ($gp.ok) { Duo $g 'GPU' $Col.gpu 'LOAD' ([int]$gp.util).ToString() '%' (Get-LevelColor $gp.util 60 85) 'TEMP' ([int]$gp.temp).ToString() $Deg (Get-LevelColor $gp.temp 70 83) $gp.util }
    else { Duo $g 'GPU' $Col.gpu 'LOAD' '--' '' $Col.muted 'TEMP' '--' '' $Col.muted -1 }
    $g.Dispose(); $bmp
}
function Duo-Mem($s) {
    $bmp, $g = New-Tile
    $rp = 100 * $s.ramUsed / $s.ramTotal
    $c = $s.disks | Select-Object -First 1
    Duo $g 'MEMORY' $Col.mem 'RAM' ([int]$rp).ToString() '%' (Get-LevelColor $rp 75 90) "$($c.id): FREE" ([int]$c.free).ToString() 'GB' $Col.text $rp
    $g.Dispose(); $bmp
}
function Duo-Net($s) {
    $bmp, $g = New-Tile
    $d = FmtRate $s.netDown; $u = FmtRate $s.netUp
    Duo $g 'NETWORK' $Col.net 'DOWN' $d[0] $d[1] $Col.text 'UP' $u[0] $u[1] $Col.text -1
    $g.Dispose(); $bmp
}
function Duo-Clock($s) {
    $bmp, $g = New-Tile; $now = Get-Date
    $up = $s.uptime; $upTxt = if ($up.Days -gt 0) { "$($up.Days)d $($up.Hours)h" } else { "$($up.Hours)h $($up.Minutes)m" }
    Duo $g $now.ToString('ddd d. MMM', $NbNo).ToUpper() $Col.clock 'TIME' $now.ToString('HH:mm') '' $Col.text 'UPTIME' $upTxt '' $Col.text -1
    $g.Dispose(); $bmp
}

# ---------- style "gauge": one large ring per tile ----------
# One thick ring, one big number, one line of context. Nothing smaller than 12 px.
$GaugeCx = 64; $GaugeCy = 60; $GaugeR = 46; $GaugeTh = 12
$NumFont = 'Bahnschrift SemiBold'; $NumFontC = 'Bahnschrift SemiBold Condensed'
function Arc($g, [single]$cx, [single]$cy, [single]$r, [single]$th, [single]$start, [single]$sweep, [System.Drawing.Color]$c) {
    $pen = New-Object System.Drawing.Pen $c, $th; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawArc($pen, (New-Object System.Drawing.RectangleF ($cx - $r), ($cy - $r), (2 * $r), (2 * $r)), $start, $sweep)
    $pen.Dispose()
}
function GaugeRing($g, [double]$pct, [System.Drawing.Color]$c) {
    $pct = [Math]::Max(0, [Math]::Min(100, $pct))
    Arc $g $GaugeCx $GaugeCy $GaugeR $GaugeTh 135 270 (C '#1C222E')
    if ($pct -gt 0.5) { Arc $g $GaugeCx $GaugeCy $GaugeR $GaugeTh 135 (270 * $pct / 100) $c }
}
# Title inside the ring, big value under it with a small unit, context line in the ring's opening.
function GaugeText($g, [string]$title, [System.Drawing.Color]$accent, [string]$value, [string]$unit, [System.Drawing.Color]$vcol, [string]$sub, [System.Drawing.Color]$subCol) {
    Text $g $title (Font 11 $true 'Bahnschrift SemiBold') $accent $GaugeCx 26 'C'
    $f = Font 40 $true $NumFont
    if ($value.Length -gt 3) { $f = Font 40 $true $NumFontC }
    $w = $g.MeasureString($value, $f).Width
    $uf = Font 15 $true $NumFontC
    $uw = 0; if ($unit) { $uw = $g.MeasureString($unit, $uf).Width - 4 }
    $x = $GaugeCx - ($w + $uw) / 2 + 3
    Text $g $value $f $vcol $x 36
    if ($unit) { Text $g $unit $uf $Col.muted ($x + $w - 6) 56 }
    if ($sub) { Text $g $sub (Font 13 $true $NumFontC) $subCol $GaugeCx 106 'C' }
}
function Gauge-Cpu($s) {
    $bmp, $g = New-Tile
    $lc = Get-LevelColor $s.cpuLoad 60 85
    GaugeRing $g $s.cpuLoad $lc
    $t = if ($s.cpuTemp -ne $null) { "$([int]$s.cpuTemp)$Deg" } else { '--' }
    GaugeText $g 'CPU' $Col.cpu ([int]$s.cpuLoad).ToString() '%' $Col.text "$(Fmt $s.cpuGhz 1) GHz$Dot$t" $Col.text
    $g.Dispose(); $bmp
}
function Gauge-Gpu($s) {
    $bmp, $g = New-Tile; $gp = $s.gpu
    if ($gp.ok) {
        GaugeRing $g $gp.util (Get-LevelColor $gp.util 60 85)
        GaugeText $g 'GPU' $Col.gpu ([int]$gp.util).ToString() '%' $Col.text "$([int]$gp.temp)$Deg$Dot$([int]$gp.power) W" $Col.text
    } else { GaugeRing $g 0 $Col.gpu; GaugeText $g 'GPU' $Col.gpu '--' '' $Col.muted '' $Col.muted }
    $g.Dispose(); $bmp
}
function Gauge-Mem($s) {
    $bmp, $g = New-Tile
    $rp = 100 * $s.ramUsed / $s.ramTotal
    GaugeRing $g $rp (Get-LevelColor $rp 75 90)
    GaugeText $g 'RAM' $Col.mem ([int]$rp).ToString() '%' $Col.text "$(Fmt $s.ramUsed 1) / $([int]$s.ramTotal) GB" $Col.text
    $g.Dispose(); $bmp
}
function Gauge-Net($s) {
    $bmp, $g = New-Tile
    $d = FmtRate $s.netDown; $u = FmtRate $s.netUp
    $max = ($script:NetHist | Measure-Object -Maximum).Maximum
    $pct = if ($max -gt 0) { 100 * $s.netDown / $max } else { 0 }
    GaugeRing $g $pct $Col.net
    GaugeText $g 'DOWN' $Col.net $d[0] $d[1] $Col.text "UP $($u[0]) $($u[1])" $Col.muted
    $g.Dispose(); $bmp
}
function Gauge-Clock($s) {
    $bmp, $g = New-Tile; $now = Get-Date
    GaugeRing $g (100 * $now.Minute / 60) $Col.clock
    Text $g $now.ToString('dddd', $NbNo).ToUpper() (Font 11 $true 'Bahnschrift SemiBold') $Col.clock $GaugeCx 26 'C'
    Text $g $now.ToString('HH:mm') (Font 36 $true $NumFont) $Col.text $GaugeCx 38 'C'
    $up = $s.uptime; $upTxt = if ($up.Days -gt 0) { "$($up.Days)d $($up.Hours)h" } else { "$($up.Hours)h $($up.Minutes)m" }
    Text $g "$($now.ToString('d. MMM', $NbNo))$Dot$upTxt" (Font 13 $true $NumFontC) $Col.text $GaugeCx 106 'C'
    $g.Dispose(); $bmp
}

# ---------- style "retro": 5x7 pixel font, segment bars, scanlines ----------
$Px = @{}
$PxRows = @'
0 .###. #...# #..## #.#.# ##..# #...# .###.
1 ..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.
2 .###. #...# ....# ...#. ..#.. .#... #####
3 .###. #...# ....# ..##. ....# #...# .###.
4 ...#. ..##. .#.#. #..#. ##### ...#. ...#.
5 ##### #.... ####. ....# ....# #...# .###.
6 ..##. .#... #.... ####. #...# #...# .###.
7 ##### ....# ...#. ..#.. .#... .#... .#...
8 .###. #...# #...# .###. #...# #...# .###.
9 .###. #...# #...# .#### ....# ...#. .##..
A .###. #...# #...# ##### #...# #...# #...#
B ####. #...# #...# ####. #...# #...# ####.
C .###. #...# #.... #.... #.... #...# .###.
D ####. #...# #...# #...# #...# #...# ####.
E ##### #.... #.... ####. #.... #.... #####
F ##### #.... #.... ####. #.... #.... #....
G .###. #...# #.... #.### #...# #...# .####
H #...# #...# #...# ##### #...# #...# #...#
I .###. ..#.. ..#.. ..#.. ..#.. ..#.. .###.
J ..### ...#. ...#. ...#. ...#. #..#. .##..
K #...# #..#. #.#.. ##... #.#.. #..#. #...#
L #.... #.... #.... #.... #.... #.... #####
M #...# ##.## #.#.# #.#.# #...# #...# #...#
N #...# #...# ##..# #.#.# #..## #...# #...#
O .###. #...# #...# #...# #...# #...# .###.
P ####. #...# #...# ####. #.... #.... #....
Q .###. #...# #...# #...# #.#.# #..#. .##.#
R ####. #...# #...# ####. #.#.. #..#. #...#
S .#### #.... #.... .###. ....# ....# ####.
T ##### ..#.. ..#.. ..#.. ..#.. ..#.. ..#..
U #...# #...# #...# #...# #...# #...# .###.
V #...# #...# #...# #...# #...# .#.#. ..#..
W #...# #...# #...# #.#.# #.#.# ##.## #...#
X #...# #...# .#.#. ..#.. .#.#. #...# #...#
Y #...# #...# .#.#. ..#.. ..#.. ..#.. ..#..
Z ##### ....# ...#. ..#.. .#... #.... #####
% ##... ##..# ...#. ..#.. .#... #..## ...##
. ..... ..... ..... ..... ..... .##.. .##..
: ..... .##.. .##.. ..... .##.. .##.. .....
/ ....# ....# ...#. ..#.. .#... #.... #....
- ..... ..... ..... ##### ..... ..... .....
^ ..#.. .###. ##### ..#.. ..#.. ..#.. ..#..
v ..#.. ..#.. ..#.. ..#.. ##### .###. ..#..
'@
foreach ($line in $PxRows -split "`n") {
    $p = $line.Trim() -split ' '
    if ($p.Count -eq 8) { $Px[$p[0]] = $p[1..7] }
}
$Px[[string][char]0xD8] = '.###.', '#..##', '#.#.#', '#.#.#', '#.#.#', '##..#', '.###.'   # Ø
$Px[[string][char]0xB0] = '.##..', '#..#.', '.##..', '.....', '.....', '.....', '.....'   # °
# Proportional: trim empty columns on each side of a glyph.
function PxGlyph([string]$ch) {
    if ($ch -eq ' ') { return @{ rows = @('.....') * 7; min = 0; w = 2 } }
    $rows = $Px[$ch]; if (-not $rows) { $rows = $Px['-'] }
    $min = 5; $max = -1
    foreach ($r in $rows) { for ($c = 0; $c -lt 5; $c++) { if ($r[$c] -eq '#') { if ($c -lt $min) { $min = $c }; if ($c -gt $max) { $max = $c } } } }
    if ($max -lt 0) { return @{ rows = $rows; min = 0; w = 2 } }   # space
    @{ rows = $rows; min = $min; w = $max - $min + 1 }
}
function PxWidth([string]$s, [int]$sc) {
    $w = 0; foreach ($ch in $s.ToUpper().ToCharArray()) { $w += ((PxGlyph ([string]$ch)).w + 1) * $sc }
    $w - $sc
}
function PxText($g, [string]$s, [single]$x, [single]$y, [int]$sc, [System.Drawing.Color]$c, [string]$align = 'L') {
    $w = PxWidth $s $sc
    if ($align -eq 'C') { $x = [Math]::Round($x - $w / 2) } elseif ($align -eq 'R') { $x = $x - $w }
    $b = Brush $c
    foreach ($ch in $s.ToUpper().ToCharArray()) {
        $gl = PxGlyph ([string]$ch)
        for ($r = 0; $r -lt 7; $r++) { for ($col = 0; $col -lt $gl.w; $col++) {
            if ($gl.rows[$r][$gl.min + $col] -eq '#') { $g.FillRectangle($b, $x + $col * $sc, $y + $r * $sc, $sc, $sc) }
        } }
        $x += ($gl.w + 1) * $sc
    }
}
$Retro = @{
    bg = C '#05060A'; dim = C '#1E2230'; text = C '#F4F4F0'; muted = C '#8C92A6'
    cpu = C '#19E6FF'; gpu = C '#3DFF5E'; mem = C '#FF3FD8'; net = C '#FFB000'; clock = C '#FFF04A'
    good = C '#3DFF5E'; warn = C '#FFB000'; bad = C '#FF3B3B'
}
# 12-segment bar. $vu colours segments green/amber/red by position (VU-meter style); otherwise one colour.
function SegBar($g, [single]$y, [double]$pct, [System.Drawing.Color]$c, [bool]$vu) {
    $n = 12; $lit = [Math]::Round($n * [Math]::Max(0, [Math]::Min(100, $pct)) / 100)
    for ($i = 0; $i -lt $n; $i++) {
        $col = $Retro.dim
        if ($i -lt $lit) { $col = $c; if ($vu) { $col = $Retro.good; if ($i -ge 7) { $col = $Retro.warn }; if ($i -ge 10) { $col = $Retro.bad } } }
        $g.FillRectangle((Brush $col), 7 + $i * 10, $y, 8, 14)
    }
}
function RetroFrame($g, [System.Drawing.Color]$accent, [string]$title) {
    $g.SmoothingMode = 'None'
    $g.Clear($Retro.bg)
    $g.FillRectangle((Brush $accent), 0, 0, $Size, 2); $g.FillRectangle((Brush $accent), 0, $Size - 2, $Size, 2)
    $g.FillRectangle((Brush $accent), 0, 0, 2, $Size); $g.FillRectangle((Brush $accent), $Size - 2, 0, 2, $Size)
    PxText $g $title 7 8 2 $accent
}
function Scanlines($g) {
    $b = Brush ([System.Drawing.Color]::FromArgb(40, 0, 0, 0))
    for ($y = 1; $y -lt $Size; $y += 2) { $g.FillRectangle($b, 0, $y, $Size, 1) }
}
# Big value (scale 5) with a small unit, context line, segment bar.
function RetroTile([System.Drawing.Color]$accent, [string]$title, [string]$value, [string]$unit, [System.Drawing.Color]$vcol, [string]$sub, [double]$pct, [System.Drawing.Color]$barCol, [bool]$vu) {
    $bmp, $g = New-Tile
    RetroFrame $g $accent $title
    $sc = 5; if ((PxWidth $value 5) + (PxWidth $unit 2) + 6 -gt 112) { $sc = 4 }
    $vw = PxWidth $value $sc; $uw = 0; if ($unit) { $uw = (PxWidth $unit 2) + 6 }
    $x = [Math]::Round((128 - $vw - $uw) / 2)
    PxText $g $value $x 30 $sc $vcol
    if ($unit) { PxText $g $unit ($x + $vw + 6) (30 + 7 * $sc - 14) 2 $Retro.muted }
    if ($sub) { PxText $g $sub 64 78 2 $Retro.text 'C' }
    SegBar $g 102 $pct $barCol $vu
    Scanlines $g
    $g.Dispose(); $bmp
}
function Retro-Cpu($s) {
    $t = if ($s.cpuTemp -ne $null) { "$([int]$s.cpuTemp)$Deg" } else { '--' }
    RetroTile $Retro.cpu 'CPU' ([int]$s.cpuLoad).ToString() '%' $Retro.text "$(Fmt $s.cpuGhz 1)GHZ $t" $s.cpuLoad $Retro.cpu $true
}
function Retro-Gpu($s) {
    $gp = $s.gpu
    if ($gp.ok) { RetroTile $Retro.gpu 'GPU' ([int]$gp.util).ToString() '%' $Retro.text "$([int]$gp.temp)$Deg $([int]$gp.power)W" $gp.util $Retro.gpu $true }
    else { RetroTile $Retro.gpu 'GPU' '--' '' $Retro.muted 'NO DATA' 0 $Retro.gpu $false }
}
function Retro-Mem($s) {
    $rp = 100 * $s.ramUsed / $s.ramTotal
    RetroTile $Retro.mem 'RAM' ([int]$rp).ToString() '%' $Retro.text "$(Fmt $s.ramUsed 1)/$([int]$s.ramTotal)GB" $rp $Retro.mem $false
}
function Retro-Net($s) {
    $d = FmtRate $s.netDown; $u = FmtRate $s.netUp
    $max = ($script:NetHist | Measure-Object -Maximum).Maximum
    $pct = if ($max -gt 0) { 100 * $s.netDown / $max } else { 0 }
    RetroTile $Retro.net 'v NET' $d[0] $d[1] $Retro.text "^ $($u[0]) $($u[1])" $pct $Retro.net $false
}
# Knight Rider sweep over the 12 segments: a bright head with a fading tail, bouncing left-right.
function SweepBar($g, [single]$y, [int]$pos, [System.Drawing.Color]$c) {
    for ($i = 0; $i -lt 12; $i++) {
        $d = [Math]::Abs($i - $pos)
        $col = $Retro.dim
        if ($d -eq 0) { $col = $Retro.text } elseif ($d -eq 1) { $col = $c } elseif ($d -eq 2) { $col = [System.Drawing.Color]::FromArgb(110, $c) }
        $g.FillRectangle((Brush $col), 7 + $i * 10, $y, 8, 14)
    }
}
# Animated: 8 frames, uploaded once a minute (the hash check skips identical frames), looped by the device.
# The colon blinks (1 s on, 1 s off) and the bar sweeps back and forth.
function Retro-Clock($s) {
    $now = Get-Date
    $up = $s.uptime; $upTxt = if ($up.Days -gt 0) { "$($up.Days)D $($up.Hours)H" } else { "$($up.Hours)H" }
    $sweep = 1, 4, 7, 10, 10, 7, 4, 1
    0..7 | ForEach-Object {
        $bmp, $g = New-Tile
        RetroFrame $g $Retro.clock $now.ToString('dddd', $NbNo)
        $t = $now.ToString('HH:mm'); if ($_ -ge 4) { $t = $t.Replace(':', ' ') }   # space is as wide as the colon
        PxText $g $t 64 30 4 $Retro.text 'C'
        PxText $g $now.ToString('d. MMM', $NbNo) 64 66 2 $Retro.text 'C'
        PxText $g "UP $upTxt" 64 84 2 $Retro.muted 'C'
        SweepBar $g 102 $sweep[$_] $Retro.clock
        Scanlines $g
        $g.Dispose(); $bmp
    }
}

function Get-TileSet([string]$style) {
    switch ($style) {
        'retro' { @({ param($s) Retro-Cpu $s }, { param($s) Retro-Gpu $s }, { param($s) Retro-Mem $s }, { param($s) Retro-Net $s }, { param($s) Retro-Clock $s }) }
        'big'   { @({ param($s) Big-Cpu $s }, { param($s) Big-Gpu $s }, { param($s) Big-Mem $s }, { param($s) Big-Net $s }, { param($s) Big-Clock $s }) }
        'duo'   { @({ param($s) Duo-Cpu $s }, { param($s) Duo-Gpu $s }, { param($s) Duo-Mem $s }, { param($s) Duo-Net $s }, { param($s) Duo-Clock $s }) }
        'gauge' { @({ param($s) Gauge-Cpu $s }, { param($s) Gauge-Gpu $s }, { param($s) Gauge-Mem $s }, { param($s) Gauge-Net $s }, { param($s) Gauge-Clock $s }) }
        default { @({ param($s) Tile-Cpu $s }, { param($s) Tile-Gpu $s }, { param($s) Tile-Mem $s }, { param($s) Tile-Net $s }, { param($s) Tile-Clock $s }) }
    }
}

# ---------- device ----------
$JpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
function Encode-Jpeg([System.Drawing.Bitmap]$bmp) {
    # Start at -Quality and step down until the file is under MaxBytes (never below quality 40).
    $q = $Quality
    while ($true) {
        $ep = New-Object System.Drawing.Imaging.EncoderParameters 1
        $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]$q)
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, $JpegCodec, $ep)
        $jpeg = $ms.ToArray()
        if ($MaxBytes -le 0 -or $jpeg.Length -le $MaxBytes -or $q -le 40) { break }
        $q -= 6
    }
    $script:LastQuality = $q
    if ($MinBytes -gt 0 -and $jpeg.Length -lt $MinBytes) { $jpeg = Pad-Jpeg $jpeg ($MinBytes - $jpeg.Length) }
    $jpeg
}
function Invoke-Divoom($body) {
    Invoke-RestMethod -Uri $Api -Method Post -ContentType 'application/json' -DisableKeepAlive `
        -Body ($body | ConvertTo-Json -Compress -Depth 5) -TimeoutSec 10
}
$script:PicId = 0
$script:LastHash = @{}
# Sends one picture, or an animation when given several frames (same PicID, PicOffset 0..n-1; the device
# loops it locally at $FrameMs per frame). Returns $false and sends nothing when the frames are identical
# to the last ones sent to this screen: the device processes ~1 picture/s, so unchanged tiles must not take a slot.
$FrameMs = 250
function Send-Tile([System.Drawing.Bitmap[]]$frames, [int]$lcd) {
    $jpegs = @(foreach ($f in $frames) { , (Encode-Jpeg $f) })
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = ($jpegs | ForEach-Object { [BitConverter]::ToString($md5.ComputeHash($_)) }) -join '|'
    if ($script:LastHash[$lcd] -eq $hash) { return $false }
    $script:LastHash[$lcd] = $hash
    $script:LastBytes = ($jpegs | Measure-Object Length -Sum).Sum
    $arr = @(0, 0, 0, 0, 0); $arr[$lcd] = 1
    if ($FixedIds) { $id = $lcd + 1 } else { $script:PicId++; $id = $script:PicId }
    $speed = $PicSpeed; if ($jpegs.Count -gt 1) { $speed = $FrameMs }
    for ($i = 0; $i -lt $jpegs.Count; $i++) {
        Invoke-Divoom @{ Command = 'Draw/SendHttpGif'; LcdArray = $arr; PicNum = $jpegs.Count; PicWidth = $Size; PicOffset = $i
                         PicID = $id; PicSpeed = $speed; PicData = [Convert]::ToBase64String($jpegs[$i]) } | Out-Null
    }
    $true
}
# Insert a JPEG COM (comment) segment of $extra bytes right after the SOI marker. Decoders ignore it.
function Pad-Jpeg([byte[]]$jpeg, [int]$extra) {
    $len = [Math]::Max(2, [Math]::Min(65533, $extra + 2))   # segment length field includes itself
    $seg = New-Object byte[] ($len + 2)
    $seg[0] = 0xFF; $seg[1] = 0xFE; $seg[2] = [byte]($len -shr 8); $seg[3] = [byte]($len -band 0xFF)
    for ($i = 4; $i -lt $seg.Length; $i++) { $seg[$i] = 0x20 }
    $jpeg[0..1] + $seg + $jpeg[2..($jpeg.Length - 1)]
}
function Reset-Device {
    Invoke-Divoom @{ Command = 'Channel/SetIndex'; SelectIndex = 3 } | Out-Null
    Invoke-Divoom @{ Command = 'Draw/ResetHttpGifId' } | Out-Null
    $script:PicId = 0
    $script:LastHash = @{}   # everything must be re-sent after a reset
}

# ---------- main ----------
$Tiles = Get-TileSet $Style
# Minimum seconds between sends per tile. Memory and clock change slowly, so skipping them
# makes room for the per-picture gap; the clock tile is also forced when the minute changes.
$TilePeriod = @(0, 0, 10, 0, 10)
$LastSent = @(0, 0, 0, 0, 0) | ForEach-Object { [DateTime]::MinValue }
$script:LastMinute = -1

if ($Preview) {
    # Renders every style to preview\<style>\tileN.png plus a 2x comparison sheet.
    $dir = Join-Path $PSScriptRoot 'preview'
    Get-Stats | Out-Null; Start-Sleep 1   # second sample gives real deltas for top process / sparklines
    $s = Get-Stats
    $sheet = New-Object System.Drawing.Bitmap (5 * 2 * $Size + 6 * 8 + 90), ($Styles.Count * (2 * $Size + 8) + 8)
    $sg = [System.Drawing.Graphics]::FromImage($sheet); $sg.Clear([System.Drawing.Color]::FromArgb(40, 40, 48))
    $sg.InterpolationMode = 'NearestNeighbor'; $sg.PixelOffsetMode = 'Half'
    for ($r = 0; $r -lt $Styles.Count; $r++) {
        $sd = Join-Path $dir $Styles[$r]; New-Item -ItemType Directory -Force $sd | Out-Null
        $set = Get-TileSet $Styles[$r]
        Text $sg $Styles[$r] (Font 16) $Col.text 8 (8 + $r * (2 * $Size + 8) + 110)
        for ($i = 0; $i -lt 5; $i++) {
            $frames = @(& $set[$i] $s); $bmp = $frames[0]
            $bmp.Save((Join-Path $sd "tile$i.png"), [System.Drawing.Imaging.ImageFormat]::Png)
            for ($k = 1; $k -lt $frames.Count; $k++) { $frames[$k].Save((Join-Path $sd "tile$i-frame$k.png"), [System.Drawing.Imaging.ImageFormat]::Png) }
            $jpeg = Encode-Jpeg $bmp
            [IO.File]::WriteAllBytes((Join-Path $sd "tile$i.jpg"), $jpeg)   # what the device actually receives
            Write-Host ("{0,-7} tile{1}: {2} bytes q{3}" -f $Styles[$r], $i, $jpeg.Length, $script:LastQuality)
            $sg.DrawImage($bmp, 90 + 8 + $i * (2 * $Size + 8), 8 + $r * (2 * $Size + 8), 2 * $Size, 2 * $Size)
        }
    }
    $sheet.Save((Join-Path $dir 'styles.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    "Saved $dir\<style>\tile0..4.png and $dir\styles.png"; return
}

Write-Host "Pushing PC status to Times Gate at $Ip (gap ${Gap}s per picture). Ctrl+C to stop."
$connected = $false
$demoStart = Get-Date; $demoIdx = -1
while ($true) {
    try {
        if (-not $connected) { Reset-Device; $connected = $true; Write-Host 'Connected.' }
        if ($Demo) {
            $idx = [int][Math]::Floor(((Get-Date) - $demoStart).TotalSeconds / 20) % $Styles.Count
            if ($idx -ne $demoIdx) {
                $demoIdx = $idx; $Tiles = Get-TileSet $Styles[$idx]
                $LastSent = 0..4 | ForEach-Object { [DateTime]::MinValue }   # repaint every screen
                Write-Host "Demo: style '$($Styles[$idx])'"
            }
        }
        $s = Get-Stats
        $now = Get-Date
        $cycleStart = $now
        $minuteTurned = $now.Minute -ne $script:LastMinute; $script:LastMinute = $now.Minute
        $map = [int[]]($Layout -split ',')   # not $layout: PowerShell variable names are case-insensitive
        foreach ($i in [int[]]($Order -split ',')) {
            $t = $map[$i]
            $due = ($now - $LastSent[$i]).TotalSeconds -ge $TilePeriod[$t]
            if (-not $due -and -not ($t -eq 4 -and $minuteTurned)) { continue }
            $frames = @(& $Tiles[$t] $s)      # one bitmap, or several for an animated tile
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $sent = Send-Tile $frames $i
            $LastSent[$i] = Get-Date
            if (-not $sent) { continue }
            if ($Log) { Write-Host ("{0:HH:mm:ss.f} screen {1} tile {2} id {3} {4} frame(s) {5} bytes q{6} {7} ms" -f (Get-Date), $i, $t, $script:PicId, $frames.Count, $script:LastBytes, $script:LastQuality, $sw.ElapsedMilliseconds) }
            if ($Gap -gt 0) { Start-Sleep -Milliseconds ($Gap * 1000) }
        }
        # IDs grow forever otherwise; reset occasionally and immediately repaint.
        if ($script:PicId -gt 5000) { Reset-Device }
    } catch {
        Write-Warning "Device error: $($_.Exception.Message) - retrying in 10s"
        $connected = $false; Start-Sleep 10; continue
    }
    if ($Interval -gt 0) { Start-Sleep $Interval }
    # Don't spin at full speed when nothing changed: at least 1 s between samples.
    $left = 1000 - ((Get-Date) - $cycleStart).TotalMilliseconds
    if ($left -gt 0) { Start-Sleep -Milliseconds $left }
}
