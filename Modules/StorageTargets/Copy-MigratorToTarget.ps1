<#
========================================================================================================
    Title:          Win11Migrator - Copy Migrator To Target
    Filename:       Copy-MigratorToTarget.ps1
    Description:    Copies the Win11Migrator tool itself alongside a migration package so it can
                    run directly on the target machine without separate installation.
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
    Copies Win11Migrator to a target directory so it can run on the target machine.
.DESCRIPTION
    Uses Robocopy /MIR to copy the essential Win11Migrator files (scripts, config, modules, GUI,
    reports) to a target base path. Excludes non-essential directories like MigrationPackage, Build,
    .git, and Tests. Skips the copy if the target already has the same or newer version.
.PARAMETER TargetBasePath
    The target directory where Win11Migrator files should be placed. For example,
    "E:\Win11Migrator" or "\\PC\C$\Users\john\Win11Migrator".
.OUTPUTS
    [PSCustomObject] With TargetPath, FileCount, TotalSizeMB, and Skipped properties.
.EXAMPLE
    Copy-MigratorToTarget -TargetBasePath "E:\Win11Migrator"
#>

function Copy-MigratorToTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetBasePath
    )

    Write-MigrationLog -Message "Bundling Win11Migrator tool to: $TargetBasePath" -Level Info

    # Check if target already has the same or newer version
    $sourceVersion = if ($script:MigratorVersion) { $script:MigratorVersion } else { '0.0.0' }
    $targetVersionFile = Join-Path $TargetBasePath 'Win11Migrator.ps1'

    if (Test-Path $targetVersionFile) {
        try {
            $targetContent = Get-Content $targetVersionFile -TotalCount 80 -ErrorAction SilentlyContinue
            $targetVersionLine = $targetContent | Where-Object { $_ -match "MigratorVersion\s*=\s*'([^']+)'" }
            if ($targetVersionLine -and $Matches[1]) {
                $targetVersion = $Matches[1]
                if ([version]$targetVersion -ge [version]$sourceVersion) {
                    Write-MigrationLog -Message "Target already has Win11Migrator v$targetVersion (source: v$sourceVersion) - skipping tool copy" -Level Info
                    return [PSCustomObject]@{
                        TargetPath  = $TargetBasePath
                        FileCount   = 0
                        TotalSizeMB = 0
                        Skipped     = $true
                    }
                }
            }
        } catch {
            Write-MigrationLog -Message "Could not read target version, proceeding with copy" -Level Debug
        }
    }

    # Ensure target directory exists
    if (-not (Test-Path $TargetBasePath)) {
        New-Item -Path $TargetBasePath -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    # Robocopy the essential Win11Migrator files
    # /MIR = mirror (ensures clean copy), /XD = exclude directories
    # Exclude: MigrationPackage (data), Build, .git, Tests, .claude, .github, node_modules
    # Also exclude any Win11Migration_* directories (exported packages living alongside)
    $robocopyArgs = @(
        $script:MigratorRoot
        $TargetBasePath
        '/MIR'
        '/XD', 'MigrationPackage', 'Build', '.git', 'Tests', '.claude', '.github', 'node_modules', '.vscode'
        '/XF', '*.log', '.gitignore', '.gitattributes', 'LICENSE', '*.md'
        '/R:2'
        '/W:3'
        '/NP'
        '/NDL'
        '/NJH'
        '/NJS'
        '/COPY:DAT'
        '/DCOPY:T'
    )

    # Also exclude any existing Win11Migration_* package dirs in the target
    # (MIR would delete them if they don't exist in source)
    $existingPackages = Get-ChildItem $TargetBasePath -Directory -Filter "Win11Migration_*" -ErrorAction SilentlyContinue
    foreach ($pkg in $existingPackages) {
        $robocopyArgs += '/XD'
        $robocopyArgs += $pkg.Name
    }

    $robocopyOutput = & robocopy @robocopyArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ge 8) {
        $outputText = ($robocopyOutput | Out-String).Trim()
        Write-MigrationLog -Message "Robocopy failed bundling Win11Migrator (exit code: $exitCode)" -Level Warning
        Write-MigrationLog -Message $outputText -Level Debug
        return [PSCustomObject]@{
            TargetPath  = $TargetBasePath
            FileCount   = 0
            TotalSizeMB = 0
            Skipped     = $false
        }
    }

    # Count what we copied
    $targetFiles = Get-ChildItem $TargetBasePath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\Win11Migration_' }
    $fileCount = ($targetFiles | Measure-Object).Count
    $totalSize = ($targetFiles | Measure-Object -Property Length -Sum).Sum
    $totalSizeMB = [math]::Round($totalSize / 1MB, 2)

    Write-MigrationLog -Message "Win11Migrator bundled: $fileCount files, $totalSizeMB MB" -Level Success

    return [PSCustomObject]@{
        TargetPath  = $TargetBasePath
        FileCount   = $fileCount
        TotalSizeMB = $totalSizeMB
        Skipped     = $false
    }
}
