<#
.SYNOPSIS
  Backup and clean Windows logs (temp, CBS, WER, setup, Windows Update cache, Event Logs).

.DESCRIPTION
  - Backs up logs to a single root folder
  - Zips each backup
  - Prunes backups older than configurable retention (default 90 days)
  - Supports ReportOnly (size analysis) and DryRun (no changes)
  - Supports DebugMode (line numbers + call stack)
  - Tracks broken/ghost event logs
  - Optional orphan cleanup (registry only)
  - Suitable for Scheduled Task use (no prompts)

.PARAMETER BackupRoot
  Root folder where all backups (including Event Logs) are stored.

.PARAMETER RetentionDays
  Number of days to keep backup ZIPs.

.PARAMETER DryRun
  If set, no changes are made; actions are logged as "would do".

.PARAMETER ReportOnly
  If set, no changes are made; only size of deletable logs is reported.

.PARAMETER DebugMode
  Enables detailed debug logging (line numbers, call stack, exception info).

.PARAMETER SanityFix
  Attempts to remove orphaned event log registry keys (safe, optional).

.PARAMETER ExcludePaths
  Array of paths to exclude from file-based log cleanup.

.PARAMETER ExcludeEventLogs
  Array of event log names to exclude from event log backup/cleanup.

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupRoot,

    [int]$RetentionDays = 90,

    [switch]$DryRun,
    [switch]$ReportOnly,
    [switch]$DebugMode,
    [switch]$SanityFix,

    [string[]]$ExcludePaths = @(),
    [string[]]$ExcludeEventLogs = @()
)

$ErrorActionPreference = 'Stop'

# ---------------------------
# INITIAL SETUP & LOGGING
# ---------------------------

if (-not (Test-Path $BackupRoot)) {
    if ($DryRun -or $ReportOnly) {
        Write-Host "[DRY/REPORT] Would create backup root: $BackupRoot"
    } else {
        New-Item -ItemType Directory -Path $BackupRoot | Out-Null
    }
}

$LogDir = Join-Path $BackupRoot "ScriptLogs"
if (-not (Test-Path $LogDir)) {
    if ($DryRun -or $ReportOnly) {
        Write-Host "[DRY/REPORT] Would create log directory: $LogDir"
    } else {
        New-Item -ItemType Directory -Path $LogDir | Out-Null
    }
}
$LogFile = Join-Path $LogDir ("LogCleanup_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    if (-not $DryRun -and -not $ReportOnly) {
        Add-Content -Path $LogFile -Value $line
    }
}

function Write-DebugInfo {
    param($ex)

    if (-not $DebugMode) { return }

    # Normalize ErrorRecord → Exception
    if ($ex -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ex.Exception
    } else {
        $exception = $ex
    }

    $line  = $exception.InvocationInfo.ScriptLineNumber
    $stack = $exception.ScriptStackTrace
    $msg   = $exception.Message
    $type  = $exception.GetType().FullName

    Write-Log "[DEBUG] Error at line $line" "DEBUG"
    Write-Log "[DEBUG] Call stack: $stack" "DEBUG"
    Write-Log "[DEBUG] Exception type: $type" "DEBUG"
    Write-Log "[DEBUG] Message: $msg" "DEBUG"
}

Write-Log "=== Log cleanup started. DryRun=$DryRun, ReportOnly=$ReportOnly, DebugMode=$DebugMode, RetentionDays=$RetentionDays ==="

# ---------------------------
# HELPER FUNCTIONS
# ---------------------------

function New-SafeDirectory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        if ($DryRun -or $ReportOnly) {
            Write-Log "[DRY/REPORT] Would create directory: $Path"
        } else {
            New-Item -ItemType Directory -Path $Path | Out-Null
            Write-Log "Created directory: $Path"
        }
    }
}

function Get-SizeReadable {
    param([long]$Bytes)

    switch ($Bytes) {
        {$_ -ge 1TB} { return "{0:N2} TB" -f ($Bytes / 1TB) }
        {$_ -ge 1GB} { return "{0:N2} GB" -f ($Bytes / 1GB) }
        {$_ -ge 1MB} { return "{0:N2} MB" -f ($Bytes / 1MB) }
        {$_ -ge 1KB} { return "{0:N2} KB" -f ($Bytes / 1KB) }
        default      { return "$Bytes bytes" }
    }
}

function Compress-And-RemoveFile {
    param(
        [System.IO.FileInfo]$File,
        [string]$DestinationRoot
    )

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeName = $File.Name.Replace(" ", "_")
    $zipName  = "{0}_{1}.zip" -f $safeName, $timestamp
    $zipPath  = Join-Path $DestinationRoot $zipName

    $tempDirName = "LogBackup_{0}_{1}" -f $safeName, $timestamp
    $tempDir = Join-Path $env:TEMP $tempDirName

    try {
        if ($DryRun) {
            Write-Log "[DRY-RUN] Would create temp dir: $tempDir"
            Write-Log "[DRY-RUN] Would copy $($File.FullName) to $tempDir"
            Write-Log "[DRY-RUN] Would compress to $zipPath"
            Write-Log "[DRY-RUN] Would delete original file: $($File.FullName)"
        } else {
            New-SafeDirectory -Path $tempDir
            Copy-Item -Path $File.FullName -Destination $tempDir -Force
            Compress-Archive -Path (Join-Path $tempDir '*') -DestinationPath $zipPath -Force
            Remove-Item -Path $tempDir -Recurse -Force
            Remove-Item -Path $File.FullName -Force
            Write-Log "Backed up and removed file: $($File.FullName) -> $zipPath"
        }
    }
    catch {
        Write-Log ("Failed to process file {0}: {1}" -f $File.FullName, $_) "ERROR"
        Write-DebugInfo $_
    }
}

function Is-SafeLogFile {
    param([System.IO.FileInfo]$File)

    if ($File.Extension -notin ".log", ".txt", ".dmp", ".etl") {
        return $false
    }

    if ($File.FullName -match "CBS\.log$") {
        return $false
    }

    return $true
}

function Path-IsExcluded {
    param(
        [string]$Path,
        [string[]]$Exclusions
    )

    foreach ($ex in $Exclusions) {
        if ([string]::IsNullOrWhiteSpace($ex)) { continue }
        if ($Path.TrimEnd('\') -like "$($ex.TrimEnd('\'))*") {
            return $true
        }
    }
    return $false
}

# ---------------------------
# LOG PATHS
# ---------------------------

$LogPaths = @(
    "C:\Windows\Temp",
    "$env:TEMP",
    "C:\Windows\Logs\CBS",
    "C:\Windows\SoftwareDistribution\Download",
    "C:\ProgramData\Microsoft\Windows\WER",
    "C:\Windows\Panther",
    "C:\$WINDOWS.~BT"
)

# ---------------------------
# REPORT-ONLY MODE
# ---------------------------

if ($ReportOnly) {
    Write-Log "=== REPORT-ONLY MODE: No files will be backed up, zipped, or deleted ==="

    $Report = [ordered]@{
        TempLogs    = 0L
        CBSLogs     = 0L
        WERLogs     = 0L
        SetupLogs   = 0L
        UpdateCache = 0L
        EventLogs   = 0L
        Total       = 0L
    }

    foreach ($Path in $LogPaths) {
        if (-not (Test-Path $Path)) { continue }
        if (Path-IsExcluded -Path $Path -Exclusions $ExcludePaths) { continue }

        try {
            $files = Get-ChildItem -Path $Path -File -Recurse -ErrorAction SilentlyContinue |
                     Where-Object { Is-SafeLogFile $_ }

            $size = ($files | Measure-Object -Property Length -Sum).Sum
            if (-not $size) { $size = 0 }

            switch -Wildcard ($Path) {
                "*Temp*"                  { $Report.TempLogs    += $size }
                "*Logs\CBS*"              { $Report.CBSLogs     += $size }
                "*ProgramData*\WER*"      { $Report.WERLogs     += $size }
                "*Panther*"               { $Report.SetupLogs   += $size }
                "*SoftwareDistribution*"  { $Report.UpdateCache += $size }
            }

            $Report.Total += $size
        }
        catch {
            Write-Log ("Error while scanning path {0}: {1}" -f $Path, $_) "ERROR"
            Write-DebugInfo $_
        }
    }

    try {
        $EventLogs = wevtutil el
    }
    catch {
        Write-Log "Failed to enumerate event logs in report-only mode: $_" "ERROR"
        Write-DebugInfo $_
        $EventLogs = @()
    }

    foreach ($LogName in $EventLogs) {
        if ($ExcludeEventLogs -contains $LogName) { continue }

        try {
            $info = wevtutil gl "$LogName" 2>&1

            if ($info -match "Failed to read configuration") {
                Write-Log "Skipping ghost event log: $LogName" "WARN"
                continue
            }

            if ($info -match "file size:\s*(\d+)") {
                $bytes = [long]$matches[1]
                $Report.EventLogs += $bytes
                $Report.Total     += $bytes
            }
        }
        catch {
            Write-Log ("Failed to query size for event log '{0}': {1}" -f $LogName, $_) "ERROR"
            Write-DebugInfo $_
        }
    }

    Write-Host ""
    Write-Host "===== REPORT SUMMARY ====="
    foreach ($key in $Report.Keys) {
        Write-Host ("{0,-15}: {1}" -f $key, (Get-SizeReadable $Report[$key]))
    }
    Write-Host "=========================="

    Write-Log "Report-only mode completed."
    Write-Log "=== Log cleanup finished (report-only). ==="
    exit
}

# ---------------------------
# FILE-BASED LOG CLEANUP
# ---------------------------

$FileLogBackupRoot = Join-Path $BackupRoot "FileLogs"
New-SafeDirectory -Path $FileLogBackupRoot

foreach ($Path in $LogPaths) {
    if (-not (Test-Path $Path)) {
        Write-Log "Path does not exist, skipping: $Path"
        continue
    }

    if (Path-IsExcluded -Path $Path -Exclusions $ExcludePaths) {
        Write-Log "Path excluded by user, skipping: $Path"
        continue
    }

    Write-Log "Processing path: $Path"

    try {
        Get-ChildItem -Path $Path -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { Is-SafeLogFile $_ } |
            ForEach-Object {
                Compress-And-RemoveFile -File $_ -DestinationRoot $FileLogBackupRoot
            }
    }
    catch {
        Write-Log ("Error while processing path {0}: {1}" -f $Path, $_) "ERROR"
        Write-DebugInfo $_
    }
}

# ---------------------------
# EVENT LOG BACKUP & CLEANUP
# ---------------------------

$EventBackupRoot = Join-Path $BackupRoot "EventLogs"
New-SafeDirectory -Path $EventBackupRoot

$BrokenEventLogs = @()

try {
    $EventLogs = wevtutil el
}
catch {
    Write-Log "Failed to enumerate event logs: $_" "ERROR"
    Write-DebugInfo $_
    $EventLogs = @()
}

foreach ($LogName in $EventLogs) {

    if ($ExcludeEventLogs -contains $LogName) {
        Write-Log "Event log excluded by user, skipping: $LogName"
        continue
    }

    $safeName  = ($LogName -replace '[\\/:*?"<>|]', '_')
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $evtxPath  = Join-Path $EventBackupRoot ("{0}_{1}.evtx" -f $safeName, $timestamp)
    $zipPath   = "$evtxPath.zip"

    try {
        $info = wevtutil gl "$LogName" 2>&1

        if ($info -match "Failed to read configuration") {
            Write-Log "Skipping ghost/broken event log: $LogName" "WARN"
            $BrokenEventLogs += $LogName
            continue
        }

        if ($DryRun) {
            Write-Log "[DRY-RUN] Would export event log '$LogName' to $evtxPath"
            Write-Log "[DRY-RUN] Would compress $evtxPath to $zipPath"
            Write-Log "[DRY-RUN] Would delete $evtxPath"
            Write-Log "[DRY-RUN] Would clear event log '$LogName'"
        } else {
            wevtutil epl "$LogName" "$evtxPath"
            Compress-Archive -Path $evtxPath -DestinationPath $zipPath -Force
            Remove-Item $evtxPath -Force
            wevtutil cl "$LogName"
            Write-Log "Backed up and cleared event log: $LogName -> $zipPath"
        }
    }
    catch {
        Write-Log ("Failed to process event log '{0}': {1}" -f $LogName, $_) "ERROR"
        Write-DebugInfo $_
        $BrokenEventLogs += $LogName
        continue
    }
}

# ---------------------------
# OPTIONAL SANITY FIX
# ---------------------------

if ($SanityFix -and $BrokenEventLogs.Count -gt 0) {
    Write-Log "SanityFix enabled. Attempting to remove orphaned registry keys."

    foreach ($LogName in $BrokenEventLogs) {
        try {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog"
            $key = Get-ChildItem $regPath -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match [regex]::Escape($LogName) }

            if ($key) {
                Write-Log "Removing orphaned event log registry key: $($key.Name)" "WARN"
                if (-not $DryRun) {
                    Remove-Item -Path $key.PSPath -Recurse -Force
                }
            } else {
                Write-Log "No registry key found for orphaned log: $LogName"
            }
        }
        catch {
            Write-Log ("Failed to remove orphaned registry key for '{0}': {1}" -f $LogName, $_) "ERROR"
            Write-DebugInfo $_
        }
    }
}

# ---------------------------
# RETENTION CLEANUP
# ---------------------------

$Cutoff = (Get-Date).AddDays(-$RetentionDays)
Write-Log "Pruning backups older than $RetentionDays days (before $Cutoff)."

function Prune-OldZips {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return }

    try {
        Get-ChildItem -Path $Path -Filter *.zip -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $Cutoff } |
            ForEach-Object {
                if ($DryRun) {
                    Write-Log "[DRY-RUN] Would delete old backup: $($_.FullName)"
                } else {
                    Remove-Item $_.FullName -Force
                    Write-Log "Deleted old backup: $($_.FullName)"
                }
            }
    }
    catch {
        Write-Log ("Error during retention cleanup in {0}: {1}" -f $Path, $_) "ERROR"
        Write-DebugInfo $_
    }
}

Prune-OldZips -Path $BackupRoot

# ---------------------------
# FINAL SUMMARY
# ---------------------------

if ($BrokenEventLogs.Count -gt 0) {
    Write-Log "Broken or ghost event logs detected:" "WARN"
    foreach ($log in $BrokenEventLogs) {
        Write-Log " - $log" "WARN"
    }
}

Write-Log "=== Log cleanup completed. ==="
