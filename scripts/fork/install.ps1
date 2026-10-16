# Installs the Sunshine fork over the installed Sunshine, keeping the configuration, and sets stream_notify_cmd. Run elevated.
param([string]$Msi = (Join-Path $PSScriptRoot '..\..\dist\Sunshine-Windows-AMD64-installer.msi'))
$ErrorActionPreference = 'Stop'
$config  = 'C:\Program Files\Sunshine\config'
$backup  = "C:\ProgramData\SunshineBackup\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$log     = Join-Path $PSScriptRoot '..\..\dist\sunshine-msi.log'
$lgtv    = '"C:\Program Files\LGTV Companion\LGTV Companion.exe"'
$notify  = "stream_notify_cmd = $lgtv -streaming_event"

# everything but the logs: settings, apps, paired clients and certificates
New-Item -ItemType Directory -Force $backup | Out-Null
Get-ChildItem $config -Exclude 'sunshine.log*' | Copy-Item -Destination $backup -Recurse -Force
Write-Host "Config backed up to $backup"

$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/i `"$Msi`" /qn /norestart /l*v `"$log`""
Write-Host "msiexec exit code: $($p.ExitCode)"
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { exit $p.ExitCode }

# restore anything the installer changed or removed
$restored = @()
Get-ChildItem $backup -Recurse -File | ForEach-Object {
    $target = Join-Path $config $_.FullName.Substring($backup.Length + 1)
    if (-not (Test-Path $target) -or (Get-FileHash $target).Hash -ne (Get-FileHash $_.FullName).Hash) {
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $_.FullName $target -Force
        $restored += $target
    }
}
if ($restored) { Write-Host "Restored: $($restored -join ', ')" } else { Write-Host 'Config untouched by the installer' }

# LGTV Companion follows the stream through stream_notify_cmd. Its older hooks would only duplicate the signals:
# dd_prepare_cmd (replaced by stream_notify_cmd) and a global prep command made only of LGTV Companion commands.
$conf = Join-Path $config 'sunshine.conf'
$lines = @(Get-Content $conf | Where-Object {
    $_ -notmatch '^\s*(dd_prepare_cmd|stream_notify_cmd)\s*=' -and
    -not ($_ -match '^\s*global_prep_cmd\s*=' -and ($_ -replace 'LGTV Companion\.exe\\" -streaming_(dis)?connect', '') -notmatch '"(do|undo)":"[^"]')
}) + $notify
Set-Content $conf $lines -Encoding utf8NoBOM
Write-Host "sunshine.conf:"; $lines | ForEach-Object { Write-Host "  $_" }

Restart-Service SunshineService
Start-Sleep -Seconds 20
Get-Service SunshineService | ForEach-Object { Write-Host "Service: $($_.Status)" }
$reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' | Where-Object DisplayName -eq 'Sunshine'
Write-Host ("Registered: " + (($reg | ForEach-Object { "$($_.DisplayVersion) $($_.PSChildName)" }) -join '; '))
Get-Content (Join-Path $config 'sunshine.log') | Select-String "stream_notify_cmd|Found .* encoder|Fatal|Sunshine version" | ForEach-Object { Write-Host $_.Line }
