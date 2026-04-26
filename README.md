# periodic-windows-log-cleanup

PowerShell script to back up and clean common Windows logs on a periodic basis.

Features
- Back up and compress file-based logs and Event Logs to a single `BackupRoot`.
- Prune backups older than a configurable retention (default: 90 days).
- Supports `ReportOnly` (size analysis) and `DryRun` (no changes).
- `DebugMode` for detailed debugging (line numbers and call stacks).
- Optional `SanityFix` to remove orphaned Event Log registry keys.
- Exclude specific file paths or Event Logs via `ExcludePaths` / `ExcludeEventLogs`.
- Suitable for use as a Scheduled Task (non-interactive).

Files in this repo
- `Clean-Logs.ps1` — main script.
- `CleanLogsTask.xml` — example Task Scheduler XML to import a scheduled task.

Quick usage
- Manual (interactive / elevated PowerShell):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\Clean-Logs.ps1" -BackupRoot "D:\LogBackups"

- With options:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\Clean-Logs.ps1" -BackupRoot "D:\LogBackups" -RetentionDays 60 -DryRun

Parameters
- `-BackupRoot` (string, required): Root folder where backups and script logs are stored. The script creates subfolders `FileLogs`, `EventLogs` and `ScriptLogs`.
- `-RetentionDays` (int, default: `90`): Number of days to keep backup ZIPs.
- `-DryRun` (switch): Log actions but make no changes.
- `-ReportOnly` (switch): Scan and report total reclaimable size; no changes.
- `-DebugMode` (switch): Enable detailed debug logging (invocation line numbers and stack).
- `-SanityFix` (switch): Attempt to remove orphaned event log registry keys (requires elevation).
- `-ExcludePaths` (string[]): Paths to skip when scanning file-based logs.
- `-ExcludeEventLogs` (string[]): Event log names to skip when exporting/clearing.

Notes and recommendations
- The script requires administrative privileges to export/clear Event Logs and to remove registry keys with `SanityFix`. Run elevated when using `EventLogs` or `SanityFix`.
- `DryRun` and `ReportOnly` are safe ways to validate behavior before making changes.
- Backups are created as ZIP files named by source and timestamp. The script logs activity to `BackupRoot\ScriptLogs\LogCleanup_<timestamp>.log`.
- The script excludes non-log file extensions and also skips `CBS.log` by default (it's handled separately in code).

Using the provided Task Scheduler XML
- Import with Task Scheduler GUI:
  1. Open Task Scheduler.
  2. Action → Import Task…
  3. Select `CleanLogsTask.xml` and adjust paths/credentials as needed.

- Import with PowerShell:
  powershell -Command "Register-ScheduledTask -TaskName 'Clean-Logs' -Xml (Get-Content .\CleanLogsTask.xml -Raw)"

The example `CleanLogsTask.xml` in this repo runs monthly (every 4 weeks on Sunday at 03:00) and uses:
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UserProfile%\Scripts\Clean-Logs.ps1" -BackupRoot "D:\LogBackups"`

Troubleshooting
- Use `-DryRun` first to confirm what will be changed.
- Enable `-DebugMode` to get line numbers and stack traces in the script log when errors occur.
- Check the script log in `BackupRoot\ScriptLogs` for details.

License
- This project is licensed under the terms of GPL-3.0, the GNU General Public License v3.0.
