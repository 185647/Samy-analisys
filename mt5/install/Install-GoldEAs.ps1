# Install-GoldEAs.ps1
# Copies the Gold EAs into every MetaTrader 5 data folder on this PC and compiles them.
# Run via Install.bat (double-click). Open MetaTrader 5 at least once before running.

$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot '..\Experts'
$eas = Get-ChildItem -Path $src -Filter *.mq5
if (-not $eas) { Write-Host "No .mq5 files found in $src"; exit 1 }

$root = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
if (-not (Test-Path $root)) {
    Write-Host "MetaTrader 5 data folder not found. Open MetaTrader 5 once, close it, and run this again."
    exit 1
}

$found = $false
foreach ($term in Get-ChildItem $root -Directory) {
    $mql    = Join-Path $term.FullName 'MQL5'
    $origin = Join-Path $term.FullName 'origin.txt'
    if (-not (Test-Path $mql) -or -not (Test-Path $origin)) { continue }

    $install = (Get-Content $origin -Raw).Trim()
    $editor  = Join-Path $install 'metaeditor64.exe'
    if (-not (Test-Path $editor)) {
        Write-Host "Skip $($term.Name): MetaEditor not found in $install"
        continue
    }
    $found = $true
    Write-Host ""
    Write-Host "== MetaTrader 5: $install"

    $dest = Join-Path $mql 'Experts\Samy'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    foreach ($ea in $eas) {
        $target = Join-Path $dest $ea.Name
        $ex5    = [IO.Path]::ChangeExtension($target, '.ex5')
        $log    = [IO.Path]::ChangeExtension($target, '.log')
        Copy-Item $ea.FullName $target -Force
        if (Test-Path $ex5) { Remove-Item $ex5 -Force }
        if (Test-Path $log) { Remove-Item $log -Force }

        Start-Process -FilePath $editor -ArgumentList "/compile:`"$target`"", "/log:`"$log`"" -Wait -WindowStyle Hidden

        if (Test-Path $ex5) { Write-Host "  OK    $($ea.Name)" -ForegroundColor Green }
        else                { Write-Host "  FAIL  $($ea.Name)  (log: $log)" -ForegroundColor Red }

        if (Test-Path $log) {
            Get-Content $log | Where-Object { $_ -match 'error|warning|result' } |
                Select-Object -Last 20 | ForEach-Object { Write-Host "        $_" }
        }
    }
}

if (-not $found) {
    Write-Host "No MetaTrader 5 installation found. Install MT5 from your broker and open it once."
} else {
    Write-Host ""
    Write-Host "Done. In MetaTrader 5: Navigator > Expert Advisors > Samy (right-click > Refresh if not visible)."
}
