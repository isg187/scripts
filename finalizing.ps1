<#
.SYNOPSIS
    Prepares the image for Sysprep. Stops third-party services and
    removes Docker Appx state that blocks generalize.
    Keeps AVD and FSLogix services Automatic.

.EXAMPLE
    .\finalizing.ps1
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Log {
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Message = '',
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    if (-not $script:LogPath) {
        $script:LogPath = Join-Path $env:TEMP ("SoftwareInstall_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    }

    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN' { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default { Write-Host $entry }
    }

    $logDir = Split-Path $script:LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $script:LogPath -Value $entry
}

$keepService = @(
    'WinRM', 'Winmgmt', 'EventLog', 'RpcSs', 'PlugPlay', 'DcomLaunch',
    'Dhcp', 'Dnscache', 'PolicyAgent', 'CryptSvc', 'Schedule', 'ProfSvc',
    'LanmanServer', 'LanmanWorkstation', 'W32Time', 'wuauserv', 'UsoSvc',
    'BITS', 'TrustedInstaller', 'WinDefend', 'Sense', 'WdNisSvc', 'mpssvc',
    'BFE', 'BrokerInfrastructure', 'LSM', 'Power', 'TrkWks', 'FontCache',
    'UserManager', 'SamSs', 'Netlogon', 'nsi', 'NlaSvc', 'iphlpsvc',
    'WinHttpAutoProxySvc', 'KeyIso', 'VaultSvc', 'StateRepository',
    'TokenBroker', 'WpnService', 'gpsvc', 'seclogon', 'ShellHWDetection',
    'SysMain', 'WSearch', 'Spooler', 'TermService', 'UmRdpService',
    'SessionEnv', 'WindowsAzureGuestAgent', 'WaAppAgent', 'RdAgent',
    'WindowsAzureTelemetryService', 'GCArcService', 'HybridInstanceMetadataService',
    'frxsvc', 'frxccds', 'frxdrv', 'frxdrvvt'
)

$automaticService = @(
    'frxsvc',
    'RdAgent',
    'WindowsAzureGuestAgent'
)

$keepProcess = @(
    'csrss', 'smss', 'wininit', 'winlogon', 'services', 'lsass', 'svchost',
    'System', 'Idle', 'spoolsv', 'dwm', 'explorer', 'MsMpEng', 'NisSrv',
    'SecurityHealthService', 'SearchHost', 'RuntimeBroker', 'sihost',
    'taskhostw', 'conhost', 'powershell', 'pwsh', 'WmiPrvSE', 'LogonUI',
    'fontdrvhost', 'dllhost', 'smartscreen', 'WindowsAzureGuestAgent',
    'WaAppAgent', 'WindowsAzureNetAgent', 'RdAgent', 'packer',
    'frxsvc', 'frxccds'
)

function Test-KeepName {
    param(
        [string]$Name,
        [string[]]$List
    )
    foreach ($item in $List) {
        if ($Name -like $item) { return $true }
    }
    return $false
}

function Test-WindowsBinary {
    param([string]$Path)
    if (-not $Path) { return $true }
    $clean = $Path.Trim('"')
    if ($clean -match '(?i)\\Windows\\System32\\') { return $true }
    if ($clean -match '(?i)\\Windows\\SysWOW64\\') { return $true }
    if ($clean -match '(?i)\\WindowsAzure\\') { return $true }
    if ($clean -match '(?i)\\GuestAgent\\') { return $true }
    if ($clean -match '^\\SystemRoot\\') { return $true }
    return $false
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("Finalizing_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

Write-Log 'Starting sysprep prep'

try {
    Write-Log 'Stopping Docker and related services'
    foreach ($name in @('com.docker.service', 'docker', 'dockerbackend', 'vmcompute', 'vmms')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($svc.Status -eq 'Running') {
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        }
        Set-Service -Name $name -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Log ('Set {0} to Disabled' -f $name)
    }

    foreach ($procName in @('Docker Desktop', 'com.docker.backend', 'dockerd', 'docker', 'wsl', 'wslservice')) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Write-Log 'Removing Docker Appx packages'
    Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'Docker' } |
    ForEach-Object {
        Write-Log ('Removing Appx {0}' -f $_.PackageFullName)
        Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
    }

    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Docker' } |
    ForEach-Object {
        Write-Log ('Removing provisioned {0}' -f $_.DisplayName)
        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue
    }

    Write-Log 'Stopping other third-party services'
    $services = Get-CimInstance Win32_Service | Where-Object { $_.State -eq 'Running' }
    foreach ($svc in $services) {
        if (Test-KeepName -Name $svc.Name -List $keepService) { continue }
        if (Test-WindowsBinary -Path $svc.PathName) { continue }
        Write-Log ('Stopping service {0}' -f $svc.Name)
        Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc.Name -StartupType Manual -ErrorAction SilentlyContinue
    }

    $procs = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -and
        $_.ExecutablePath -and
        -not (Test-KeepName -Name ($_.Name -replace '\.exe$', '') -List $keepProcess) -and
        -not (Test-WindowsBinary -Path $_.ExecutablePath)
    }
    foreach ($proc in $procs) {
        Write-Log ('Stopping process {0}' -f $proc.Name)
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }

    Write-Log 'Setting AVD and FSLogix services to Automatic'
    foreach ($name in $automaticService) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Log ('Service not present: {0}' -f $name) -Level WARN
            continue
        }
        Set-Service -Name $name -StartupType Automatic -ErrorAction SilentlyContinue
        Write-Log ('Set {0} to Automatic' -f $name) -Level SUCCESS
    }

    Write-Log 'Stop pass finished' -Level SUCCESS
    exit 0
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}
