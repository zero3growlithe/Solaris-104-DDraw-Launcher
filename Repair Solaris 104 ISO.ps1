param([string]$SourcePath)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($SourcePath)) { Write-Host '[X] no file given'; exit 1 }
if (-not (Test-Path -LiteralPath $SourcePath)) { Write-Host ('[X] file not found: ' + $SourcePath); exit 1 }

$sectorSize = 2048
$in = [System.IO.File]::Open($SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
$total = $in.Length
Write-Host ('input size=' + $total + '  sectors=' + [math]::Floor($total / $sectorSize) + '  mod2048=' + ($total % $sectorSize))

function Read-Exact([System.IO.Stream]$stream, [long]$pos, [int]$len) {
    $stream.Position = $pos
    $buf = New-Object byte[] $len
    $got = 0
    while ($got -lt $len) {
        $r = $stream.Read($buf, $got, $len - $got)
        if ($r -le 0) { break }
        $got = $got + $r
    }
    if ($got -ne $len) { return $null }
    return ,$buf
}

# ---- find volume descriptors (sectors 16..47) ----
$descSectors = @()   # parallel: sector numbers of PVD/SVD
for ($s = 16; $s -lt 48; $s++) {
    $d = Read-Exact $in ([int64]$s * $sectorSize) $sectorSize
    if ($null -eq $d) { break }
    $marker = [System.Text.Encoding]::ASCII.GetString($d, 1, 5)
    if ($marker -ne 'CD001') { continue }
    $type = $d[0]
    if ($type -eq 1) {
        $lba = [System.BitConverter]::ToInt32($d, 158)
        Write-Host ('descriptor sector ' + $s + ': ISO9660 PVD, root LBA=' + $lba)
        $descSectors += $s
    } elseif ($type -eq 2) {
        $esc = [System.Text.Encoding]::ASCII.GetString($d, 88, 3)
        if ($esc -like '%/*') {
            $lba = [System.BitConverter]::ToInt32($d, 158)
            Write-Host ('descriptor sector ' + $s + ': Joliet SVD, root LBA=' + $lba)
            $descSectors += $s
        }
    } elseif ($type -eq 255) { break }
}
if ($descSectors.Count -eq 0) { Write-Host '[X] no usable volume descriptors'; $in.Close(); exit 2 }

# ---- patch tracking as PARALLEL arrays (avoid PowerShell nested-array mutation pitfalls) ----
$pRec = @()   # record index
$pRoot = @()  # root dir LBA of the tree
$pOff = @()   # record byte offset within dir sector(s)
$pLba = @()   # file extent LBA
$pName = @()  # display name
$pEst = @()   # estimated size (0 = not fixed)
$nRec = 0
$treeAllLbas = @()

foreach ($ds in $descSectors) {
    $d = Read-Exact $in ([int64]$ds * $sectorSize) $sectorSize
    $rootLba = [System.BitConverter]::ToInt32($d, 158)
    $isJoliet = ($d[0] -eq 2)
    $dirBytes = Read-Exact $in ([int64]$rootLba * $sectorSize) 2048
    if ($null -eq $dirBytes) { Write-Host ('[X] cannot read dir at LBA ' + $rootLba); $in.Close(); exit 3 }
    Write-Host ('scanning tree @LBA ' + $rootLba + ' (joliet=' + $isJoliet + ')')
    $off = 0
    while ($off -lt $dirBytes.Length) {
        $rl = [int]$dirBytes[$off]
        if ($rl -eq 0) { $off = (([math]::Floor($off / 2048)) + 1) * 2048; continue }
        if ($rl -lt 34) { $off += $rl; continue }
        $lba = [System.BitConverter]::ToInt32($dirBytes, $off + 2)
        $size = [System.BitConverter]::ToInt32($dirBytes, $off + 10)
        $nlen = [int]$dirBytes[$off + 32]
        $name = ''
        if ($nlen -gt 0) {
            if ($isJoliet) {
                $pairs = [math]::Floor($nlen / 2)
                $u = New-Object byte[] $pairs
                for ($k = 0; $k -lt $pairs; $k++) {
                    $b = $dirBytes[$off + 33 + ($k * 2)]
                    if ($b -gt 32 -and $b -lt 127) { $u[$k] = $b }
                }
                $name = [System.Text.Encoding]::ASCII.GetString($u).TrimEnd([char]0)
            } else {
                $name = [System.Text.Encoding]::ASCII.GetString($dirBytes, $off + 33, $nlen)
            }
        }
        Write-Host ('  rec[' + $nRec + '] ' + $name + '  lba=' + $lba + '  size=' + $size)
        if ($name.Length -gt 0 -and $name[0] -ne '.') { $treeAllLbas += $lba }
        if ($size -eq 2147483647) {
            $pRec += $nRec; $pRoot += $rootLba; $pOff += $off; $pLba += $lba; $pName += $name; $pEst += 0
        }
        $nRec++
        $off += $rl
    }
}

$sortedLbas = $treeAllLbas | Sort-Object -Unique
$fixedCount = 0
for ($i = 0; $i -lt $pRec.Count; $i++) {
    $next = $null
    foreach ($cand in $sortedLbas) { if ($cand -gt $pLba[$i]) { $next = $cand; break } }
    if ($null -eq $next) {
        Write-Host ('  UNFIXED ' + $pName[$i] + ': no next lba found')
        continue
    }
    $est = ($next - $pLba[$i]) * $sectorSize
    $pEst[$i] = $est
    $fixedCount++
    Write-Host ('  FIXED ' + $pName[$i] + ' (tree@' + $pRoot[$i] + '): 0x7FFFFFFF -> ' + $est + ' (next lba=' + $next + ')')
}

# ---- write patched image ----
$dir = [System.IO.Path]::GetDirectoryName($SourcePath)
$base = [System.IO.Path]::GetFileNameWithoutExtension($SourcePath)
$outPath = [System.IO.Path]::Combine($dir, $base + '_fixed3.iso')
Write-Host ('writing: ' + $outPath)
$out = [System.IO.File]::Create($outPath)
$in.Position = 0
$copyBuf = New-Object byte[] 1048576
$left = $total
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($left -gt 0) {
    $chunk = $left
    if ($chunk -gt $copyBuf.Length) { $chunk = $copyBuf.Length }
    $r = $in.Read($copyBuf, 0, [int]$chunk)
    if ($r -le 0) { break }
    $out.Write($copyBuf, 0, $r)
    $left = $left - $r
}
Write-Host ('  base copy: ' + [math]::Floor($total / 1048576) + ' MB in ' + [math]::Floor($sw.Elapsed.TotalSeconds) + ' s')

# volume-space patch on every PVD/SVD
$volSpaceNew = [int][math]::Ceiling($total / $sectorSize)
foreach ($ds in $descSectors) {
    $d = Read-Exact $in ([int64]$ds * $sectorSize) $sectorSize
    $vsLE = [System.BitConverter]::GetBytes($volSpaceNew)
    $d[80] = $vsLE[0]; $d[81] = $vsLE[1]; $d[82] = $vsLE[2]; $d[83] = $vsLE[3]
    $d[84] = $vsLE[3]; $d[85] = $vsLE[2]; $d[86] = $vsLE[1]; $d[87] = $vsLE[0]
    $out.Position = [int64]$ds * $sectorSize
    $out.Write($d, 0, $d.Length)
    Write-Host ('  volume-space patched @sector ' + $ds + ' -> ' + $volSpaceNew)
}

# dir record size patch: LE at +10, BE copy at +14
for ($i = 0; $i -lt $pRec.Count; $i++) {
    if ($pEst[$i] -eq 0) { continue }
    $absBase = ([int64]$pRoot[$i] * $sectorSize) + $pOff[$i]
    $sizeLE = [System.BitConverter]::GetBytes([int]$pEst[$i])
    $be = New-Object byte[] 4
    $be[0] = $sizeLE[3]; $be[1] = $sizeLE[2]; $be[2] = $sizeLE[1]; $be[3] = $sizeLE[0]
    $out.Position = $absBase + 10
    $out.Write($sizeLE, 0, 4)
    $out.Position = $absBase + 14
    $out.Write($be, 0, 4)
    Write-Host ('  record patched @LBA ' + $pRoot[$i] + ' off ' + $pOff[$i] + ' (' + $pName[$i] + ') -> ' + $pEst[$i])
}

# ---- verify: read back patched bytes AND the first bytes of each fixed file extent ----
$outFileStream = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
$chk = New-Object byte[] 8
$outFileStream.Position = 32768 + 80
$outFileStream.Read($chk, 0, 8) | Out-Null
Write-Host ('verify PVD vol-space bytes: ' + [System.BitConverter]::ToString($chk))
for ($i = 0; $i -lt $pRec.Count; $i++) {
    if ($pEst[$i] -eq 0) { continue }
    $absBase = ([int64]$pRoot[$i] * $sectorSize) + $pOff[$i]
    $chk2 = New-Object byte[] 8
    $outFileStream.Position = $absBase + 10
    $outFileStream.Read($chk2, 0, 8) | Out-Null
    Write-Host ('verify record ' + $pName[$i] + ' size bytes: ' + [System.BitConverter]::ToString($chk2))
    $head = New-Object byte[] 16
    $outFileStream.Position = [int64]$pLba[$i] * $sectorSize
    $outFileStream.Read($head, 0, 16) | Out-Null
    Write-Host ('  extent head ' + $pName[$i] + ': ' + [System.BitConverter]::ToString($head))
    if ($head[0] -eq 0x4D -and $head[1] -eq 0x5A) { Write-Host '    -> MZ header OK (Windows EXE)' }
}
$outFileStream.Close()

$out.Close()
$in.Close()
$fs = Get-Item -LiteralPath $outPath
Write-Host ('output size=' + $fs.Length + ' (must equal ' + $total + ')')
if ($fs.Length -eq $total) {
    Write-Host ('RESULT=OK, records fixed=' + $fixedCount + ' -> ' + $outPath)
} else {
    Write-Host 'RESULT=SIZE-MISMATCH'
}
