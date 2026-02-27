<#
========================================================================================================
    Title:          Win11Migrator - Winget Application Scanner
    Filename:       Get-WingetApps.ps1
    Description:    Discovers installed applications via the Windows Package Manager (winget) CLI.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Discovers installed applications via the Windows Package Manager (winget).
    Parses the tabular output of 'winget list' into structured MigrationApp objects.
#>

function Get-WingetApps {
    <#
    .SYNOPSIS
        Runs 'winget list' and parses its table output to discover installed packages.
    .OUTPUTS
        [MigrationApp[]] Array of discovered applications with Source='Winget'.
    #>
    [CmdletBinding()]
    [OutputType([MigrationApp[]])]
    param()

    Write-MigrationLog -Message "Starting winget application scan" -Level Info

    # Verify winget is available
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-MigrationLog -Message "winget is not installed or not in PATH - skipping winget scan" -Level Warning
        return [MigrationApp[]]@()
    }

    # Run winget list
    try {
        $rawOutput = & winget list --accept-source-agreements --disable-interactivity 2>&1
        $outputLines = $rawOutput | Out-String -Stream | Where-Object { $_ -is [string] }
    }
    catch {
        Write-MigrationLog -Message "Failed to execute winget list: $($_.Exception.Message)" -Level Error
        return [MigrationApp[]]@()
    }

    if (-not $outputLines -or $outputLines.Count -eq 0) {
        Write-MigrationLog -Message "winget list returned no output" -Level Warning
        return [MigrationApp[]]@()
    }

    # Find the header separator line (a line of dashes) to determine column positions
    $headerLineIndex = -1
    $separatorIndex = -1
    for ($i = 0; $i -lt $outputLines.Count; $i++) {
        $line = $outputLines[$i]
        if ($line -match '^-{3,}') {
            $separatorIndex = $i
            $headerLineIndex = $i - 1
            break
        }
    }

    if ($separatorIndex -lt 0 -or $headerLineIndex -lt 0) {
        Write-MigrationLog -Message "Could not parse winget list output - header separator not found" -Level Warning
        return [MigrationApp[]]@()
    }

    # Parse column positions from the header line
    $headerLine = $outputLines[$headerLineIndex]

    # Detect column start positions by finding known header keywords
    $nameStart    = 0
    $idStart      = $headerLine.IndexOf('Id')
    $versionStart = $headerLine.IndexOf('Version')
    $sourceStart  = $headerLine.IndexOf('Source')

    # Fallback: if we cannot find Id column, try alternate header
    if ($idStart -lt 0) {
        Write-MigrationLog -Message "Could not identify column positions in winget output" -Level Warning
        return [MigrationApp[]]@()
    }

    $apps = [System.Collections.Generic.List[MigrationApp]]::new()

    # Parse data lines after the separator
    for ($i = $separatorIndex + 1; $i -lt $outputLines.Count; $i++) {
        $line = $outputLines[$i]

        # Skip empty lines, progress indicators, and summary lines
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\d+ (upgrades|packages)') { continue }
        if ($line.Length -lt $idStart + 2) { continue }

        # Extract fields by column positions
        $appName = ''
        $appId   = ''
        $appVer  = ''
        $appSrc  = ''

        try {
            if ($idStart -gt 0) {
                $appName = $line.Substring($nameStart, [Math]::Min($idStart, $line.Length)).TrimEnd()
            }
            if ($versionStart -gt $idStart -and $line.Length -gt $idStart) {
                $idLen = $versionStart - $idStart
                $appId = $line.Substring($idStart, [Math]::Min($idLen, $line.Length - $idStart)).TrimEnd()
            }
            if ($versionStart -gt 0 -and $line.Length -gt $versionStart) {
                if ($sourceStart -gt $versionStart) {
                    $verLen = $sourceStart - $versionStart
                    $appVer = $line.Substring($versionStart, [Math]::Min($verLen, $line.Length - $versionStart)).TrimEnd()
                }
                else {
                    $appVer = $line.Substring($versionStart).TrimEnd()
                }
            }
            if ($sourceStart -gt 0 -and $line.Length -gt $sourceStart) {
                $appSrc = $line.Substring($sourceStart).TrimEnd()
            }
        }
        catch {
            Write-MigrationLog -Message "Could not parse winget line: $line" -Level Debug
            continue
        }

        # Skip entries without a name or ID
        if ([string]::IsNullOrWhiteSpace($appName) -or [string]::IsNullOrWhiteSpace($appId)) {
            continue
        }

        $normalizedName = Get-NormalizedAppName -Name $appName

        $app = [MigrationApp]::new()
        $app.Name              = $appName.Trim()
        $app.NormalizedName    = $normalizedName
        $app.Version           = $appVer.Trim()
        $app.Publisher         = ''
        $app.InstallLocation   = ''
        $app.UninstallString   = ''
        $app.Source            = 'Winget'
        $app.InstallMethod     = 'Winget'
        $app.PackageId         = $appId.Trim()
        $app.DownloadUrl       = ''
        $app.MatchConfidence   = 1.0
        $app.Selected          = $true
        $app.InstallStatus     = 'Pending'
        $app.InstallError      = ''

        $apps.Add($app)
    }

    Write-MigrationLog -Message "Winget scan complete: found $($apps.Count) applications" -Level Info
    return [MigrationApp[]]$apps.ToArray()
}
