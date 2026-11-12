# desk-presets.ps1 - program the 4 memory presets on JCB36NE3A-230 via the RJ11 "F" port
#
# Protocol facts (verified 2026-11-09):
#   frame : F1 F1 CMD LEN PARAMS... CHK 7E   (CHK = CMD+LEN+PARAMS, address bytes excluded)
#   GOTO  : CMD 1B, LEN 02, big-endian uint16 mm
#   SAVE  : CMD 03 / 04 / 25 / 26  (LEN 00) = store CURRENT height as preset 1/2/3/4
#   MOVE  : CMD 05 / 06 / 27 / 28  (LEN 00)
#   the preset value cannot be written directly - you must drive to the height then save
#
# IMPORTANT: polling with 0x07 during a self-driven move interferes with the motion,
# so MoveTo waits passively and only checks after the expected travel time.

param(
  [ValidateSet('check', 'apply', 'verify', 'test')]
  [string]$Action = 'check',
  [int]$Only = 0,
  [string]$Port = 'COM3'
)

$ErrorActionPreference = 'Stop'

# --- target presets: soft min, 1/3, 2/3, soft max ---
$MIN_H = 850
$MAX_H = 1130
$TARGETS = @(
  @{ Index = 1; Height = $MIN_H;                              Save = 0x03; Move = 0x05 },
  @{ Index = 2; Height = [int][math]::Round($MIN_H + ($MAX_H - $MIN_H) / 3.0); Save = 0x04; Move = 0x06 },
  @{ Index = 3; Height = [int][math]::Round($MIN_H + ($MAX_H - $MIN_H) * 2 / 3.0); Save = 0x25; Move = 0x27 },
  @{ Index = 4; Height = $MAX_H;                              Save = 0x26; Move = 0x28 }
)

function HexStr([int[]]$a) { ($a | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }

function Open-Desk([string]$name) {
  $sp = [System.IO.Ports.SerialPort]::new($name, 9600, 'None', 8, 'One')
  $sp.ReadTimeout = 200
  $sp.Open()
  Start-Sleep -Milliseconds 400
  return $sp
}

function Send-Payload($sp, [int[]]$payload) {
  $cs = 0
  foreach ($b in $payload) { $cs = (($cs + $b) -band 0xFF) }
  $fr = [byte[]]((@(0xF1, 0xF1) + $payload) + $cs + 0x7E)
  $sp.DiscardInBuffer()
  $sp.Write($fr, 0, $fr.Length)
}

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
    $total = 6 + $len
    if ($i + $total -gt $buf.Count) { break }
    $cs = 0
    for ($k = 2; $k -lt 4 + $len; $k++) { $cs = (($cs + $buf[$i + $k]) -band 0xFF) }
    if ($cs -eq $buf[$i + $total - 2] -and $buf[$i + $total - 1] -eq 0x7E) {
      $prm = @()
      for ($k = 0; $k -lt $len; $k++) { $prm += $buf[$i + 4 + $k] }
      $out += [pscustomobject]@{ Cmd = $buf[$i + 2]; Len = $len; Params = $prm }
      $i += $total
    } else { $i++ }
  }
  return $out
}

# 0x07 returns the whole block: 01(height) 25-28(presets) 21/22(limits)
function Poll-Block($sp) {
  for ($try = 0; $try -lt 8; $try++) {
    Send-Payload $sp @(0x07, 0x00)
    $f = Read-Frames $sp 340
    if ($f.Count -gt 0) { return $f }
    Start-Sleep -Milliseconds 200
  }
  return @()
}

function Get-Height($frames) {
  foreach ($f in $frames) {
    if ($f.Cmd -eq 0x01 -and $f.Len -ge 2) { return [int]$f.Params[0] * 256 + [int]$f.Params[1] }
  }
  return $null
}

function Get-Presets($frames) {
  $m = @{}
  foreach ($f in $frames) {
    $c = [int]$f.Cmd
    if (($c -ge 0x25 -and $c -le 0x28) -and $f.Len -eq 2) {
      $m[$c - 0x25 + 1] = [int]$f.Params[0] * 256 + [int]$f.Params[1]
    }
  }
  return $m
}

function Get-Limits($sp) {
  $r = @{}
  Send-Payload $sp @(0x20, 0x00)
  foreach ($f in (Read-Frames $sp 420)) {
    if ($f.Cmd -eq 0x20 -and $f.Len -ge 1) { $r['flags'] = [int]$f.Params[0] }
    if ($f.Cmd -eq 0x21 -and $f.Len -eq 2) { $r['max'] = [int]$f.Params[0] * 256 + [int]$f.Params[1] }
    if ($f.Cmd -eq 0x22 -and $f.Len -eq 2) { $r['min'] = [int]$f.Params[0] * 256 + [int]$f.Params[1] }
  }
  return $r
}

function Show-State($sp, [string]$label) {
  $f = Poll-Block $sp
  $h = Get-Height $f
  $m = Get-Presets $f
  $lim = Get-Limits $sp
  Write-Host "--- $label ---"
  Write-Host "height   : $h mm"
  Write-Host "soft min : $($lim['min']) mm   soft max : $($lim['max']) mm   flags : 0x$('{0:X2}' -f $lim['flags'])"
  for ($i = 1; $i -le 4; $i++) {
    $v = if ($m.ContainsKey($i)) { "$($m[$i]) mm" } else { 'n/a' }
    Write-Host "preset $i : $v"
  }
  return $m
}

function Get-HeightStable($sp) {
  for ($i = 0; $i -lt 4; $i++) {
    $h = Get-Height (Poll-Block $sp)
    if ($h -ne $null) { return $h }
    Start-Sleep -Milliseconds 400
  }
  return $null
}

# Drive to target height. No polling while moving (0x07 disturbs self-driven motion).
function Move-To($sp, [int]$target, [int]$tol = 3) {
  $h0 = Get-HeightStable $sp
  if ($h0 -eq $null) { throw "cannot read height before move" }
  if ([math]::Abs($h0 - $target) -le $tol) { return $h0 }

  for ($attempt = 1; $attempt -le 2; $attempt++) {
    $d = [math]::Abs($target - $h0)
    $hi = [int][math]::Floor($target / 256)
    $lo = $target -band 0xFF
    Send-Payload $sp @(0x1B, 0x02, $hi, $lo)
    # 35 mm/s nominal; add soft-start/stop margin
    $waitMs = [int]([math]::Min(30000, 1800 + $d / 35.0 * 1000))
    Start-Sleep -Milliseconds $waitMs

    # confirm, allowing the tail of the motion to settle
    $last = $null; $steady = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 6000) {
      Start-Sleep -Milliseconds 350
      $h = Get-Height (Poll-Block $sp)
      if ($h -eq $null) { continue }
      if ($last -ne $null -and [math]::Abs($h - $last) -le 1) { $steady++ } else { $steady = 0 }
      $last = $h
      if ($steady -ge 3) { break }
    }
    if ($last -ne $null -and [math]::Abs($last - $target) -le $tol) { return $last }
    "  move to $target not settled (got $last), retry $attempt"
    if ($last -ne $null) { $h0 = $last }
  }
  return (Get-Height (Poll-Block $sp))
}

$sp = Open-Desk $Port
try {
  [void](Poll-Block $sp)   # warm up: first poll after Open() is always lost

  switch ($Action) {
    'check' {
      Show-State $sp 'current state' | Out-Null
      "planned targets:"
      foreach ($t in $TARGETS) {
        "  preset {0} -> {1} mm   (save CMD 0x{2:X2}, move CMD 0x{3:X2})" -f $t.Index, $t.Height, $t.Save, $t.Move
      }
    }

    'apply' {
      # this box consistently undershoots by ~1 mm because of deceleration,
      # so aim 1 mm high and let the soft limits clamp the endpoints
      $lead = 1
      foreach ($t in $TARGETS) {
        if ($Only -gt 0 -and $t.Index -ne $Only) { continue }
        $goal = [math]::Min($MAX_H, [math]::Max($MIN_H, $t.Height + $lead))
        "=== preset $($t.Index): aiming $goal mm for a true $($t.Height) mm ==="
        $cur = Move-To $sp $goal 2
        if ($cur -eq $null -or [math]::Abs($cur - $t.Height) -gt 3) {
          "  ABORT at preset $($t.Index): reached $cur mm, wanted $($t.Height) mm"
          break
        }
        Start-Sleep -Milliseconds 500
        Send-Payload $sp @($t.Save, 0x00)
        "  sent SAVE 0x{0:X2} at {1} mm" -f $t.Save, $cur
        Start-Sleep -Milliseconds 900
        $m = Get-Presets (Poll-Block $sp)
        $got = if ($m.ContainsKey($t.Index)) { $m[$t.Index] } else { 'n/a' }
        "  readback preset $($t.Index) = $got mm"
      }
      Show-State $sp 'final state' | Out-Null
    }

    'verify' {
      Show-State $sp 'state' | Out-Null
    }

    'test' {
      # exercise MOVE_n. Do NOT poll while moving: 0x07 cancels self-driven motion.
      foreach ($t in ($TARGETS | Sort-Object -Property { $_.Index } -Descending)) {
        $h0 = Get-HeightStable $sp
        $d = [math]::Abs($t.Height - $h0)
        Send-Payload $sp @($t.Move, 0x00)
        $waitMs = [int]([math]::Min(30000, 2000 + $d / 35.0 * 1000))
        Start-Sleep -Milliseconds $waitMs
        $last = $null; $steady = 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 6000) {
          Start-Sleep -Milliseconds 350
          $h = Get-Height (Poll-Block $sp)
          if ($h -eq $null) { continue }
          if ($last -ne $null -and [math]::Abs($h - $last) -le 1) { $steady++ } else { $steady = 0 }
          $last = $h
          if ($steady -ge 3) { break }
        }
        "MOVE_{0} (0x{1:X2}) : {2} -> {3} mm   target {4}   err {5} mm" -f `
          $t.Index, $t.Move, $h0, $last, $t.Height, ($last - $t.Height)
      }
      Show-State $sp 'final state' | Out-Null
    }
  }
}
finally {
  $sp.Close()
}
