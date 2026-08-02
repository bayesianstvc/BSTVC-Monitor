[CmdletBinding()]
param(
    [string]$ProcessName = "inla",
    [string]$OutputDirectory = "",
    [string]$RunId = "",
    [string]$Label = "BSTVC Monitor",
    [ValidateRange(0.1, 3600)]
    [double]$IntervalSeconds = 5.0,
    [ValidateRange(0, 100)]
    [int]$HighCpuThreshold = 50,
    [ValidateRange(1024, 65535)]
    [int]$Port = 8765,
    [switch]$NoBrowser,
    [switch]$OpenDataFolder
)

$ErrorActionPreference = "Stop"
if ($null -eq ("System.Net.Http.HttpClient" -as [type])) {
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
}
$toolRoot = $PSScriptRoot
$monitorScript = Join-Path $toolRoot "bstvc-monitor.ps1"

function Get-DefaultOutputDirectory {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        return (Join-Path $localAppData "BSTVC-Monitor\runs")
    }
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    return (Join-Path $documents "BSTVC-Monitor\runs")
}

function Get-HealthyMonitor {
    param([int]$CheckPort)
    $client = [System.Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(4)
        $response = $client.GetAsync("http://127.0.0.1:$CheckPort/api/run").GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { return $null }
        return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json)
    } catch {
        return $null
    } finally {
        $client.Dispose()
    }
}

function Test-TcpPortInUse {
    param([int]$CheckPort)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync("127.0.0.1", $CheckPort)
        return ($task.Wait(500) -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Get-PowerShellExecutable {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    $windowsPowerShell = Join-Path $PSHOME "powershell.exe"
    if (Test-Path -LiteralPath $windowsPowerShell) { return $windowsPowerShell }
    throw "No usable PowerShell executable was found."
}

function Open-MonitorPage {
    param([string]$Url)
    $chromeCandidates = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    )
    foreach ($candidate in $chromeCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            Start-Process -FilePath $candidate -ArgumentList @("--new-window", $Url) | Out-Null
            return
        }
    }
    Start-Process $Url | Out-Null
}

if (-not (Test-Path -LiteralPath $monitorScript)) { throw "Monitor engine script was not found: $monitorScript" }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Get-DefaultOutputDirectory }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$targetName = [System.IO.Path]::GetFileNameWithoutExtension($ProcessName)
$healthyMonitor = Get-HealthyMonitor -CheckPort $Port
if ($healthyMonitor -and [string]::Equals([string]$healthyMonitor.process_name, $targetName, [System.StringComparison]::OrdinalIgnoreCase)) {
    $url = "http://127.0.0.1:$Port/"
    Write-Host "Reusing the healthy $targetName monitor: $url"
    if ($OpenDataFolder) { Start-Process $OutputDirectory }
    if (-not $NoBrowser) { Open-MonitorPage -Url $url }
    return
}

if ($healthyMonitor -or (Test-TcpPortInUse -CheckPort $Port)) {
    $selectedPort = $null
    foreach ($candidate in ($Port + 1)..($Port + 20)) {
        if (-not (Test-TcpPortInUse -CheckPort $candidate)) { $selectedPort = $candidate; break }
    }
    if ($null -eq $selectedPort) { throw "No available local port was found between $Port and $($Port + 20)." }
    Write-Host "Port $Port is already in use; switching to $selectedPort."
    $Port = $selectedPort
}

$runToken = if ([string]::IsNullOrWhiteSpace($RunId)) { "auto-" + [DateTime]::Now.ToString("yyyyMMdd-HHmmss") } else { $RunId }
$shell = Get-PowerShellExecutable
$arguments = @(
    "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"{0}"' -f $monitorScript),
    "-ProcessName", ('"{0}"' -f $targetName),
    "-OutputDirectory", ('"{0}"' -f $OutputDirectory),
    "-RunId", ('"{0}"' -f $runToken),
    "-Label", ('"{0}"' -f $Label),
    "-IntervalSeconds", "$IntervalSeconds",
    "-HighCpuThreshold", "$HighCpuThreshold",
    "-Port", "$Port",
    "-NoBrowser"
)
Start-Process -FilePath $shell -ArgumentList $arguments -WindowStyle Hidden | Out-Null

$deadline = [DateTime]::UtcNow.AddSeconds(25)
do {
    Start-Sleep -Milliseconds 500
    $healthyMonitor = Get-HealthyMonitor -CheckPort $Port
} while (-not $healthyMonitor -and [DateTime]::UtcNow -lt $deadline)

$url = "http://127.0.0.1:$Port/"
if ($healthyMonitor) {
    Write-Host "BSTVC Monitor started: $url"
    Write-Host "CSV and run data are saved under: $OutputDirectory"
    if ($OpenDataFolder) { Start-Process $OutputDirectory }
    if (-not $NoBrowser) { Open-MonitorPage -Url $url }
} else {
    Write-Warning "The monitor was launched but did not answer its local API within 25 seconds. Data may still be written to: $OutputDirectory"
    Write-Host "Check the newest run folder in that directory for diagnostics."
}
