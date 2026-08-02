[CmdletBinding()]
param(
    [string]$ProcessName = "inla",
    [string]$OutputDirectory = "",
    [string]$RunId = "",
    [string]$Label = "",
    [ValidateRange(0.1, 3600)]
    [double]$IntervalSeconds = 5.0,
    [ValidateRange(1, 1440)]
    [int]$HistoryMinutes = 120,
    [ValidateRange(0, 100)]
    [int]$HighCpuThreshold = 50,
    [ValidateRange(1024, 65535)]
    [int]$Port = 8765,
    [switch]$NoBrowser,
    [switch]$Once,
    [ValidateRange(0, 10000000)]
    [int]$MaxSamples = 0
)

$ErrorActionPreference = "Stop"
$targetName = [System.IO.Path]::GetFileNameWithoutExtension($ProcessName)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $OutputDirectory = Join-Path $localAppData "BSTVC-Monitor\runs"
    } else {
        # Retain a usable fallback for unusual portable/locked-down Windows profiles.
        $OutputDirectory = Join-Path $PSScriptRoot "runs"
    }
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$safeRunId = if ([string]::IsNullOrWhiteSpace($RunId)) { "run" } else { $RunId -replace '[^\p{L}\p{Nd}_-]+', '-' }
$startStamp = [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss")
$baseRunFolder = Join-Path $OutputDirectory ("{0}_{1}" -f $startStamp, $safeRunId)
$runFolder = $baseRunFolder
$suffix = 2
while (Test-Path -LiteralPath $runFolder) {
    $runFolder = "{0}-{1:00}" -f $baseRunFolder, $suffix
    $suffix++
}
New-Item -ItemType Directory -Path $runFolder -Force | Out-Null

$metricsPath = Join-Path $runFolder "metrics.csv"
$eventsPath = Join-Path $runFolder "events.csv"
$runJsonPath = Join-Path $runFolder "run.json"
$summaryJsonPath = Join-Path $runFolder "summary.json"
$reportPath = Join-Path $runFolder "report.html"
$livePath = Join-Path $runFolder "live.html"
$dashboardSource = Join-Path $PSScriptRoot "dashboard.html"

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$metricsWriter = [System.IO.StreamWriter]::new($metricsPath, $false, $utf8NoBom)
$eventsWriter = [System.IO.StreamWriter]::new($eventsPath, $false, $utf8NoBom)
$metricsHeaders = @(
    "timestamp", "run_id", "label", "status", "pid", "process_name",
    "process_start_time", "process_runtime_seconds",
    "cpu_pct_total", "cpu_pct_logical_total", "cpu_core_equivalent", "windows_counter_cpu_pct", "working_set_mb", "private_mb",
    "virtual_memory_mb", "paged_memory_mb", "thread_count", "process_count",
    "io_read_bytes_per_sec", "io_write_bytes_per_sec", "page_faults_per_sec", "context_switches_per_sec",
    "host_cpu_pct", "host_cpu_time_pct", "cpu_utility_scale", "host_memory_pct"
)
$eventHeaders = @("timestamp", "event", "pid", "detail")
$metricsWriter.WriteLine(($metricsHeaders -join ","))
$eventsWriter.WriteLine(($eventHeaders -join ","))

$script:historyRows = [System.Collections.Generic.List[object]]::new()
$script:lastCpu = @{}
$script:processMetadata = @{}
$script:previousPids = [System.Collections.Generic.HashSet[int]]::new()
$script:sampleCount = 0
$script:totalMemoryKb = $null
$script:intervalSeconds = [double]$IntervalSeconds
$script:diagnosticsRefreshEvery = [Math]::Max(1, [int][Math]::Ceiling(15 / [Math]::Max(0.1, $script:intervalSeconds)))
$script:cachedHostCpuMetrics = $null
$script:cachedHostMemory = $null
$script:cachedWindowsCpuByPid = @{}
$script:cachedWindowsProcessDiagnosticsByPid = @{}
$script:startNewRunRequested = $false
$script:startNewRunRequestedAt = $null
$historyMaxRows = [Math]::Max(600, [int]([Math]::Ceiling(($HistoryMinutes * 60) / $IntervalSeconds) * 8))

function Write-CsvObject {
    param(
        [Parameter(Mandatory)]$Writer,
        [Parameter(Mandatory)]$Object
    )
    $line = $Object | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1
    $Writer.WriteLine([string]$line)
    $Writer.Flush()
}

function Write-Event {
    param([string]$Event, [string]$ProcessId, [string]$Detail)
    $eventObject = [PSCustomObject]@{
        timestamp = [DateTimeOffset]::Now.ToString("o")
        event = $Event
        pid = $ProcessId
        detail = $Detail
    }
    Write-CsvObject -Writer $eventsWriter -Object $eventObject
}

function Get-HostCpuCounters {
    $result = [PSCustomObject]@{ utility = $null; time = $null; scale = 1.0 }
    try {
        $samples = @(Get-Counter -Counter @('\Processor Information(_Total)\% Processor Utility', '\Processor Information(_Total)\% Processor Time') -ErrorAction Stop |
            Select-Object -ExpandProperty CounterSamples)
        foreach ($sample in $samples) {
            $path = ([string]$sample.Path).ToLowerInvariant()
            if ($path -like '*% processor utility') { $result.utility = [Math]::Round([double]$sample.CookedValue, 3) }
            if ($path -like '*% processor time') { $result.time = [Math]::Round([double]$sample.CookedValue, 3) }
        }
        if ($null -ne $result.utility -and $null -ne $result.time -and $result.time -gt 0) {
            $result.scale = [Math]::Max(0.1, [Math]::Min(20.0, [double]$result.utility / [double]$result.time))
        }
    } catch {
        # Fall back to the process-time scale when utility counters are unavailable.
    }
    return $result
}

function Get-HostCpuPercent {
    return (Get-HostCpuCounters).utility
}

function Get-WindowsProcessCpuCounter {
    $result = @{}
    try {
        $samples = @(Get-Counter -Counter @('\Process(inla*)\ID Process', '\Process(inla*)\% Processor Time') -ErrorAction Stop |
            Select-Object -ExpandProperty CounterSamples)
        $pidByInstance = @{}
        foreach ($sample in $samples) {
            $match = [regex]::Match([string]$sample.Path, '\\process\(([^)]+)\)\\id process$')
            if ($match.Success) {
                $pidByInstance[$match.Groups[1].Value] = [int]$sample.CookedValue
            }
        }
        foreach ($sample in $samples) {
            $match = [regex]::Match([string]$sample.Path, '\\process\(([^)]+)\)\\% processor time$')
            if ($match.Success) {
                $instance = $match.Groups[1].Value
                if ($pidByInstance.ContainsKey($instance)) {
                    $result[$pidByInstance[$instance]] = [Math]::Round([double]$sample.CookedValue, 3)
                }
            }
        }
    } catch {
        # Performance counters can be unavailable under restricted permissions; other metrics remain usable.
    }
    return $result
}

function Get-WindowsProcessDiagnosticCounters {
    $result = @{}
    try {
        $counterPaths = @(
            '\Process(inla*)\ID Process',
            '\Process(inla*)\IO Read Bytes/sec',
            '\Process(inla*)\IO Write Bytes/sec',
            '\Process(inla*)\Page Faults/sec',
            '\Thread(inla*)\ID Process',
            '\Thread(inla*)\Context Switches/sec'
        )
        $samples = @(Get-Counter -Counter $counterPaths -ErrorAction Stop | Select-Object -ExpandProperty CounterSamples)
        $processPidByInstance = @{}
        $threadPidByInstance = @{}
        foreach ($sample in $samples) {
            $path = ([string]$sample.Path).ToLowerInvariant()
            $processMatch = [regex]::Match($path, '\\process\(([^)]+)\)\\id process$')
            $threadMatch = [regex]::Match($path, '\\thread\(([^)]+)\)\\id process$')
            if ($processMatch.Success) { $processPidByInstance[$processMatch.Groups[1].Value] = [int]$sample.CookedValue }
            if ($threadMatch.Success) { $threadPidByInstance[$threadMatch.Groups[1].Value] = [int]$sample.CookedValue }
        }
        foreach ($sample in $samples) {
            $path = ([string]$sample.Path).ToLowerInvariant()
            $processMatch = [regex]::Match($path, '\\process\(([^)]+)\)\\(.+)$')
            $threadMatch = [regex]::Match($path, '\\thread\(([^)]+)\)\\context switches/sec$')
            if ($processMatch.Success -and $processPidByInstance.ContainsKey($processMatch.Groups[1].Value)) {
                $pid = [int]$processPidByInstance[$processMatch.Groups[1].Value]
                if (-not $result.ContainsKey($pid)) { $result[$pid] = @{ io_read = $null; io_write = $null; page_faults = $null; context_switches = 0.0 } }
                $counterName = $processMatch.Groups[2].Value
                if ($counterName -eq 'io read bytes/sec') { $result[$pid].io_read = [Math]::Round([double]$sample.CookedValue, 3) }
                if ($counterName -eq 'io write bytes/sec') { $result[$pid].io_write = [Math]::Round([double]$sample.CookedValue, 3) }
                if ($counterName -eq 'page faults/sec') { $result[$pid].page_faults = [Math]::Round([double]$sample.CookedValue, 3) }
            }
            if ($threadMatch.Success -and $threadPidByInstance.ContainsKey($threadMatch.Groups[1].Value)) {
                $pid = [int]$threadPidByInstance[$threadMatch.Groups[1].Value]
                if (-not $result.ContainsKey($pid)) { $result[$pid] = @{ io_read = $null; io_write = $null; page_faults = $null; context_switches = 0.0 } }
                $result[$pid].context_switches = [Math]::Round(([double]$result[$pid].context_switches + [double]$sample.CookedValue), 3)
            }
        }
    } catch {
        # These counters are optional and may be unavailable under restricted permissions.
    }
    return $result
}

function Get-PhysicalCoreCount {
    try {
        $processorInfo = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        $coreCount = [int](($processorInfo | Measure-Object -Property NumberOfCores -Sum).Sum)
        if ($coreCount -gt 0) { return $coreCount }
    } catch {
        # Fall through to the Windows topology API when WMI access is restricted.
    }
    try {
        if (-not ("InlaMonitorCpuTopology" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class InlaMonitorCpuTopology {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetLogicalProcessorInformationEx(ushort relationship, IntPtr buffer, ref uint returnedLength);
}
"@
        }
        [uint32]$length = 0
        [void][InlaMonitorCpuTopology]::GetLogicalProcessorInformationEx(0, [IntPtr]::Zero, [ref]$length)
        if ($length -le 0) { throw "CPU topology length unavailable" }
        $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal([int]$length)
        try {
            if (-not [InlaMonitorCpuTopology]::GetLogicalProcessorInformationEx(0, $buffer, [ref]$length)) { throw "CPU topology query failed" }
            $offset = 0
            $count = 0
            while ($offset -lt $length) {
                $relationship = [Runtime.InteropServices.Marshal]::ReadInt32($buffer, $offset)
                $size = [Runtime.InteropServices.Marshal]::ReadInt32($buffer, $offset + 4)
                if ($relationship -eq 0) { $count++ }
                if ($size -le 0) { break }
                $offset += $size
            }
            if ($count -gt 0) { return $count }
        } finally {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
        }
    } catch {
        # The logical processor count is the safe final fallback.
    }
    return [Environment]::ProcessorCount
}

$script:logicalProcessorCount = [Math]::Max(1, [Environment]::ProcessorCount)
$script:physicalCoreCount = [Math]::Max(1, [int](Get-PhysicalCoreCount))
$script:taskManagerCpuDenominator = $script:physicalCoreCount

function Get-HostMemoryPercent {
    try {
        if ($null -eq $script:totalMemoryKb) {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $script:totalMemoryKb = [double]$os.TotalVisibleMemorySize
        }
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($script:totalMemoryKb -gt 0) {
            return [Math]::Round(100 * (1 - ([double]$os.FreePhysicalMemory / $script:totalMemoryKb)), 2)
        }
    } catch {
        # Some locked-down Windows sessions deny CIM access. Use the local
        # .NET computer information provider without requiring elevation.
    }
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        $computerInfo = [Microsoft.VisualBasic.Devices.ComputerInfo]::new()
        $totalBytes = [double]$computerInfo.TotalPhysicalMemory
        $availableBytes = [double]$computerInfo.AvailablePhysicalMemory
        if ($totalBytes -gt 0) {
            $script:totalMemoryKb = $totalBytes / 1KB
            return [Math]::Round(100 * (1 - ($availableBytes / $totalBytes)), 2)
        }
    } catch {
        return $null
    }
    return $null
}

function Get-TotalPhysicalMemoryGb {
    try {
        if ($null -eq $script:totalMemoryKb) {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $script:totalMemoryKb = [double]$os.TotalVisibleMemorySize
        }
        if ($script:totalMemoryKb -gt 0) {
            return [Math]::Round($script:totalMemoryKb / 1MB, 2)
        }
    } catch {
        # Fall through to the non-CIM provider below.
    }
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        $computerInfo = [Microsoft.VisualBasic.Devices.ComputerInfo]::new()
        if ($computerInfo.TotalPhysicalMemory -gt 0) {
            $script:totalMemoryKb = [double]$computerInfo.TotalPhysicalMemory / 1KB
            return [Math]::Round([double]$computerInfo.TotalPhysicalMemory / 1GB, 2)
        }
    } catch {
        return $null
    }
    return $null
}

function Add-HistoryRow {
    param([Parameter(Mandatory)]$Row)
    $script:historyRows.Add($Row)
    if ($script:historyRows.Count -gt $historyMaxRows) {
        $removeCount = $script:historyRows.Count - $historyMaxRows
        $script:historyRows.RemoveRange(0, $removeCount)
    }
}

function Get-Aggregates {
    param([Parameter(Mandatory)][object[]]$Rows)
    $activeRows = @($Rows | Where-Object { $_.status -in @("running", "warmup") })
    if ($activeRows.Count -eq 0) { return @() }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($group in ($activeRows | Group-Object -Property timestamp | Sort-Object Name)) {
        $groupRows = @($group.Group)
        $sum = {
            param($property)
            (($groupRows | ForEach-Object {
                $value = $_.$property
                if ($null -ne $value -and "$value" -ne "") { [double]$value } else { 0 }
            } | Measure-Object -Sum).Sum)
        }
        $hostCpuValues = @($groupRows | ForEach-Object { if ("$($_.host_cpu_pct)" -ne "") { [double]$_.host_cpu_pct } })
        $hostMemValues = @($groupRows | ForEach-Object { if ("$($_.host_memory_pct)" -ne "") { [double]$_.host_memory_pct } })
        $groupStatus = if (@($groupRows | Where-Object { $_.status -eq "running" }).Count -gt 0) { "running" } else { "warmup" }
        $result.Add([PSCustomObject]@{
            timestamp = $group.Name
            run_id = [string]$groupRows[0].run_id
            label = [string]$groupRows[0].label
            status = $groupStatus
            pid = 0
            process_name = $targetName
            cpu_pct_total = [Math]::Round((&$sum "cpu_pct_total"), 3)
            cpu_pct_logical_total = [Math]::Round((&$sum "cpu_pct_logical_total"), 3)
            cpu_core_equivalent = [Math]::Round((&$sum "cpu_core_equivalent"), 3)
            windows_counter_cpu_pct = [Math]::Round((&$sum "windows_counter_cpu_pct"), 3)
            working_set_mb = [Math]::Round((&$sum "working_set_mb"), 3)
            private_mb = [Math]::Round((&$sum "private_mb"), 3)
            virtual_memory_mb = [Math]::Round((&$sum "virtual_memory_mb"), 3)
            paged_memory_mb = [Math]::Round((&$sum "paged_memory_mb"), 3)
            thread_count = [int]((&$sum "thread_count"))
            process_count = $groupRows.Count
            host_cpu_pct = if ($hostCpuValues.Count) { [Math]::Round((($hostCpuValues | Measure-Object -Average).Average), 3) } else { $null }
            host_cpu_time_pct = if (@($groupRows | Where-Object { "$($_.host_cpu_time_pct)" -ne "" }).Count) { [Math]::Round(((@($groupRows | ForEach-Object { if ("$($_.host_cpu_time_pct)" -ne "") { [double]$_.host_cpu_time_pct } }) | Measure-Object -Average).Average), 3) } else { $null }
            cpu_utility_scale = if (@($groupRows | Where-Object { "$($_.cpu_utility_scale)" -ne "" }).Count) { [Math]::Round(((@($groupRows | ForEach-Object { if ("$($_.cpu_utility_scale)" -ne "") { [double]$_.cpu_utility_scale } }) | Measure-Object -Average).Average), 3) } else { $null }
            host_memory_pct = if ($hostMemValues.Count) { [Math]::Round((($hostMemValues | Measure-Object -Average).Average), 3) } else { $null }
        })
    }
    return $result.ToArray()
}

function Get-Summary {
    param([Parameter(Mandatory)][object[]]$Rows)
    $aggregates = @(Get-Aggregates -Rows $Rows)
    $cpuAggregates = @($aggregates | Where-Object { $_.status -eq "running" })
    $cpu = @($cpuAggregates | ForEach-Object { [double]$_.cpu_pct_total })
    $memory = @($aggregates | ForEach-Object { [double]$_.working_set_mb })
    $private = @($aggregates | ForEach-Object { [double]$_.private_mb })
    $highCount = @($cpu | Where-Object { $_ -ge $HighCpuThreshold }).Count
    $count = $aggregates.Count
    $cpuCount = $cpu.Count
    $percentile = {
        param([double[]]$Values, [double]$Probability)
        if ($Values.Count -eq 0) { return $null }
        $sorted = @($Values | Sort-Object)
        $index = [int][Math]::Ceiling($Probability * $sorted.Count) - 1
        $index = [Math]::Max(0, [Math]::Min($index, $sorted.Count - 1))
        return [Math]::Round($sorted[$index], 3)
    }
    return [PSCustomObject]@{
        generated_at = [DateTimeOffset]::Now.ToString("o")
        run_id = $safeRunId
        label = $Label
        process_name = $targetName
        interval_seconds = $script:intervalSeconds
        high_cpu_threshold = $HighCpuThreshold
        sample_count = $count
        high_cpu_samples = $highCount
        high_cpu_fraction = if ($cpuCount) { [Math]::Round($highCount / $cpuCount, 4) } else { 0 }
        cpu_mean_pct_total = if ($cpuCount) { [Math]::Round(($cpu | Measure-Object -Average).Average, 3) } else { $null }
        cpu_p95_pct_total = &$percentile $cpu 0.95
        cpu_max_pct_total = if ($cpuCount) { [Math]::Round(($cpu | Measure-Object -Maximum).Maximum, 3) } else { $null }
        working_set_mean_mb = if ($count) { [Math]::Round(($memory | Measure-Object -Average).Average, 3) } else { $null }
        working_set_peak_mb = if ($count) { [Math]::Round(($memory | Measure-Object -Maximum).Maximum, 3) } else { $null }
        private_peak_mb = if ($count) { [Math]::Round(($private | Measure-Object -Maximum).Maximum, 3) } else { $null }
        first_sample = if ($count) { $aggregates[0].timestamp } else { $null }
        last_sample = if ($count) { $aggregates[$count - 1].timestamp } else { $null }
    }
}

function Sample-Processes {
    # Get-Process is the primary Task Manager-aligned snapshot. The Windows
    # performance-counter/WMI calls are deliberately refreshed less often at
    # short intervals because they can block for more than one second. They
    # must run after the primary snapshot: otherwise a slow counter call makes
    # the CPU-time delta look too large for the timestamp interval, producing
    # a false 100% spike followed by a false near-zero sample.
    $processes = @(Get-Process -Name $targetName -ErrorAction SilentlyContinue)
    $now = [DateTimeOffset]::Now
    $refreshDiagnostics = ($null -eq $script:cachedHostCpuMetrics) -or (($script:sampleCount % $script:diagnosticsRefreshEvery) -eq 0)
    $hostCpuMetrics = $script:cachedHostCpuMetrics
    if ($null -eq $hostCpuMetrics) { $hostCpuMetrics = [PSCustomObject]@{ utility = $null; time = $null; scale = 1.0 } }
    $hostCpu = $hostCpuMetrics.utility
    $hostCpuTime = $hostCpuMetrics.time
    $cpuUtilityScale = $hostCpuMetrics.scale
    $hostMemory = $script:cachedHostMemory
    $windowsCpuByPid = if ($null -ne $script:cachedWindowsCpuByPid) { $script:cachedWindowsCpuByPid } else { @{} }
    $processDiagnosticsByPid = if ($null -ne $script:cachedWindowsProcessDiagnosticsByPid) { $script:cachedWindowsProcessDiagnosticsByPid } else { @{} }
    $currentPids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($process in $processes) {
        [void]$currentPids.Add([int]$process.Id)
    }
    foreach ($oldPid in @($script:previousPids)) {
        if (-not $currentPids.Contains($oldPid)) {
            Write-Event -Event "exited" -ProcessId "$oldPid" -Detail "process disappeared"
            $metadata = if ($script:processMetadata.ContainsKey($oldPid)) { $script:processMetadata[$oldPid] } else { $null }
            $stopped = [PSCustomObject]@{
                timestamp = $now.ToString("o"); run_id = $safeRunId; label = $Label; status = "stopped"; pid = $oldPid; process_name = $targetName
                process_start_time = if ($metadata -and $metadata.start_time) { $metadata.start_time.ToString("o") } else { $null }
                process_runtime_seconds = if ($metadata) { $metadata.last_runtime_seconds } else { $null }
                cpu_pct_total = $null; cpu_pct_logical_total = $null; cpu_core_equivalent = $null; windows_counter_cpu_pct = $null
                working_set_mb = $null; private_mb = $null; virtual_memory_mb = $null; paged_memory_mb = $null
                thread_count = if ($metadata) { $metadata.last_thread_count } else { $null }
                io_read_bytes_per_sec = $null; io_write_bytes_per_sec = $null; page_faults_per_sec = $null; context_switches_per_sec = $null
                process_count = $processes.Count; host_cpu_pct = $hostCpu; host_cpu_time_pct = $hostCpuTime; cpu_utility_scale = $cpuUtilityScale; host_memory_pct = $hostMemory
            }
            Write-CsvObject -Writer $metricsWriter -Object $stopped
            Add-HistoryRow -Row $stopped
            $script:lastCpu.Remove($oldPid)
            $script:processMetadata.Remove($oldPid)
        }
    }
    foreach ($newPid in @($currentPids)) {
        if (-not $script:previousPids.Contains($newPid)) {
            Write-Event -Event "started" -ProcessId "$newPid" -Detail "process detected"
            $script:processMetadata[$newPid] = [PSCustomObject]@{ first_seen_at = $now; start_time = $null; last_runtime_seconds = $null; last_thread_count = $null; last_seen_at = $now }
        }
    }

    if ($processes.Count -eq 0) {
        $waiting = [PSCustomObject]@{
            timestamp = $now.ToString("o"); run_id = $safeRunId; label = $Label; status = "waiting"; pid = $null; process_name = $targetName; process_start_time = $null; process_runtime_seconds = $null
            cpu_pct_total = $null; cpu_pct_logical_total = $null; cpu_core_equivalent = $null; windows_counter_cpu_pct = $null; working_set_mb = $null; private_mb = $null; virtual_memory_mb = $null; paged_memory_mb = $null
            thread_count = $null; process_count = 0; io_read_bytes_per_sec = $null; io_write_bytes_per_sec = $null; page_faults_per_sec = $null; context_switches_per_sec = $null; host_cpu_pct = $hostCpu; host_cpu_time_pct = $hostCpuTime; cpu_utility_scale = $cpuUtilityScale; host_memory_pct = $hostMemory
        }
        Write-CsvObject -Writer $metricsWriter -Object $waiting
        Add-HistoryRow -Row $waiting
    } else {
        foreach ($process in $processes) {
            $processId = [int]$process.Id
            if (-not $script:processMetadata.ContainsKey($processId)) {
                $script:processMetadata[$processId] = [PSCustomObject]@{ first_seen_at = $now; start_time = $null; last_runtime_seconds = $null; last_thread_count = $null; last_seen_at = $now }
            }
            $processStartTime = $null
            try { $processStartTime = [DateTimeOffset]$process.StartTime } catch {}
            if ($null -ne $processStartTime) {
                $script:processMetadata[$processId].start_time = $processStartTime
            } else {
                $processStartTime = $script:processMetadata[$processId].start_time
            }
            $processRuntimeSeconds = if ($null -ne $processStartTime) { [Math]::Max(0, [Math]::Round(($now - $processStartTime).TotalSeconds, 3)) } else { [Math]::Max(0, [Math]::Round(($now - $script:processMetadata[$processId].first_seen_at).TotalSeconds, 3)) }
            $status = "warmup"
            $cpuTotal = 0.0
            $cpuLogicalTotal = 0.0
            $cpuCore = 0.0
            $windowsCounterCpu = $null
            try {
                $cpuSeconds = [double]$process.TotalProcessorTime.TotalSeconds
                if ($script:lastCpu.ContainsKey($processId)) {
                    $previous = $script:lastCpu[$processId]
                    $elapsed = ($now - $previous.timestamp).TotalSeconds
                    if ($elapsed -gt 0) {
                        $cpuCore = [Math]::Max(0, [Math]::Min(100 * [Environment]::ProcessorCount, 100 * (($cpuSeconds - $previous.cpuSeconds) / $elapsed)))
                        $cpuLogicalTotal = [Math]::Max(0, [Math]::Min(100, $cpuCore / $script:logicalProcessorCount))
                        # Windows Task Manager's Processes/Performance CPU values use Processor Utility,
                        # while Process\% Processor Time is a time-based counter. Apply the host utility/time
                        # ratio to the PID's time-based total so the main series follows Task Manager's basis.
                        $cpuTotal = [Math]::Max(0, [Math]::Min(100, $cpuLogicalTotal * $cpuUtilityScale))
                        $status = "running"
                    }
                }
                $script:lastCpu[$processId] = [PSCustomObject]@{ timestamp = $now; cpuSeconds = $cpuSeconds }
            } catch {
                $status = "unreadable"
            }
            if ($windowsCpuByPid.ContainsKey($processId)) {
                # Keep Process\% Processor Time as an advanced diagnostic only. It is
                # measured in a separate performance-counter window and can be out of
                # phase with the Get-Process CPU-time and Working Set snapshot. The
                # primary Task Manager-basis value above must not be overwritten here.
                $windowsCounterCpu = $windowsCpuByPid[$processId]
            }
            $threadCount = $null
            try { $threadCount = [int]$process.Threads.Count } catch {}
            $diagnosticCounters = if ($processDiagnosticsByPid.ContainsKey($processId)) { $processDiagnosticsByPid[$processId] } else { $null }
            $row = [PSCustomObject]@{
                timestamp = $now.ToString("o"); run_id = $safeRunId; label = $Label; status = $status; pid = $processId; process_name = $targetName; process_start_time = if ($null -ne $processStartTime) { $processStartTime.ToString("o") } else { $null }; process_runtime_seconds = $processRuntimeSeconds
                cpu_pct_total = [Math]::Round($cpuTotal, 3); cpu_pct_logical_total = [Math]::Round($cpuLogicalTotal, 3); cpu_core_equivalent = [Math]::Round($cpuCore, 3); windows_counter_cpu_pct = $windowsCounterCpu
                working_set_mb = [Math]::Round(([double]$process.WorkingSet64 / 1MB), 3)
                private_mb = [Math]::Round(([double]$process.PrivateMemorySize64 / 1MB), 3)
                virtual_memory_mb = [Math]::Round(([double]$process.VirtualMemorySize64 / 1MB), 3)
                paged_memory_mb = [Math]::Round(([double]$process.PagedMemorySize64 / 1MB), 3)
                thread_count = $threadCount
                io_read_bytes_per_sec = if ($diagnosticCounters) { $diagnosticCounters.io_read } else { $null }
                io_write_bytes_per_sec = if ($diagnosticCounters) { $diagnosticCounters.io_write } else { $null }
                page_faults_per_sec = if ($diagnosticCounters) { $diagnosticCounters.page_faults } else { $null }
                context_switches_per_sec = if ($diagnosticCounters) { $diagnosticCounters.context_switches } else { $null }
                process_count = $processes.Count; host_cpu_pct = $hostCpu; host_cpu_time_pct = $hostCpuTime; cpu_utility_scale = $cpuUtilityScale; host_memory_pct = $hostMemory
            }
            Write-CsvObject -Writer $metricsWriter -Object $row
            Add-HistoryRow -Row $row
            $script:processMetadata[$processId].last_runtime_seconds = $processRuntimeSeconds
            $script:processMetadata[$processId].last_thread_count = $threadCount
            $script:processMetadata[$processId].last_seen_at = $now
        }
    }
    $script:previousPids = $currentPids
    $script:sampleCount++
    # Refresh slow diagnostics only after the primary CPU/memory rows have
    # been timestamped and written. The elapsed time of this work is then
    # included in the next sample interval instead of corrupting this one.
    if ($refreshDiagnostics) {
        $script:cachedHostCpuMetrics = Get-HostCpuCounters
        $script:cachedHostMemory = Get-HostMemoryPercent
        $script:cachedWindowsCpuByPid = Get-WindowsProcessCpuCounter
        $script:cachedWindowsProcessDiagnosticsByPid = Get-WindowsProcessDiagnosticCounters
    }
}

function Write-Response {
    param($Context, [int]$StatusCode, [string]$ContentType, [byte[]]$Bytes)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentEncoding = [System.Text.Encoding]::UTF8
    $Context.Response.Headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    $Context.Response.Headers["Pragma"] = "no-cache"
    $Context.Response.ContentLength64 = $Bytes.Length
    $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Write-JsonResponse {
    param($Context, $Object)
    $json = $Object | ConvertTo-Json -Depth 8 -Compress
    Write-Response -Context $Context -StatusCode 200 -ContentType "application/json; charset=utf-8" -Bytes $utf8NoBom.GetBytes($json)
}

function Save-BytesWithUserDialog {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$SuggestedName,
        [Parameter(Mandatory)][string]$Filter,
        [string]$Title = "Save BSTVC Monitor export"
    )
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $dialog = [System.Windows.Forms.SaveFileDialog]::new()
    try {
        $dialog.Title = $Title
        $dialog.FileName = $SuggestedName
        $dialog.Filter = $Filter
        $dialog.OverwritePrompt = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            [System.IO.File]::WriteAllBytes($dialog.FileName, $Bytes)
            return $dialog.FileName
        }
        return $null
    } finally {
        $dialog.Dispose()
    }
}

function Quote-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-ReplacementMonitor {
    $hostPath = try { (Get-Process -Id $PID -ErrorAction Stop).Path } catch { $null }
    if ([string]::IsNullOrWhiteSpace($hostPath)) {
        $hostPath = if ($PSVersionTable.PSEdition -eq "Core") { Join-Path $PSHOME "pwsh.exe" } else { Join-Path $PSHOME "powershell.exe" }
    }
    $newRunId = "run-{0}" -f [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss")
    $arguments = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Quote-NativeArgument $PSCommandPath),
        "-ProcessName", (Quote-NativeArgument $ProcessName),
        "-OutputDirectory", (Quote-NativeArgument $OutputDirectory),
        "-RunId", (Quote-NativeArgument $newRunId),
        "-Label", (Quote-NativeArgument $Label),
        "-IntervalSeconds", $script:intervalSeconds.ToString([Globalization.CultureInfo]::InvariantCulture),
        "-HistoryMinutes", $HistoryMinutes.ToString([Globalization.CultureInfo]::InvariantCulture),
        "-HighCpuThreshold", $HighCpuThreshold.ToString([Globalization.CultureInfo]::InvariantCulture),
        "-Port", $Port.ToString([Globalization.CultureInfo]::InvariantCulture),
        "-NoBrowser"
    ) -join " "
    return Start-Process -FilePath $hostPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru
}

function Handle-HttpRequest {
    param($Context)
    try {
        $path = $Context.Request.Url.AbsolutePath
        if ($path -eq "/" -or $path -eq "/dashboard.html") {
            $html = Get-Content -LiteralPath $dashboardSource -Raw -Encoding UTF8
            Write-Response -Context $Context -StatusCode 200 -ContentType "text/html; charset=utf-8" -Bytes $utf8NoBom.GetBytes($html)
        } elseif ($path -eq "/api/metrics") {
            $metricRows = @($script:historyRows.ToArray())
            $sinceText = [string]$Context.Request.QueryString["since"]
            $sinceValue = [DateTimeOffset]::MinValue
            $hasSince = -not [string]::IsNullOrWhiteSpace($sinceText) -and [DateTimeOffset]::TryParse($sinceText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$sinceValue)
            if ($hasSince) {
                $metricRows = @($metricRows | Where-Object {
                    $rowTime = [DateTimeOffset]::MinValue
                    [DateTimeOffset]::TryParse([string]$_.timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$rowTime) -and $rowTime -gt $sinceValue
                })
            }
            $limit = 0
            $limitText = [string]$Context.Request.QueryString["limit"]
            if (-not [int]::TryParse($limitText, [ref]$limit)) { $limit = 0 }
            $limit = [Math]::Max(0, [Math]::Min(50000, $limit))
            if ($limit -gt 0 -and $metricRows.Count -gt $limit) { $metricRows = @($metricRows | Select-Object -Last $limit) }
            Write-JsonResponse -Context $Context -Object $metricRows
        } elseif ($path -eq "/api/summary") {
            Write-JsonResponse -Context $Context -Object (Get-Summary -Rows @($script:historyRows.ToArray()))
        } elseif ($path -eq "/api/run") {
            Write-JsonResponse -Context $Context -Object (Get-Content -LiteralPath $runJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        } elseif ($path -eq "/api/health") {
            $healthRows = @($script:historyRows.ToArray())
            $latestRow = if ($healthRows.Count) { $healthRows[$healthRows.Count - 1] } else { $null }
            $latestTime = [DateTimeOffset]::MinValue
            $hasLatest = $null -ne $latestRow -and [DateTimeOffset]::TryParse([string]$latestRow.timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$latestTime)
            $dataAge = if ($hasLatest) { [Math]::Max(0, ([DateTimeOffset]::Now - $latestTime).TotalSeconds) } else { $null }
            Write-JsonResponse -Context $Context -Object ([PSCustomObject]@{
                service = "ok"
                api = "ok"
                server_time = [DateTimeOffset]::Now.ToString("o")
                latest_sample = if ($hasLatest) { $latestTime.ToString("o") } else { $null }
                data_age_seconds = if ($null -ne $dataAge) { [Math]::Round($dataAge, 2) } else { $null }
                history_row_count = $healthRows.Count
                sample_count = $script:sampleCount
                process_count = if ($null -ne $latestRow) { $latestRow.process_count } else { 0 }
                run_id = $safeRunId
                output_directory = $runFolder
                csv_path = $metricsPath
                restart_pending = $script:startNewRunRequested
            })
        } elseif ($path -eq "/api/new-run" -and $Context.Request.HttpMethod -eq "POST") {
            if (-not $script:startNewRunRequested) {
                $script:startNewRunRequested = $true
                $script:startNewRunRequestedAt = [DateTimeOffset]::Now
                Write-Event -Event "new_run_requested" -ProcessId "" -Detail "requested from dashboard"
            }
            Write-JsonResponse -Context $Context -Object ([PSCustomObject]@{ accepted = $true; restart_pending = $true; current_run_id = $safeRunId })
        } elseif ($path -eq "/api/settings") {
            if ($Context.Request.HttpMethod -in @("POST", "PUT")) {
                $candidate = $Context.Request.QueryString["interval_seconds"]
                $interval = 0.0
                if (-not [double]::TryParse([string]$candidate, [ref]$interval) -or $interval -lt 0.1 -or $interval -gt 3600) {
                    Write-Response -Context $Context -StatusCode 400 -ContentType "text/plain; charset=utf-8" -Bytes $utf8NoBom.GetBytes("interval_seconds must be between 0.1 and 3600")
                    return
                }
                $script:intervalSeconds = [Math]::Round($interval, 2)
                $script:diagnosticsRefreshEvery = [Math]::Max(1, [int][Math]::Ceiling(15 / [Math]::Max(0.1, $script:intervalSeconds)))
                $runMetadata.interval_seconds = $script:intervalSeconds
                $runMetadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runJsonPath -Encoding UTF8
                Write-Event -Event "interval_changed" -ProcessId "" -Detail ("interval_seconds={0}" -f $script:intervalSeconds)
            }
            Write-JsonResponse -Context $Context -Object ([PSCustomObject]@{ interval_seconds = $script:intervalSeconds })
        } elseif ($path -eq "/metrics.csv") {
            $rows = @($script:historyRows.ToArray())
            $csv = if ($rows.Count) { $rows | Select-Object -Property $metricsHeaders | ConvertTo-Csv -NoTypeInformation } else { @($metricsHeaders -join ",") }
            Write-Response -Context $Context -StatusCode 200 -ContentType "text/csv; charset=utf-8" -Bytes $utf8NoBom.GetBytes(($csv -join [Environment]::NewLine))
        } elseif ($path -eq "/api/save-file" -and $Context.Request.HttpMethod -eq "POST") {
            if ($Context.Request.ContentLength64 -gt 52428800) {
                Write-Response -Context $Context -StatusCode 413 -ContentType "text/plain; charset=utf-8" -Bytes $utf8NoBom.GetBytes("Export is larger than 50 MB")
                return
            }
            $fileName = [System.IO.Path]::GetFileName([string]$Context.Request.QueryString["name"])
            if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = "inla-process-monitor-export.bin" }
            $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()
            $filter = switch ($extension) {
                ".csv" { "CSV files (*.csv)|*.csv|All files (*.*)|*.*" }
                ".png" { "PNG image (*.png)|*.png|All files (*.*)|*.*" }
                ".pdf" { "PDF files (*.pdf)|*.pdf|All files (*.*)|*.*" }
                default { "All files (*.*)|*.*" }
            }
            $memory = [System.IO.MemoryStream]::new()
            try {
                $Context.Request.InputStream.CopyTo($memory)
                $savedPath = Save-BytesWithUserDialog -Bytes $memory.ToArray() -SuggestedName $fileName -Filter $filter
            } finally {
                $memory.Dispose()
            }
            Write-JsonResponse -Context $Context -Object ([PSCustomObject]@{ saved = -not [string]::IsNullOrWhiteSpace($savedPath) })
        } else {
            Write-Response -Context $Context -StatusCode 404 -ContentType "text/plain; charset=utf-8" -Bytes $utf8NoBom.GetBytes("Not found")
        }
    } catch {
        try { Write-Response -Context $Context -StatusCode 500 -ContentType "text/plain; charset=utf-8" -Bytes $utf8NoBom.GetBytes($_.Exception.Message) } catch {}
    }
}

function Write-Report {
    $allRows = @(Import-Csv -LiteralPath $metricsPath -Encoding UTF8)
    $aggregates = @(Get-Aggregates -Rows $allRows)
    $summary = Get-Summary -Rows $allRows
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryJsonPath -Encoding UTF8
    $embeddedMetrics = ($allRows | ConvertTo-Json -Depth 8 -Compress)
    $runObject = Get-Content -LiteralPath $runJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $embeddedRun = ($runObject | ConvertTo-Json -Depth 8 -Compress)
    $embeddedSummary = ($summary | ConvertTo-Json -Depth 8 -Compress)
    $html = Get-Content -LiteralPath $dashboardSource -Raw -Encoding UTF8
    $html = $html.Replace("const embeddedMetrics = null;", "const embeddedMetrics = $embeddedMetrics;")
    $html = $html.Replace("const embeddedRun = null;", "const embeddedRun = $embeddedRun;")
    $html = $html.Replace("const embeddedSummary = null;", "const embeddedSummary = $embeddedSummary;")
    $html = $html.Replace('href="/metrics.csv"', 'href="metrics.csv"')
    $html | Set-Content -LiteralPath $reportPath -Encoding UTF8
    return $summary
}

function Write-LiveDashboard {
    $recentRows = @($script:historyRows.ToArray())
    if ($recentRows.Count -gt 9600) {
        $recentRows = @($recentRows | Select-Object -Last 9600)
    }
    $summary = Get-Summary -Rows $recentRows
    $runObject = Get-Content -LiteralPath $runJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $html = Get-Content -LiteralPath $dashboardSource -Raw -Encoding UTF8
    $html = $html.Replace("const embeddedMetrics = null;", ("const embeddedMetrics = {0};" -f ($recentRows | ConvertTo-Json -Depth 8 -Compress)))
    $html = $html.Replace("const embeddedRun = null;", ("const embeddedRun = {0};" -f ($runObject | ConvertTo-Json -Depth 8 -Compress)))
    $html = $html.Replace("const embeddedSummary = null;", ("const embeddedSummary = {0};" -f ($summary | ConvertTo-Json -Depth 8 -Compress)))
    $html = $html.Replace("const embeddedLive = false;", "const embeddedLive = true;")
    $html = $html.Replace('href="/metrics.csv"', 'href="metrics.csv"')
    $html | Set-Content -LiteralPath $livePath -Encoding UTF8
}

$runMetadata = [PSCustomObject]@{
    run_id = $safeRunId; label = $Label; process_name = $targetName; started_at = [DateTimeOffset]::Now.ToString("o")
    interval_seconds = $script:intervalSeconds; history_minutes = $HistoryMinutes; high_cpu_threshold = $HighCpuThreshold
    port = $Port; output_directory = $runFolder; host = $env:COMPUTERNAME; processor_count = $script:logicalProcessorCount
    logical_processor_count = $script:logicalProcessorCount; physical_core_count = $script:physicalCoreCount
    total_physical_memory_gb = Get-TotalPhysicalMemoryGb
    cpu_display_denominator = $script:logicalProcessorCount; cpu_display_method = "Task Manager Processor Utility adjusted from process CPU time"
}
$runMetadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runJsonPath -Encoding UTF8
Write-Event -Event "monitor_started" -ProcessId "" -Detail ("tracking {0}" -f $targetName)

$listener = $null
$script:pendingRequest = $null
$browserLaunched = $false
try {
    if (Test-Path -LiteralPath $dashboardSource) {
        try {
            $listener = [System.Net.HttpListener]::new()
            $listener.Prefixes.Add("http://127.0.0.1:$Port/")
            $listener.Start()
            $script:pendingRequest = $listener.GetContextAsync()
        } catch {
            Write-Warning ("The local dashboard could not start; CSV collection will continue: {0}" -f $_.Exception.Message)
            $listener = $null
        }
    }
    $url = "http://127.0.0.1:$Port/"
    Write-Host "BSTVC Monitor started for $targetName"
    Write-Host "Output: $runFolder"
    if ($listener) {
        Write-Host "Dashboard: $url"
        if (-not $NoBrowser) { Start-Process $url; $browserLaunched = $true }
    } else {
        Write-Host "Dashboard fallback: $livePath"
    }
    Write-Host "Press Ctrl+C to stop and write report."

    function Process-PendingHttpRequests {
        $processed = 0
        while ($listener -and $script:pendingRequest -and $script:pendingRequest.IsCompleted -and $processed -lt 8) {
            try {
                $context = $script:pendingRequest.Result
                $script:pendingRequest = $listener.GetContextAsync()
                Handle-HttpRequest -Context $context
            } catch {
                try { $script:pendingRequest = $listener.GetContextAsync() } catch { $script:pendingRequest = $null }
            }
            $processed++
        }
    }

    $nextSample = [DateTimeOffset]::Now
    $nextLiveDashboard = [DateTimeOffset]::Now
    while ($true) {
        Process-PendingHttpRequests
        if ($script:startNewRunRequested) { break }
        if ([DateTimeOffset]::Now -ge $nextSample) {
            Sample-Processes
            Process-PendingHttpRequests
            if ($script:startNewRunRequested) { break }
            if (-not $listener -and [DateTimeOffset]::Now -ge $nextLiveDashboard) {
                try { Write-LiveDashboard } catch { Write-Verbose ("live dashboard update failed: {0}" -f $_.Exception.Message) }
                $nextLiveDashboard = [DateTimeOffset]::Now.AddSeconds(10)
                if (-not $browserLaunched -and -not $NoBrowser -and (Test-Path -LiteralPath $livePath)) {
                    Start-Process $livePath
                    $browserLaunched = $true
                }
            }
            if ($Once -or ($MaxSamples -gt 0 -and $script:sampleCount -ge $MaxSamples)) { break }
            $nextSample = $nextSample.AddSeconds($script:intervalSeconds)
            if ($nextSample -lt [DateTimeOffset]::Now) { $nextSample = [DateTimeOffset]::Now.AddMilliseconds(50) }
        }
        Start-Sleep -Milliseconds 100
    }
} finally {
    try {
        if ($listener) { $listener.Stop(); $listener.Close() }
    } catch {}
    try {
        Write-Event -Event "monitor_stopped" -ProcessId "" -Detail ("samples={0}" -f $script:sampleCount)
    } catch {}
    try { $metricsWriter.Flush(); $metricsWriter.Dispose() } catch {}
    try { $eventsWriter.Flush(); $eventsWriter.Dispose() } catch {}
    if ($script:startNewRunRequested) {
        try {
            $replacement = Start-ReplacementMonitor
            Write-Host ("New monitoring run started: PID {0}" -f $replacement.Id)
        } catch {
            Write-Warning ("A new monitoring run could not be started: {0}" -f $_.Exception.Message)
        }
    }
    try {
        $finalSummary = Write-Report
        $runMetadata | Add-Member -NotePropertyName ended_at -NotePropertyValue ([DateTimeOffset]::Now.ToString("o")) -Force
        $runMetadata | Add-Member -NotePropertyName sample_count -NotePropertyValue $script:sampleCount -Force
        $runMetadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $runJsonPath -Encoding UTF8
        Write-Host "Report: $reportPath"
        Write-Host ("Samples: {0}; mean CPU: {1}; peak Working Set: {2} MB" -f $finalSummary.sample_count, $finalSummary.cpu_mean_pct_total, $finalSummary.working_set_peak_mb)
    } catch {
        Write-Warning ("The report could not be generated, but the raw logs were saved: {0}" -f $_.Exception.Message)
    }
}
