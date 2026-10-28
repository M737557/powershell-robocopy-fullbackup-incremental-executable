$Pairs = @(
    @{ Source = "C:\xampp3\htdocs";                Dest = "F:\Full\C\xampp3\htdocs" }
    @{ Source = "C:\Users\maev\Desktop";           Dest = "F:\Full\C\Users\maev\Desktop" }
    @{ Source = "C:\Users\maev\Downloads";         Dest = "F:\Full\C\Users\maev\Downloads" }
    @{ Source = "C:\scripts";                      Dest = "F:\Full\C\scripts" }
    @{ Source = "C:\windows10\pri\Mijnbestanden";  Dest = "F:\Full\C\windows10\pri\Mijnbestanden" }
)

$LogDir = "F:\logs"
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

$allDiffs = @()
$rows     = @()

foreach ($pair in $Pairs) {
    $src = $pair.Source
    $dst = $pair.Dest

    $srcMap = @{}
    if (Test-Path $src) {
        Get-ChildItem -Path $src -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $srcMap[$_.FullName.Substring($src.Length).TrimStart('\')] = $_.Length
        }
    }

    $dstMap = @{}
    if (Test-Path $dst) {
        Get-ChildItem -Path $dst -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $dstMap[$_.FullName.Substring($dst.Length).TrimStart('\')] = $_.Length
        }
    }

    $missing = @($srcMap.Keys | Where-Object { -not $dstMap.ContainsKey($_) })
    $extra   = @($dstMap.Keys | Where-Object { -not $srcMap.ContainsKey($_) })
    $sizeDif = @($srcMap.Keys | Where-Object {
        $dstMap.ContainsKey($_) -and $srcMap[$_] -ne $dstMap[$_]
    })

    $rows += [PSCustomObject]@{
        Source      = $src
        Dest        = $dst
        SrcCount    = $srcMap.Count
        DestCount   = $dstMap.Count
        Missing     = $missing.Count
        Extra       = $extra.Count
        SizeDiff    = $sizeDif.Count
        Status      = if (($missing.Count + $extra.Count + $sizeDif.Count) -eq 0) { "OK" } else { "DIFF" }
    }

    foreach ($f in $missing) {
        $allDiffs += [PSCustomObject]@{ Source = $src; File = $f; Issue = "Missing in dest"; SrcSize = $srcMap[$f]; DestSize = $null }
    }
    foreach ($f in $extra) {
        $allDiffs += [PSCustomObject]@{ Source = $src; File = $f; Issue = "Extra in dest";   SrcSize = $null; DestSize = $dstMap[$f] }
    }
    foreach ($f in $sizeDif) {
        $allDiffs += [PSCustomObject]@{ Source = $src; File = $f; Issue = "Size differs";    SrcSize = $srcMap[$f]; DestSize = $dstMap[$f] }
    }
}

# ---------- Summary ----------
Write-Host ""
Write-Host "========== SUMMARY ==========" -ForegroundColor Cyan
$rows | Format-Table Source, SrcCount, DestCount, Missing, Extra, SizeDiff, Status -AutoSize

$totSrc     = ($rows | Measure-Object SrcCount  -Sum).Sum
$totDst     = ($rows | Measure-Object DestCount -Sum).Sum
$totMissing = ($rows | Measure-Object Missing   -Sum).Sum
$totExtra   = ($rows | Measure-Object Extra     -Sum).Sum
$totSize    = ($rows | Measure-Object SizeDiff  -Sum).Sum

Write-Host ""
Write-Host ("Total source files     : {0}" -f $totSrc)
Write-Host ("Total dest files       : {0}" -f $totDst)
Write-Host ("Missing in dest        : {0}" -f $totMissing) -ForegroundColor $(if ($totMissing -gt 0) { 'Red' } else { 'Green' })
Write-Host ("Extra in dest          : {0}" -f $totExtra)   -ForegroundColor $(if ($totExtra   -gt 0) { 'Red' } else { 'Green' })
Write-Host ("Size differs           : {0}" -f $totSize)    -ForegroundColor $(if ($totSize    -gt 0) { 'Red' } else { 'Green' })

if ($allDiffs.Count -gt 0) {
    $csv = Join-Path $LogDir "diff-log.csv"
    $allDiffs | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host ("Full per-file diff written to: {0}" -f $csv) -ForegroundColor Cyan
} else {
    Write-Host ""
    Write-Host "All sources and destinations match." -ForegroundColor Green
}