# desk.ps1 - Jiecang JCB36NE3A-230 control over the RJ11 "F" port
# Verified on 2026-11-09. Frame: F2 F2 CMD LEN PARAMS... CHK 7E
# CHK = (CMD + LEN + PARAMS...) & 0xFF   <-- address bytes F1 F1 are NOT included
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File desk.ps1 status
#   powershell -ExecutionPolicy Bypass -File desk.ps1 goto -Value 1000
#   powershell -ExecutionPolicy Bypass -File desk.ps1 up / down / stop / read
#
param(
  [ValidateSet('status','read','up','down','stop','goto')]
  [string]$Cmd = 'status',
  [int]$Value = 0,
  [string]$Port = 'COM3'
)

$ErrorActionPreference = 'Stop'

function Open-Desk([string]$name) {
  $sp = [System.IO.Ports.SerialPort]::new($name, 9600, 'None', 8, 'One')
  $sp.ReadTimeout = 200
  $sp.Open()
  Start-Sleep -Milliseconds 400
  return $sp
}

function Send-Frame($sp, [int[]]$payload) {
  $cs = 0
  foreach ($b in $payload) { $cs = (($cs + $b) -band 0xFF) }
  $fr = [byte[]]((@(0xF1, 0xF1) + $payload) + $cs + 0x7E)
  # Discard BEFORE writing: the box answers in ~16 ms, discarding afterwards
  # can eat the head of the reply.
  $sp.DiscardInBuffer()
  $sp.Write($fr, 0, $fr.Length)
}

# Returns array of frames: each frame is @{ Cmd; Len; Params }
function Read-Frames($sp, [int]$ms) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $buf = New-Object System.Collections.ArrayList
  while ($sw.ElapsedMilliseconds -lt $ms) {
    while ($sp.BytesToRead -gt 0) { [void]$buf.Add($sp.ReadByte()) }
    Start-Sleep -Milliseconds 5
  }
  $out = @()
  $i = 0
  while ($i + 5 -lt $buf.Count) {
    if ($buf[$i] -ne 0xF2 -or $buf[$i + 1] -ne 0xF2) { $i++; continue }
    $len = $buf[$i + 3]
    $total = 6 + $len                    # F2 F2 CMD LEN params CHK 7E
    if ($i + $total -gt $buf.Count) { break }
    $cs = 0
    for ($k = 2; $k -lt 4 + $len; $k++) { $cs = (($cs + $buf[$i + $k]) -band 0xFF) }
    if ($cs -eq $buf[$i + $total - 2] -and $buf[$i + $total - 1] -eq 0x7E) {
      $prm = @()
      for ($k = 0; $k -lt $len; $k++) { $prm += $buf[$i + 4 + $k] }
      $out += [pscustomobject]@{ Cmd = $buf[$i + 2]; Len = $len; Params = $prm }
      $i += $total
    } else {
      $i++
    }
  }
  return $out
}

# Ask 07 (returns memories + height). Retries because the first frame after
# opening the port is always lost on this box.
function Get-Poll($sp) {
  for ($try = 0; $try -lt 4; $try++) {
    Send-Frame $sp @(0x07, 0x00)
    $f = Read-Frames $sp 320
    if ($f.Count -gt 0) { return $f }
    Start-Sleep -Milliseconds 120
  }
  return @()
}

function Get-Height($frames) {
  foreach ($f in $frames) {
    if ($f.Cmd -eq 0x01 -and $f.Len -eq 3) {
      return ([int]$f.Params[0] * 256 + [int]$f.Params[1])
    }
  }
  return $null
}

$sp = Open-Desk $Port
try {
  switch ($Cmd) {
    'read' {
      $f = Get-Poll $sp
      $h = Get-Height $f
      if ($h -ne $null) { Write-Output "$h" } else { Write-Output "ERR no reply" }
    }
    'status' {
      $f = Get-Poll $sp
      $h = Get-Height $f
      "Height      : $h mm"
      $names = @{ 0x25 = 'Memory 1'; 0x26 = 'Memory 2'; 0x27 = 'Memory 3'; 0x28 = 'Memory 4' }
      foreach ($fr in $f) {
        if ($names.ContainsKey([int]$fr.Cmd) -and $fr.Len -eq 2) {
          "{0,-12}: {1} mm" -f $names[[int]$fr.Cmd], ([int]$fr.Params[0] * 256 + [int]$fr.Params[1])
        }
      }
      Send-Frame $sp @(0x20, 0x00)
      foreach ($fr in (Read-Frames $sp 400)) {
        if ($fr.Cmd -eq 0x20) { "Limit flags : 0x{0:X2}" -f $fr.Params[0] }
        if ($fr.Cmd -eq 0x21) { "Soft max    : {0} mm" -f ([int]$fr.Params[0] * 256 + [int]$fr.Params[1]) }
        if ($fr.Cmd -eq 0x22) { "Soft min    : {0} mm" -f ([int]$fr.Params[0] * 256 + [int]$fr.Params[1]) }
      }
    }
    'up'    { Send-Frame $sp @(0x01, 0x00); Start-Sleep -Milliseconds 2500; "done: $(Get-Height (Get-Poll $sp)) mm" }
    'down'  { Send-Frame $sp @(0x02, 0x00); Start-Sleep -Milliseconds 2500; "done: $(Get-Height (Get-Poll $sp)) mm" }
    'stop'  { 1..3 | ForEach-Object { Send-Frame $sp @(0x2B, 0x00); Start-Sleep -Milliseconds 30 }; "stop sent" }
    'goto'  {
      if ($Value -lt 600 -or $Value -gt 1400) { throw "Value out of sane range" }
      $hi = [int][math]::Floor($Value / 256)
      $lo = $Value -band 0xFF
      $h0 = Get-Height (Get-Poll $sp)
      Send-Frame $sp @(0x1B, 0x02, $hi, $lo)
      # Retry once if nothing moved within 700 ms (known race right after a stop)
      Start-Sleep -Milliseconds 700
      $h1 = Get-Height (Get-Poll $sp)
      if ($h1 -ne $null -and $h1 -eq $h0) {
        Send-Frame $sp @(0x1B, 0x02, $hi, $lo)
      }
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $last = $h0; $steady = 0
      while ($sw.ElapsedMilliseconds -lt 30000) {
        Start-Sleep -Milliseconds 400
        $h = Get-Height (Get-Poll $sp)
        if ($h -eq $null) { continue }
        if ([math]::Abs($h - $last) -le 1) { $steady++ } else { $steady = 0 }
        $last = $h
        if ($steady -ge 3) { break }
      }
      "target $Value mm -> reached $last mm (err $($last - $Value) mm)"
    }
  }
}
finally {
  $sp.Close()
}
