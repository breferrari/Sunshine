<#
.SYNOPSIS
    Builds the fork's Windows installer on this PC, like the "Fork Windows Build" workflow does.

.DESCRIPTION
    Needs MSYS2 in C:\msys64 with the UCRT64 packages that .github/workflows/ci-windows.yml installs, Node.js and
    the .NET SDK (WiX is fetched into the build folder). The first build takes a while; later ones recompile only
    what changed. Writes dist\Sunshine-Windows-AMD64-installer.msi. With -Install, installs it right away.

    MSYS2 runs with its own PATH plus Node.js only: anything else from the Windows PATH (a Visual Studio Qt, for
    example) could be picked up by CMake instead of the MSYS2 packages.
#>
param(
    [switch]$Install,     # install the result with install.ps1 (asks for elevation)
    [switch]$Reconfigure  # run the CMake configure step again
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$bash = 'C:\msys64\usr\bin\bash.exe'
if (-not (Test-Path $bash)) { throw 'MSYS2 not found in C:\msys64' }

function Invoke-Msys([string]$command) {
    $env:MSYSTEM = 'UCRT64'
    $env:CHERE_INVOKING = '1'
    Remove-Item Env:MSYS2_PATH_TYPE -ErrorAction SilentlyContinue
    Push-Location $root
    try {
        & $bash -lc "export PATH=`"`$PATH:/c/Program Files/nodejs`"; $command"
        if ($LASTEXITCODE -ne 0) { throw "Failed ($LASTEXITCODE): $command" }
    } finally { Pop-Location }
}

$sw = [Diagnostics.Stopwatch]::StartNew()

# Version like the CI build: the upstream release the branch is based on, plus branch and commit. CMake reads them
# at configure time, so configure again whenever the commit changed.
$commit = (git -C $root rev-parse HEAD).Trim()
$env:BUILD_VERSION = (git -C $root describe --tags --abbrev=0 --match 'v*').Trim().TrimStart('v')
$env:BRANCH = (git -C $root rev-parse --abbrev-ref HEAD).Trim()
$env:COMMIT = $commit
$configured_commit = Join-Path $root 'build\fork-configured-commit.txt'
$stale = -not (Test-Path $configured_commit) -or (Get-Content $configured_commit -Raw).Trim() -ne $commit

if ($Reconfigure -or $stale -or -not (Test-Path (Join-Path $root 'build\CMakeCache.txt'))) {
    Write-Host 'Configuring'
    Invoke-Msys ('cmake -B build -G Ninja -S . -DBUILD_WERROR=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo ' +
        '-DSUNSHINE_ASSETS_DIR=assets -DSUNSHINE_PUBLISHER_NAME=breferrari ' +
        '-DSUNSHINE_PUBLISHER_WEBSITE=https://app.lizardbyte.dev ' +
        '-DSUNSHINE_PUBLISHER_ISSUE_URL=https://app.lizardbyte.dev/support -DBUILD_DOCS=OFF')
    Set-Content $configured_commit $commit
}
Write-Host 'Building'
Invoke-Msys 'ninja -C build'
Write-Host 'Packaging'
Invoke-Msys 'cd build && cpack -G WIX'

$msi = Join-Path $root 'build\cpack_artifacts\Sunshine.msi'
$dist = New-Item -ItemType Directory -Force (Join-Path $root 'dist')
$target = Join-Path $dist 'Sunshine-Windows-AMD64-installer.msi'
Copy-Item $msi $target -Force
Write-Host ("Installer: $target ({0:N1} min)" -f $sw.Elapsed.TotalMinutes)

if ($Install) {
    $log = Join-Path $dist 'install-out.txt'
    Start-Process pwsh -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"& '$PSScriptRoot\install.ps1' -Msi '$target' *> '$log'`""
    Get-Content $log
}
