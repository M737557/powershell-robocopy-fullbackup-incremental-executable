#Requires -RunAsAdministrator
<#
 fullbackup-vss2.ps1
 Copies source folders from a VSS snapshot (so open/locked files copy consistently).

 Modes:
   Full         Mirror snapshot to F:\Full\<drive>\<path>.
   Incremental  Copy only files whose LastWriteTimeUtc is strictly newer than
                the last backed-up state (per-source manifest), then update
                the manifest. Full is never touched by Incremental.
   Archive      Complete dated copy of the snapshot.

 Usage:  .\fullbackup-vss2.ps1 -Mode Full

 v2.11 changelog:
   - Manifest read/write now supports BOTH plain-text TSV and ROT47-encoded TSV.
     Read-Manifest auto-detects per line:
       1) try ROT47-decode -> parse as TSV; if valid, use it
       2) otherwise parse the raw line as plain TSV
     This means existing v2.9/v2.10 plain-text manifests load correctly, and
     ROT47 manifests keep working. Write-Manifest ALWAYS writes ROT47.
   - A plain-text manifest seen on read is transparently rewritten as ROT47 on
     the next successful run (Write-Manifest always encodes).
   - ROT47 is obfuscation, not encryption. It hides the manifest from a casual
     glance but provides no confidentiality against a determined reader.

 v2.10 changelog:
   - Manifest files stored ROT47-encoded.

 v2.9 changelog:
   - Incremental uses a per-source state manifest (F:\State\<key>\manifest.tsv)
     holding LastWriteTimeUtc and Length of every file. A file is copied ONLY
     if its LastWriteTimeUtc is newer than the manifest value (beyond
     $DiffTolerance). Fixes "same Incremental as last time".
   - Full is no longer modified by Incremental.
   - Older (rollback) and *EXTRA (deleted in source) files are logged.

 v2.7 changelog:
   - EFS-encrypted files skipped are collected and written to
     EFS_skipped_<stamp>.log under F:\Logs.
#>
param(
    [ValidateSet('Full','Incremental','Archive')]
    [string]$Mode = 'Incremental'
)

$ErrorActionPreference = 'Stop'

# ----------------------------- CONFIG ---------------------------------------
$SourceDirs = @(
    "C:\xampp3\htdocs"
    "C:\Users\maev\Desktop"
    "C:\Users\maev\Downloads"
    "C:\scripts"
    "C:\windows10\pri\Mijnbestanden"
)

$DestinationDrive = "F"
$DestinationBase  = "${DestinationDrive}:\"

$FullRoot   = Join-Path $DestinationBase 'Full'
$IncRoot    = Join-Path $DestinationBase 'Incremental'
$ArchRoot   = Join-Path $DestinationBase 'Archive'
$SuperRoot  = Join-Path $DestinationBase 'Superseded'
$LogRoot    = Join-Path $DestinationBase 'Logs'
$StateRoot  = Join-Path $DestinationBase 'State'

$VssLinkRoot = 'C:\vsslinks'
$VssLinkFmt  = Join-Path $VssLinkRoot 'vss_link_{0}'

$ExcludeDirs = @(
    "C:\users\maev\appdata"
)

$EncryptedFiles = 'Skip'

$DiffTolerance = [TimeSpan]::FromSeconds(2)

$SkipReparsePoints = $true
# ----------------------------------------------------------------------------

$Stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'

if (-not (Test-Path $DestinationBase)) { throw "Destination drive $DestinationBase not found." }
foreach ($d in $FullRoot,$IncRoot,$ArchRoot,$SuperRoot,$LogRoot,$StateRoot) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
New-Item -ItemType Directory -Path $VssLinkRoot -Force | Out-Null

Start-Transcript -Path (Join-Path $LogRoot "$Mode`_$Stamp.log") | Out-Null

$script:EfsSkipped = [System.Collections.Generic.List[string]]::new()
$script:OlderFiles = [System.Collections.Generic.List[string]]::new()
$script:ExtraFiles = [System.Collections.Generic.List[string]]::new()

$EncArgs = switch ($EncryptedFiles) {
    'Raw'   { @('/EFSRAW') }
    default { @('/XA:E') }
}

# ---------- helpers ----------
function New-Snapshot([string]$Drive) {
    $res = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create `
           -Arguments @{ Volume = "${Drive}:\"; Context = 'ClientAccessible' }
    if ($res.ReturnValue -ne 0) { throw "VSS create failed for ${Drive}: (code $($res.ReturnValue))" }
    $sc   = Get-CimInstance Win32_ShadowCopy -Filter "ID='$($res.ShadowID)'"
    $link = $VssLinkFmt -f $Drive
    if (Test-Path $link) { cmd /c rmdir "`"$link`"" | Out-Null }
    cmd /c mklink /d "`"$link`"" "`"$($sc.DeviceObject)\`"" | Out-Null
    if (-not (Test-Path $link)) { throw "Could not link snapshot for ${Drive}:" }
    $link = (Get-Item -LiteralPath $link).FullName
    [pscustomobject]@{ Drive = $Drive; Shadow = $sc; Link = $link }
}

function Remove-Snapshot($snap) {
    try { cmd /c rmdir "`"$($snap.Link)`"" | Out-Null } catch {}
    try { $snap.Shadow | Remove-CimInstance } catch { Write-Warning "Could not delete shadow copy: $_" }
}

function Get-SnapExcludes([string]$Drive, [string]$Link) {
    $ExcludeDirs | Where-Object { $_ -like "${Drive}:\*" } |
        ForEach-Object { Join-Path $Link $_.Substring(3) }
}

function Invoke-Robo([string[]]$RoboArgs) {
    & robocopy @RoboArgs
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE)" }
}

function Get-TreeDiff([string]$Src, [string]$Dst, [string[]]$Xd) {
    $Src = (Get-Item -LiteralPath $Src -Force).FullName
    $DstExists = Test-Path -LiteralPath $Dst
    if ($DstExists) { $Dst = (Get-Item -LiteralPath $Dst -Force).FullName }
    else            { $Dst = $Dst.TrimEnd('\') }

    $xdAbs = @($Xd | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })

    function Test-Excluded([string]$FullPath) {
        foreach ($x in $xdAbs) {
            if ($FullPath.Equals($x, 'OrdinalIgnoreCase'))           { return $true }
            if ($FullPath.StartsWith($x + '\', 'OrdinalIgnoreCase')) { return $true }
        }
        return $false
    }

    $srcFiles = @{}
    Get-ChildItem -LiteralPath $Src -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (Test-Excluded $_.FullName) { return }
            if ($EncryptedFiles -eq 'Skip' -and
                ($_.Attributes -band [IO.FileAttributes]::Encrypted)) {
                $script:EfsSkipped.Add($_.FullName) | Out-Null
                return
            }
            $rel = $_.FullName.Substring($Src.Length).TrimStart('\')
            if ($rel) { $srcFiles[$rel] = $_ }
        }

    $dstFiles = @{}
    if ($DstExists) {
        Get-ChildItem -LiteralPath $Dst -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                $rel = $_.FullName.Substring($Dst.Length).TrimStart('\')
                if ($rel) { $dstFiles[$rel] = $_ }
            }
    }

    foreach ($rel in $srcFiles.Keys) {
        $s = $srcFiles[$rel]
        if (-not $dstFiles.ContainsKey($rel)) {
            [pscustomobject]@{ Class = 'New File'; Rel = $rel }
            continue
        }
        $d     = $dstFiles[$rel]
        $delta = $s.LastWriteTimeUtc - $d.LastWriteTimeUtc
        if     ($delta -gt  $DiffTolerance) { [pscustomobject]@{ Class = 'Newer';   Rel = $rel } }
        elseif ($delta -lt -$DiffTolerance) { [pscustomobject]@{ Class = 'Older';   Rel = $rel } }
        elseif ($s.Length -ne $d.Length)    { [pscustomobject]@{ Class = 'Changed'; Rel = $rel } }
    }

    foreach ($rel in $dstFiles.Keys) {
        if (-not $srcFiles.ContainsKey($rel)) {
            [pscustomobject]@{ Class = '*EXTRA File'; Rel = $rel }
        }
    }
}

function Get-DestKey([string]$Src) {
    Join-Path $Src.Substring(0,1).ToUpper() $Src.Substring(3).TrimEnd('\')
}

function Get-PathDiagnosis([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return "  (live path could not be resolved with Get-Item)" }
    $drive = if ($item.PSDrive) { $item.PSDrive.Name } else { '<none>' }
    $root  = if ($item.Root)    { $item.Root }         else { '<none>' }
    @(
        "  FullName   : $($item.FullName)"
        "  Attributes : $($item.Attributes)"
        "  LinkType   : $($item.LinkType)"
        "  Target     : $($item.Target -join ', ')"
        "  PSDrive    : $drive"
        "  Root       : $root"
    ) -join [Environment]::NewLine
}

# ---------- v2.10/v2.11 ROT47 helpers ----------
# ROT47 maps printable ASCII 33..126 onto itself:
#   x -> 33 + ((x - 33 + 47) % 94)
# Applied per character. Characters outside 33..126 (tab, CR, LF, ...) pass
# through unchanged, which is why encoding a whole TSV line keeps the tabs.
function ConvertTo-Rot47([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $sb = [System.Text.StringBuilder]::new($Text.Length)
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int][char]$ch
        if ($c -ge 33 -and $c -le 126) {
            $c = 33 + (($c - 33 + 47) % 94)
            [void]$sb.Append([char]$c)
        } else {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString()
}

# Try to parse one line as "<rel>\t<ticks>\t<length>".
# Returns $null if the line is not a valid manifest line.
function ConvertFrom-ManifestLine([string]$Line) {
    if ([string]::IsNullOrEmpty($Line)) { return $null }
    $parts = $Line -split "`t", 3
    if ($parts.Count -ne 3) { return $null }
    $rel = $parts[0]
    if (-not $rel) { return $null }
    $tick = 0L; $len = 0L
    if (-not [long]::TryParse($parts[1], [ref]$tick)) { return $null }
    if (-not [long]::TryParse($parts[2], [ref]$len))  { return $null }
    [pscustomobject]@{ Rel = $rel; Ticks = $tick; Length = $len }
}

# ---------- v2.9 manifest helpers (v2.11: plain or ROT47 read) ----------
function Get-ManifestPath([string]$Key) {
    Join-Path (Join-Path $StateRoot $Key) 'manifest.tsv'
}

function Read-Manifest([string]$Key) {
    $path = Get-ManifestPath $Key
    $map  = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $map }

    $rotHits   = 0
    $plainHits = 0

    Get-Content -LiteralPath $path -Encoding UTF8 | ForEach-Object {
        if ([string]::IsNullOrEmpty($_)) { return }

        # v2.11: auto-detect.
        # 1) Prefer ROT47 (canonical on-disk form for new files).
        $asRot = ConvertFrom-ManifestLine (ConvertTo-Rot47 $_)
        if ($asRot) {
            $rotHits++
            $map[$asRot.Rel] = [pscustomobject]@{ Ticks = $asRot.Ticks; Length = $asRot.Length }
            return
        }
        # 2) Fall back to plain text (v2.9 manifests, hand-edited files).
        $asPlain = ConvertFrom-ManifestLine $_
        if ($asPlain) {
            $plainHits++
            $map[$asPlain.Rel] = [pscustomobject]@{ Ticks = $asPlain.Ticks; Length = $asPlain.Length }
            return
        }
        Write-Warning "Unparseable manifest line in '$path': $_"
    }

    if ($rotHits -gt 0 -and $plainHits -eq 0) {
        Write-Verbose "Manifest '$path' read as ROT47 ($rotHits lines)."
    }
    elseif ($plainHits -gt 0 -and $rotHits -eq 0) {
        Write-Host "Manifest '$path' read as plain text ($plainHits lines); will be rewritten as ROT47 on this run."
    }
    elseif ($rotHits -gt 0 -and $plainHits -gt 0) {
        Write-Warning "Manifest '$path' is mixed ROT47/plain ($rotHits ROT47, $plainHits plain); will be rewritten as ROT47."
    }

    return $map
}

function Write-Manifest([string]$Key, $Map) {
    $path = Get-ManifestPath $Key
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    $lines = foreach ($rel in ($Map.Keys | Sort-Object)) {
        $e = $Map[$rel]
        $plain = "{0}`t{1}`t{2}" -f $rel, $e.Ticks, $e.Length
        ConvertTo-Rot47 $plain   # always write ROT47
    }
    $lines | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-ChangedSinceManifest($SnapshotFiles, $Manifest, [TimeSpan]$Tolerance) {
    $tolTicks = $Tolerance.Ticks
    foreach ($rel in $SnapshotFiles.Keys) {
        $s = $SnapshotFiles[$rel]
        if (-not $Manifest.ContainsKey($rel)) {
            [pscustomobject]@{ Class = 'New File'; Rel = $rel; Item = $s }
            continue
        }
        $m = $Manifest[$rel]
        $deltaTicks = $s.LastWriteTimeUtc.Ticks - $m.Ticks
        if ($deltaTicks -gt $tolTicks) {
            [pscustomobject]@{ Class = 'Newer'; Rel = $rel; Item = $s }
        }
    }
}

function Get-SnapshotFiles([string]$Src, [string[]]$Xd) {
    $Src = (Get-Item -LiteralPath $Src -Force).FullName
    $xdAbs = @($Xd | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })

    function Test-Excluded([string]$FullPath) {
        foreach ($x in $xdAbs) {
            if ($FullPath.Equals($x, 'OrdinalIgnoreCase'))           { return $true }
            if ($FullPath.StartsWith($x + '\', 'OrdinalIgnoreCase')) { return $true }
        }
        return $false
    }

    $files = @{}
    Get-ChildItem -LiteralPath $Src -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (Test-Excluded $_.FullName) { return }
            if ($EncryptedFiles -eq 'Skip' -and
                ($_.Attributes -band [IO.FileAttributes]::Encrypted)) {
                $script:EfsSkipped.Add($_.FullName) | Out-Null
                return
            }
            $rel = $_.FullName.Substring($Src.Length).TrimStart('\')
            if ($rel) { $files[$rel] = $_ }
        }
    return $files
}

# ---------- main ----------
$snaps  = @{}
$failed = @()
try {
    if ($Mode -eq 'Incremental') {
        $missing = $SourceDirs | Where-Object {
            (Test-Path $_) -and -not (Test-Path (Join-Path $FullRoot (Get-DestKey $_)))
        }
        if ($missing) {
            Write-Warning "No Full backup for: $($missing -join ', '). Switching to Full mode."
            $Mode = 'Full'
        }
    }

    $drives = $SourceDirs | Where-Object { Test-Path $_ } |
              ForEach-Object { $_.Substring(0,1).ToUpper() } | Sort-Object -Unique
    foreach ($d in $drives) {
        Write-Host "Creating snapshot of ${d}: ..."
        $snaps[$d] = New-Snapshot $d
    }

    foreach ($src in $SourceDirs) {
        if (-not (Test-Path $src)) { Write-Warning "Skipping missing source: $src"; continue }

        try {
            $liveItem = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
            if (-not $liveItem) {
                throw "Live path cannot be resolved with Get-Item: $src"
            }
            $isReparse = [bool]($liveItem.Attributes -band [IO.FileAttributes]::ReparsePoint)
            if ($isReparse -and $SkipReparsePoints) {
                Write-Warning ("SKIP (reparse point): $src" + [Environment]::NewLine +
                    (Get-PathDiagnosis $src) + [Environment]::NewLine +
                    "  If the Target lives on another drive, replace the entry in " +
                    "`$SourceDirs with that target path and re-run; the script will " +
                    "snapshot the target drive automatically.")
                continue
            }

            $drive   = $src.Substring(0,1).ToUpper()
            $snap    = $snaps[$drive]
            $rel     = $src.Substring(3).TrimEnd('\')
            $key     = Get-DestKey $src
            $snapSrc = Join-Path $snap.Link $rel
            $xd      = @(Get-SnapExcludes $drive $snap.Link)

            try {
                $null = Get-Item -LiteralPath $snapSrc -Force -ErrorAction Stop
            }
            catch {
                throw ("Snapshot path not resolvable: '$snapSrc'" +
                    [Environment]::NewLine + "Live source:" + [Environment]::NewLine +
                    (Get-PathDiagnosis $src) + [Environment]::NewLine +
                    "This almost always means the source is a reparse point whose " +
                    "target lives on a volume that is NOT in the snapshot set " +
                    "(snapshots currently: $($snaps.Keys -join ', ')).")
            }

            Write-Host "`n=== $Mode : $src ==="

            switch ($Mode) {

                'Full' {
                    $dst = Join-Path $FullRoot $key
                    New-Item -ItemType Directory -Path $dst -Force | Out-Null

                    $supBase = Join-Path (Join-Path $SuperRoot $Stamp) $key
                    try {
                        $diff = @(Get-TreeDiff $snapSrc $dst $xd |
                                Where-Object { $_.Class -in '*EXTRA File','Newer','Older','Changed' })
                    }
                    catch {
                        throw "Get-TreeDiff failed for '$snapSrc' -> '$dst': $($_.Exception.Message)"
                    }
                    foreach ($f in $diff) {
                        $from = Join-Path $dst     $f.Rel
                        $to   = Join-Path $supBase $f.Rel
                        if (Test-Path -LiteralPath $from) {
                            New-Item -ItemType Directory -Path (Split-Path $to) -Force | Out-Null
                            Move-Item -LiteralPath $from -Destination $to -Force
                        }
                    }
                    Write-Host "Superseded files moved: $($diff.Count)"

                    $a = @($snapSrc,$dst,'/MIR','/COPY:DAT','/DCOPY:T','/FFT','/XJ','/R:1','/W:1','/NP','/NDL') + $EncArgs
                    if ($xd) { $a += '/XD'; $a += $xd }
                    Invoke-Robo $a

                    # Seed/refresh the manifest from the resulting Full tree.
                    $manifest  = @{}
                    $fullFiles = Get-SnapshotFiles $dst @()
                    foreach ($r in $fullFiles.Keys) {
                        $f = $fullFiles[$r]
                        $manifest[$r] = [pscustomobject]@{
                            Ticks  = $f.LastWriteTimeUtc.Ticks
                            Length = $f.Length
                        }
                    }
                    Write-Manifest $key $manifest
                    Write-Host "Manifest seeded: $($manifest.Count) files"
                }

                'Incremental' {
                    $dst = Join-Path (Join-Path $IncRoot $Stamp) $key

                    $snapshotFiles = Get-SnapshotFiles $snapSrc $xd
                    $manifest      = Read-Manifest $key

                    Write-Host "Manifest entries: $($manifest.Count); snapshot files: $($snapshotFiles.Count)"

                    if ($manifest.Count -eq 0) {
                        Write-Warning ("No manifest for $key; falling back to Full diff " +
                                       "(this run may copy more than usual).")
                        $full = Join-Path $FullRoot $key
                        $diff = @(Get-TreeDiff $snapSrc $full $xd |
                                  Where-Object { $_.Class -in 'New File','Newer' })
                        $changed = @($diff | ForEach-Object {
                            [pscustomobject]@{ Class = $_.Class; Rel = $_.Rel; Item = $snapshotFiles[$_.Rel] }
                        } | Where-Object { $_.Item })
                    }
                    else {
                        $changed = @(Get-ChangedSinceManifest $snapshotFiles $manifest $DiffTolerance)
                    }

                    foreach ($r in $snapshotFiles.Keys) {
                        if ($manifest.ContainsKey($r)) {
                            $deltaTicks = $snapshotFiles[$r].LastWriteTimeUtc.Ticks - $manifest[$r].Ticks
                            if ($deltaTicks -lt (-$DiffTolerance.Ticks)) {
                                $script:OlderFiles.Add("$key`t$r") | Out-Null
                            }
                        }
                    }
                    foreach ($r in $manifest.Keys) {
                        if (-not $snapshotFiles.ContainsKey($r)) {
                            $script:ExtraFiles.Add("$key`t$r") | Out-Null
                        }
                    }

                    Write-Host "Files to copy (newer than last backup): $($changed.Count)"

                    foreach ($f in $changed) {
                        $from = Join-Path $snapSrc $f.Rel
                        $to   = Join-Path $dst     $f.Rel
                        if (-not (Test-Path -LiteralPath $from)) {
                            Write-Warning "Diff entry no longer present, skipping: $from"
                            continue
                        }
                        New-Item -ItemType Directory -Path (Split-Path $to) -Force | Out-Null
                        Copy-Item -LiteralPath $from -Destination $to -Force

                        $copied = Get-Item -LiteralPath $from -Force
                        $manifest[$f.Rel] = [pscustomobject]@{
                            Ticks  = $copied.LastWriteTimeUtc.Ticks
                            Length = $copied.Length
                        }
                    }

                    foreach ($r in @($manifest.Keys)) {
                        if (-not $snapshotFiles.ContainsKey($r)) {
                            $manifest.Remove($r)
                        }
                    }

                    Write-Manifest $key $manifest
                }

                'Archive' {
                    $dst = Join-Path (Join-Path $ArchRoot $Stamp) $key
                    New-Item -ItemType Directory -Path $dst -Force | Out-Null
                    $a = @($snapSrc,$dst,'/E','/COPY:DAT','/DCOPY:T','/FFT','/XJ','/R:1','/W:1','/NP','/NDL') + $EncArgs
                    if ($xd) { $a += '/XD'; $a += $xd }
                    Invoke-Robo $a
                }
            }
        }
        catch {
            Write-Warning "FAILED, skipping ${src}: $($_.Exception.Message)"
            $failed += $src
        }
    }

    if ($failed) { Write-Warning "Sources that failed: $($failed -join ', ')" }
    Write-Host "`nDone: $Mode ($Stamp)"
}
finally {
    if ($script:EfsSkipped.Count -gt 0) {
        $efsLog = Join-Path $LogRoot "EFS_skipped_$Stamp.log"
        try {
            $script:EfsSkipped | Set-Content -LiteralPath $efsLog -Encoding UTF8
            Write-Warning ("EFS files skipped: $($script:EfsSkipped.Count) (see $efsLog)")
        }
        catch {
            Write-Warning "Could not write EFS skip log: $($_.Exception.Message)"
        }
    }

    if ($script:OlderFiles.Count -gt 0) {
        $log = Join-Path $LogRoot "Older_$Stamp.log"
        try {
            $script:OlderFiles | Set-Content -LiteralPath $log -Encoding UTF8
            Write-Warning ("Files OLDER than last backup (possible rollback), " +
                           "not copied: $($script:OlderFiles.Count) (see $log)")
        }
        catch {
            Write-Warning "Could not write Older log: $($_.Exception.Message)"
        }
    }
    if ($script:ExtraFiles.Count -gt 0) {
        $log = Join-Path $LogRoot "Extra_$Stamp.log"
        try {
            $script:ExtraFiles | Set-Content -LiteralPath $log -Encoding UTF8
            Write-Host ("Files removed since last backup (deleted or renamed): " +
                        "$($script:ExtraFiles.Count) (see $log)")
        }
        catch {
            Write-Warning "Could not write Extra log: $($_.Exception.Message)"
        }
    }

    foreach ($s in $snaps.Values) { Remove-Snapshot $s }
    Stop-Transcript | Out-Null
}

if ($failed) { exit 1 }