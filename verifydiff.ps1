$Pairs = @(
    @{ Source = "C:\xampp3\htdocs";                Dest = "F:\Full\C\xampp3\htdocs" }
    @{ Source = "C:\Users\maev\Desktop";           Dest = "F:\Full\C\Users\maev\Desktop" }
    @{ Source = "C:\Users\maev\Downloads";         Dest = "F:\Full\C\Users\maev\Downloads" }
    @{ Source = "C:\scripts";                      Dest = "F:\Full\C\scripts" }
    @{ Source = "C:\windows10\pri\Mijnbestanden";  Dest = "F:\Full\C\windows10\pri\Mijnbestanden" }
)

$allDiffs = @()

foreach ($pair in $Pairs) {
    $src = $pair.Source
    $dst = $pair.Dest

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "Source: $src"
    Write-Host "Dest  : $dst"
    Write-Host "==============================================" -ForegroundColor Cyan

    if (-not (Test-Path $src)) {
        Write-Host "  Source missing" -ForegroundColor Yellow
        continue
    }
    if (-not (Test-Path $dst)) {
        Write-Host "  Destination missing" -ForegroundColor Yellow
        continue
    }

    # Build relative-path -> size maps
    $srcMap = @{}
    Get-ChildItem -Path $src -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($src.Length).TrimStart('\')
        $srcMap[$rel] = $_.Length
    }

    $dstMap = @{}
    Get-ChildItem -Path $dst -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($dst.Length).TrimStart('\')
        $dstMap[$rel] = $_.Length
    }

    Write-Host ("  Source files: {0}" -f $srcMap.Count)
    Write-Host ("  Dest files  : {0}" -f $dstMap.Count)

    # Missing in destination (in source, not in dest)
    $missingInDest = $srcMap.Keys | Where-Object { -not $dstMap.ContainsKey($_) } | Sort-Object

    # Extra in destination (in dest, not in source)
    $extraInDest = $dstMap.Keys | Where-Object { -not $srcMap.ContainsKey($_) } | Sort-Object

    # Size mismatch (present in both, different length)
    $sizeDiff = $srcMap.Keys | Where-Object {
        $dstMap.ContainsKey($_) -and $srcMap[$_] -ne $dstMap[$_]
    } | Sort-Object

    if ($missingInDest.Count -eq 0 -and $extraInDest.Count -eq 0 -and $sizeDiff.Count -eq 0) {
        Write-Host "  All files match (by name and size)" -ForegroundColor Green
        continue
    }

    if ($missingInDest) {
        Write-Host ""
        Write-Host ("  [MISSING IN DEST] {0} file(s)" -f $missingInDest.Count) -ForegroundColor Red
        foreach ($f in $missingInDest) {
            Write-Host ("    {0}  ({1} bytes)" -f $f, $srcMap[$f])
            $allDiffs += [PSCustomObject]@{
                Source = $src; File = $f; Issue = "Missing in dest"
                SrcSize = $srcMap[$f]; DestSize = $null
            }
        }
    }

    if ($extraInDest) {
        Write-Host ""
        Write-Host ("  [EXTRA IN DEST] {0} file(s)" -f $extraInDest.Count) -ForegroundColor Magenta
        foreach ($f in $extraInDest) {
            Write-Host ("    {0}  ({1} bytes)" -f $f, $dstMap[$f])
            $allDiffs += [PSCustomObject]@{
                Source = $src; File = $f; Issue = "Extra in dest"
                SrcSize = $null; DestSize = $dstMap[$f]
            }
        }
    }

    if ($sizeDiff) {
        Write-Host ""
        Write-Host ("  [SIZE DIFFERS] {0} file(s)" -f $sizeDiff.Count) -ForegroundColor Yellow
        foreach ($f in $sizeDiff) {
            Write-Host ("    {0}  (src={1}  dst={2})" -f $f, $srcMap[$f], $dstMap[$f])
            $allDiffs += [PSCustomObject]@{
                Source = $src; File = $f; Issue = "Size differs"
                SrcSize = $srcMap[$f]; DestSize = $dstMap[$f]
            }
        }
    }
}

# ---------- Summary ----------
Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " SUMMARY" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

if ($allDiffs.Count -eq 0) {
    Write-Host "All sources and destinations match." -ForegroundColor Green
} else {
    Write-Host ("Total differences: {0}" -f $allDiffs.Count) -ForegroundColor Red

    $byType = $allDiffs | Group-Object Issue | Sort-Object Name
    foreach ($g in $byType) {
        Write-Host ("  {0}: {1}" -f $g.Name, $g.Count)
    }

 
}