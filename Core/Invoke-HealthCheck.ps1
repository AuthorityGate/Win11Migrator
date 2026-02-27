<#
========================================================================================================
    Title:          Win11Migrator - Post-Migration Health Check
    Filename:       Invoke-HealthCheck.ps1
    Description:    Runs a comprehensive verification of all migrated items and reports a health score.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 27, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Comprehensive post-migration health check to verify all migrated items are intact.
.DESCRIPTION
    Validates installed apps, user data, WiFi profiles, printers, mapped drives,
    browser bookmarks, environment variables, disk space, and pending reboots.
    Each check produces a Pass/Fail/Warning result and the overall migration gets
    a health score from 0-100.
.PARAMETER Manifest
    The MigrationManifest object from the completed import.
.PARAMETER OutputFile
    Optional path to save the health check report as JSON.
.OUTPUTS
    [hashtable] with Checks array, counts, Score, and Timestamp.
#>

function Invoke-HealthCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [MigrationManifest]$Manifest,

        [Parameter()]
        [string]$OutputFile
    )

    Write-MigrationLog -Message "Starting post-migration health check" -Level Info

    $checks = @()

    # --- 1. Verify installed apps ---
    Write-MigrationLog -Message "Health check: verifying installed applications" -Level Debug

    # Build a lookup of installed programs from the registry
    $installedApps = @()
    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($regPath in $uninstallPaths) {
        try {
            $items = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
                     Where-Object { $_.DisplayName } |
                     Select-Object -ExpandProperty DisplayName
            $installedApps += @($items)
        }
        catch {
            # Registry path may not exist
        }
    }
    $installedAppsLower = $installedApps | ForEach-Object { $_.ToLower() }

    # Also check winget list if available
    $wingetApps = @()
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            $wingetOutput = & winget list --disable-interactivity 2>$null
            if ($wingetOutput) {
                $wingetApps = @($wingetOutput)
            }
        }
        catch {
            # winget may not be available
        }
    }

    $successApps = @($Manifest.Apps | Where-Object { $_.InstallStatus -eq 'Success' })
    foreach ($app in $successApps) {
        $appName = if ($app.NormalizedName) { $app.NormalizedName } else { $app.Name }
        $found = $false

        # Check registry
        foreach ($installed in $installedAppsLower) {
            if ($installed -like "*$($appName.ToLower())*") {
                $found = $true
                break
            }
        }

        # Check winget output
        if (-not $found -and $wingetApps.Count -gt 0) {
            foreach ($line in $wingetApps) {
                if ($line -and $line.ToLower() -like "*$($appName.ToLower())*") {
                    $found = $true
                    break
                }
            }
        }

        # Check Get-Command for CLI tools
        if (-not $found) {
            $cmdName = ($appName -replace '\s+', '' -replace '[^a-zA-Z0-9]', '').ToLower()
            if (Get-Command $cmdName -ErrorAction SilentlyContinue) {
                $found = $true
            }
        }

        $checks += @{
            Name     = "App: $($app.Name)"
            Category = 'Applications'
            Status   = if ($found) { 'Pass' } else { 'Fail' }
            Detail   = if ($found) { "Verified installed" } else { "Not found in registry, winget, or PATH" }
        }
    }

    # --- 2. Verify user data ---
    Write-MigrationLog -Message "Health check: verifying user data" -Level Debug

    $successData = @($Manifest.UserData | Where-Object { $_.ExportStatus -eq 'Success' })
    foreach ($item in $successData) {
        $targetPath = $item.SourcePath  # On the target machine, the source path is the restore location

        if (Test-Path $targetPath) {
            $fileCount = @(Get-ChildItem -Path $targetPath -Recurse -File -ErrorAction SilentlyContinue).Count

            $checks += @{
                Name     = "UserData: $($item.Category)"
                Category = 'UserData'
                Status   = if ($fileCount -gt 0) { 'Pass' } else { 'Warning' }
                Detail   = if ($fileCount -gt 0) { "$fileCount files present" } else { "Folder exists but is empty" }
            }
        }
        else {
            $checks += @{
                Name     = "UserData: $($item.Category)"
                Category = 'UserData'
                Status   = 'Fail'
                Detail   = "Target folder does not exist: $targetPath"
            }
        }
    }

    # --- 3. Verify WiFi profiles ---
    Write-MigrationLog -Message "Health check: verifying WiFi profiles" -Level Debug

    $wifiSettings = @($Manifest.SystemSettings | Where-Object { $_.Category -eq 'WiFi' -and $_.ExportStatus -eq 'Success' })
    if ($wifiSettings.Count -gt 0) {
        $wifiProfiles = @()
        try {
            $netshOutput = & netsh wlan show profiles 2>$null
            if ($netshOutput) {
                $wifiProfiles = @($netshOutput | Where-Object { $_ -match 'All User Profile\s*:\s*(.+)' } | ForEach-Object { $Matches[1].Trim() })
            }
        }
        catch {
            # netsh may fail if no wireless adapter
        }

        foreach ($wifi in $wifiSettings) {
            $wifiName = $wifi.Name
            $found = $wifiProfiles -contains $wifiName

            $checks += @{
                Name     = "WiFi: $wifiName"
                Category = 'WiFi'
                Status   = if ($found) { 'Pass' } else { 'Fail' }
                Detail   = if ($found) { "Profile present" } else { "WiFi profile not found" }
            }
        }
    }

    # --- 4. Verify printers ---
    Write-MigrationLog -Message "Health check: verifying printers" -Level Debug

    $printerSettings = @($Manifest.SystemSettings | Where-Object { $_.Category -eq 'Printer' -and $_.ExportStatus -eq 'Success' })
    if ($printerSettings.Count -gt 0) {
        $installedPrinters = @()
        try {
            $installedPrinters = @(Get-Printer -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        }
        catch {
            # Get-Printer may not be available
        }

        foreach ($printer in $printerSettings) {
            $printerName = $printer.Name
            $found = $installedPrinters -contains $printerName

            $checks += @{
                Name     = "Printer: $printerName"
                Category = 'Printers'
                Status   = if ($found) { 'Pass' } else { 'Warning' }
                Detail   = if ($found) { "Printer installed" } else { "Printer not found (may require driver installation)" }
            }
        }
    }

    # --- 5. Verify mapped drives ---
    Write-MigrationLog -Message "Health check: verifying mapped drives" -Level Debug

    $driveSettings = @($Manifest.SystemSettings | Where-Object { $_.Category -eq 'MappedDrive' -and $_.ExportStatus -eq 'Success' })
    if ($driveSettings.Count -gt 0) {
        $currentDrives = @()
        try {
            $currentDrives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        }
        catch {
            # Unlikely to fail
        }

        foreach ($drive in $driveSettings) {
            $driveLetter = $drive.Name
            $found = $currentDrives -contains $driveLetter

            $checks += @{
                Name     = "MappedDrive: ${driveLetter}:"
                Category = 'MappedDrives'
                Status   = if ($found) { 'Pass' } else { 'Fail' }
                Detail   = if ($found) { "Drive mapped" } else { "Drive letter not found (network may be unavailable)" }
            }
        }
    }

    # --- 6. Verify browser bookmarks ---
    Write-MigrationLog -Message "Health check: verifying browser profiles" -Level Debug

    $successBrowsers = @($Manifest.BrowserProfiles | Where-Object { $_.ExportStatus -eq 'Success' })
    foreach ($bp in $successBrowsers) {
        $bookmarkFile = $null
        switch ($bp.Browser) {
            'Chrome'  { $bookmarkFile = Join-Path $bp.ProfilePath 'Bookmarks' }
            'Edge'    { $bookmarkFile = Join-Path $bp.ProfilePath 'Bookmarks' }
            'Brave'   { $bookmarkFile = Join-Path $bp.ProfilePath 'Bookmarks' }
            'Firefox' { $bookmarkFile = Join-Path $bp.ProfilePath 'places.sqlite' }
        }

        if ($bookmarkFile -and (Test-Path $bookmarkFile)) {
            $checks += @{
                Name     = "Browser: $($bp.Browser) - $($bp.ProfileName)"
                Category = 'BrowserProfiles'
                Status   = 'Pass'
                Detail   = "Bookmark file present"
            }
        }
        else {
            $checks += @{
                Name     = "Browser: $($bp.Browser) - $($bp.ProfileName)"
                Category = 'BrowserProfiles'
                Status   = 'Warning'
                Detail   = "Bookmark file not found at expected path"
            }
        }
    }

    # --- 7. Verify environment variables ---
    Write-MigrationLog -Message "Health check: verifying environment variables" -Level Debug

    $envSettings = @($Manifest.SystemSettings | Where-Object { $_.Category -eq 'EnvVar' -and $_.ExportStatus -eq 'Success' })
    foreach ($envSetting in $envSettings) {
        $envName = $envSetting.Name
        $expectedValue = $null
        if ($envSetting.Data -and $envSetting.Data.ContainsKey('Value')) {
            $expectedValue = $envSetting.Data['Value']
        }

        $currentValue = [System.Environment]::GetEnvironmentVariable($envName, 'User')

        if ($null -ne $currentValue) {
            if ($expectedValue -and $currentValue -eq $expectedValue) {
                $checks += @{
                    Name     = "EnvVar: $envName"
                    Category = 'EnvironmentVariables'
                    Status   = 'Pass'
                    Detail   = "Value matches"
                }
            }
            else {
                $checks += @{
                    Name     = "EnvVar: $envName"
                    Category = 'EnvironmentVariables'
                    Status   = 'Warning'
                    Detail   = "Variable exists but value differs"
                }
            }
        }
        else {
            $checks += @{
                Name     = "EnvVar: $envName"
                Category = 'EnvironmentVariables'
                Status   = 'Fail'
                Detail   = "Environment variable not found"
            }
        }
    }

    # --- 8. Disk space check ---
    Write-MigrationLog -Message "Health check: verifying disk space" -Level Debug

    try {
        $systemDrive = $env:SystemDrive
        if (-not $systemDrive) { $systemDrive = 'C:' }
        $drive = Get-PSDrive -Name ($systemDrive.TrimEnd(':')) -ErrorAction Stop
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        $totalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 2)
        $freePercent = if ($totalGB -gt 0) { [math]::Round(($freeGB / $totalGB) * 100, 1) } else { 0 }

        $diskStatus = 'Pass'
        $diskDetail = "$freeGB GB free ($freePercent% of $totalGB GB)"
        if ($freeGB -lt 5 -or $freePercent -lt 10) {
            $diskStatus = 'Warning'
            $diskDetail = "Low disk space: $freeGB GB free ($freePercent%)"
        }
        if ($freeGB -lt 1) {
            $diskStatus = 'Fail'
            $diskDetail = "Critical: only $freeGB GB free"
        }

        $checks += @{
            Name     = "Disk Space: $systemDrive"
            Category = 'System'
            Status   = $diskStatus
            Detail   = $diskDetail
        }
    }
    catch {
        $checks += @{
            Name     = "Disk Space"
            Category = 'System'
            Status   = 'Warning'
            Detail   = "Could not check disk space: $($_.Exception.Message)"
        }
    }

    # --- 9. Pending reboots ---
    Write-MigrationLog -Message "Health check: checking for pending reboots" -Level Debug

    $pendingReboot = $false
    $rebootReasons = @()

    # Check Component Based Servicing
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $pendingReboot = $true
        $rebootReasons += 'Component Based Servicing'
    }

    # Check Windows Update
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $pendingReboot = $true
        $rebootReasons += 'Windows Update'
    }

    # Check pending file rename operations
    try {
        $pfro = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($pfro -and $pfro.PendingFileRenameOperations) {
            $pendingReboot = $true
            $rebootReasons += 'Pending File Rename'
        }
    }
    catch {
        # Not present
    }

    $checks += @{
        Name     = "Pending Reboot"
        Category = 'System'
        Status   = if ($pendingReboot) { 'Warning' } else { 'Pass' }
        Detail   = if ($pendingReboot) { "Reboot required: $($rebootReasons -join ', ')" } else { "No pending reboot" }
    }

    # --- Calculate overall score ---
    $totalChecks = $checks.Count
    $passed  = @($checks | Where-Object { $_.Status -eq 'Pass' }).Count
    $failed  = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count
    $warned  = @($checks | Where-Object { $_.Status -eq 'Warning' }).Count

    # Score: Pass = 1.0, Warning = 0.5, Fail = 0.0
    $scorePoints = $passed + ($warned * 0.5)
    $score = if ($totalChecks -gt 0) { [math]::Round(($scorePoints / $totalChecks) * 100, 1) } else { 100.0 }

    Write-MigrationLog -Message "Health check complete: $passed passed, $failed failed, $warned warnings. Score: $score/100" -Level Info

    $result = @{
        Checks      = $checks
        TotalChecks = $totalChecks
        Passed      = $passed
        Failed      = $failed
        Warnings    = $warned
        Score       = $score
        Timestamp   = (Get-Date).ToUniversalTime().ToString('o')
    }

    # Save to file if requested
    if ($OutputFile) {
        try {
            $outputDir = Split-Path $OutputFile -Parent
            if ($outputDir -and -not (Test-Path $outputDir)) {
                New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
            }
            $result | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8 -Force
            Write-MigrationLog -Message "Health check report saved to: $OutputFile" -Level Info
        }
        catch {
            Write-MigrationLog -Message "Failed to save health check report: $($_.Exception.Message)" -Level Warning
        }
    }

    return $result
}
