<#
========================================================================================================
    Title:          Win11Migrator - Program Files Directory Scanner
    Filename:       Get-ProgramFilesApps.ps1
    Description:    Discovers installed applications by scanning Program Files directories for executables.
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
    Fallback scanner that discovers applications by inspecting top-level folders
    in Program Files and Program Files (x86).
    Extracts version information from executable files found in each folder.
#>

function Get-ProgramFilesApps {
    <#
    .SYNOPSIS
        Scans Program Files directories and extracts application info from executables.
    .OUTPUTS
        [MigrationApp[]] Array of discovered applications with Source='ProgramFiles'.
    #>
    [CmdletBinding()]
    [OutputType([MigrationApp[]])]
    param()

    Write-MigrationLog -Message "Starting Program Files fallback scan" -Level Info

    $scanDirs = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) }

    # Folder names to skip (common system/runtime folders, not user applications)
    $skipFolders = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    @(
        'Common Files',
        'CommonFiles',
        'Internet Explorer',
        'Microsoft Update Health Tools',
        'Microsoft SDKs',
        'MSBuild',
        'PackageManagement',
        'Reference Assemblies',
        'Windows Defender',
        'Windows Defender Advanced Threat Protection',
        'Windows Mail',
        'Windows Media Player',
        'Windows Multimedia Platform',
        'Windows NT',
        'Windows Photo Viewer',
        'Windows Portable Devices',
        'Windows Security',
        'Windows Sidebar',
        'WindowsApps',
        'WindowsPowerShell',
        'dotnet',
        'Microsoft.NET',
        'IIS',
        'IIS Express',
        'Uninstall Information',
        'InstallShield Installation Information',
        'Microsoft SQL Server',
        'Microsoft Visual Studio',
        'Microsoft Analysis Services',
        'NVIDIA Corporation',
        'Intel',
        'Realtek',
        'Dell',
        'HP',
        'Lenovo',
        'ModifiableWindowsApps'
    ) | ForEach-Object { $null = $skipFolders.Add($_) }

    $apps = [System.Collections.Generic.List[MigrationApp]]::new()
    $seenNormalized = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($baseDir in $scanDirs) {
        Write-MigrationLog -Message "Scanning directory: $baseDir" -Level Debug

        try {
            $topFolders = Get-ChildItem -Path $baseDir -Directory -ErrorAction SilentlyContinue
        }
        catch {
            Write-MigrationLog -Message "Cannot enumerate $baseDir : $($_.Exception.Message)" -Level Warning
            continue
        }

        if (-not $topFolders) { continue }

        foreach ($folder in $topFolders) {
            if ($skipFolders.Contains($folder.Name)) { continue }

            # Try to find an executable in this folder to read version info
            $version   = ''
            $publisher = ''
            $bestExe   = $null

            try {
                $exeFiles = Get-ChildItem -Path $folder.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                    Select-Object -First 10
            }
            catch {
                $exeFiles = @()
            }

            foreach ($exe in $exeFiles) {
                try {
                    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe.FullName)
                    if ($versionInfo -and -not [string]::IsNullOrWhiteSpace($versionInfo.ProductName)) {
                        $bestExe = $versionInfo
                        break
                    }
                    if ($versionInfo -and -not [string]::IsNullOrWhiteSpace($versionInfo.FileVersion)) {
                        # Keep it as fallback, but keep looking for one with ProductName
                        if (-not $bestExe) { $bestExe = $versionInfo }
                    }
                }
                catch {
                    # Cannot read version info from this exe, skip it
                }
            }

            $displayName = $folder.Name
            if ($bestExe -and -not [string]::IsNullOrWhiteSpace($bestExe.ProductName)) {
                $displayName = $bestExe.ProductName
            }
            if ($bestExe -and -not [string]::IsNullOrWhiteSpace($bestExe.FileVersion)) {
                $version = $bestExe.FileVersion
            }
            if ($bestExe -and -not [string]::IsNullOrWhiteSpace($bestExe.CompanyName)) {
                $publisher = $bestExe.CompanyName
            }

            $normalizedName = Get-NormalizedAppName -Name $displayName

            if ([string]::IsNullOrWhiteSpace($normalizedName)) { continue }

            # Deduplicate across both Program Files directories
            if (-not $seenNormalized.Add($normalizedName)) { continue }

            $app = [MigrationApp]::new()
            $app.Name              = $displayName
            $app.NormalizedName    = $normalizedName
            $app.Version           = $version
            $app.Publisher         = $publisher
            $app.InstallLocation   = $folder.FullName
            $app.UninstallString   = ''
            $app.Source            = 'ProgramFiles'
            $app.InstallMethod     = ''
            $app.PackageId         = ''
            $app.DownloadUrl       = ''
            $app.MatchConfidence   = 0.0
            $app.Selected          = $true
            $app.InstallStatus     = 'Pending'
            $app.InstallError      = ''

            $apps.Add($app)
        }
    }

    Write-MigrationLog -Message "Program Files scan complete: found $($apps.Count) applications" -Level Info
    return [MigrationApp[]]$apps.ToArray()
}
