# Extracts the HTTP traffic between the Android emulator and the Times Gate from a pcap file written by
# capture-app-traffic.ps1 (emulator -tcpdump). Pure PowerShell, no Wireshark needed.
#   .\analyse-capture.ps1 -Pcap E:\AndroidSdk\capture\20261026-200000.pcap [-Ip 192.168.2.169] [-MaxBody 600]
param(
    [Parameter(Mandatory)][string]$Pcap,
    [string]$Ip = '192.168.2.169',
    [int]$MaxBody = 600          # characters of each payload to print (base64 blobs get long)
)
# Shared read: the emulator keeps the file open while it is still capturing.
$fs = [IO.File]::Open($Pcap, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
$bytes = New-Object byte[] $fs.Length; [void]$fs.Read($bytes, 0, $bytes.Length); $fs.Close()
$magic = '{0:X8}' -f [BitConverter]::ToUInt32($bytes, 0)   # compare as text: PS 5.1 parses 0xA1B2C3D4 as a negative Int32
# Yields one @{p=offset; len=bytes; ts=unix seconds; usec=microseconds} per packet, for pcap or pcapng (pktmon output).
function Get-Packets {
    if ($magic -in 'A1B2C3D4', 'A1B23C4D') {
        $script:linkType = [BitConverter]::ToUInt32($bytes, 20)
        $pos = 24
        while ($pos + 16 -le $bytes.Length) {
            $len = [BitConverter]::ToUInt32($bytes, $pos + 8)
            @{ p = $pos + 16; len = $len; ts = [BitConverter]::ToUInt32($bytes, $pos); usec = [BitConverter]::ToUInt32($bytes, $pos + 4) }
            $pos += 16 + $len
        }
    } elseif ($magic -eq '0A0D0D0A') {
        $script:linkType = 1; $pos = 0
        while ($pos + 12 -le $bytes.Length) {
            $type = [BitConverter]::ToUInt32($bytes, $pos); $blen = [BitConverter]::ToUInt32($bytes, $pos + 4)
            if ($blen -lt 12) { break }
            if ($type -eq 1) { $script:linkType = [BitConverter]::ToUInt16($bytes, $pos + 8) }
            if ($type -eq 6) {   # enhanced packet block
                $tsHi = [BitConverter]::ToUInt32($bytes, $pos + 12); $tsLo = [BitConverter]::ToUInt32($bytes, $pos + 16)
                $t = ([uint64]$tsHi -shl 32) -bor $tsLo   # microseconds by default
                @{ p = $pos + 28; len = [BitConverter]::ToUInt32($bytes, $pos + 20); ts = [uint32][Math]::Floor($t / 1000000); usec = [uint32]($t % 1000000) }
            }
            $pos += $blen
        }
    } else { throw "Not a pcap/pcapng file (magic $magic)" }
}
$n = 0; $flows = @{}
$target = [BitConverter]::ToUInt32(([Net.IPAddress]::Parse($Ip)).GetAddressBytes(), 0)
foreach ($pk in (Get-Packets)) {
    $p = $pk.p; $len = $pk.len; $ts = $pk.ts; $usec = $pk.usec; $n++
    $ipOff = if ($linkType -eq 1) { $p + 14 } else { $p }
    if ($ipOff + 20 -gt $bytes.Length -or ($bytes[$ipOff] -shr 4) -ne 4) { continue }
    $ihl = ($bytes[$ipOff] -band 0x0F) * 4
    $proto = $bytes[$ipOff + 9]
    $src = [BitConverter]::ToUInt32($bytes, $ipOff + 12); $dst = [BitConverter]::ToUInt32($bytes, $ipOff + 16)
    if ($src -ne $target -and $dst -ne $target) { continue }
    if ($proto -ne 6) { continue }
    $tcp = $ipOff + $ihl
    # [int] casts matter: in PS 5.1 a [byte] shifted left stays a byte (0x23 -shl 8 = 0).
    $sport = ([int]$bytes[$tcp] -shl 8) + $bytes[$tcp + 1]; $dport = ([int]$bytes[$tcp + 2] -shl 8) + $bytes[$tcp + 3]
    $doff = ($bytes[$tcp + 12] -shr 4) * 4
    $totalLen = ([int]$bytes[$ipOff + 2] -shl 8) + $bytes[$ipOff + 3]
    $payLen = $totalLen - $ihl - $doff
    if ($payLen -le 0) { continue }
    # pktmon logs the same packet once per network-stack layer: keep the first copy only.
    $seq = [BitConverter]::ToUInt32($bytes, $tcp + 4)
    $dupKey = "$src|$dst|$sport|$dport|$seq|$payLen"
    if ($dupKey -eq $lastKey) { continue }; $lastKey = $dupKey
    $payload = [Text.Encoding]::ASCII.GetString($bytes, $tcp + $doff, $payLen)
    $dir = if ($dst -eq $target) { "-> device:$dport" } else { "<- device:$sport" }
    $key = "$dir"
    $flows[$key] = ($flows[$key] + $payLen)
    $t = [DateTimeOffset]::FromUnixTimeSeconds($ts).ToLocalTime().ToString('HH:mm:ss') + ('.{0:000}' -f [int]($usec / 1000))
    $shown = $payload -replace '[^\x20-\x7E\r\n]', '.'
    if ($shown.Length -gt $MaxBody) { $shown = $shown.Substring(0, $MaxBody) + " ...[$($payload.Length) bytes]" }
    "[$t] $dir ($payLen bytes)`n$shown`n"
}
"--- $n packets in file; bytes per direction/port:"
$flows.GetEnumerator() | Sort-Object Name | ForEach-Object { "  $($_.Name): $($_.Value)" }
