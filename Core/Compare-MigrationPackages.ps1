<#
========================================================================================================
    Title:          Win11Migrator - Migration Package Comparator
    Filename:       Compare-MigrationPackages.ps1
    Description:    Compares two migration packages to show differences in apps, data, browsers, and settings.
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
    Diff two migration packages to identify what changed between exports.
.DESCRIPTION
    Loads the manifest.json from two migration packages and compares their contents:
    apps (by NormalizedName), user data folders, browser profiles, system settings,
    and package metadata. Useful for verifying incremental changes or comparing
    exports from different machines.
.PARAMETER PackagePath1
    Path to the older (baseline) migration package directory.
.PARAMETER PackagePath2
    Path to the newer (current) migration package directory.
.OUTPUTS
    [hashtable] with Package1, Package2 metadata and per-category diffs.
#>

function Compare-MigrationPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath1,

        [Parameter(Mandatory)]
        [string]$PackagePath2
    )

    Write-MigrationLog -Message "Comparing migration packages: $PackagePath1 vs $PackagePath2" -Level Info

    # Validate both packages exist
    $manifest1Path = Join-Path $PackagePath1 'manifest.json'
    $manifest2Path = Join-Path $PackagePath2 'manifest.json'

    if (-not (Test-Path $manifest1Path)) {
        Write-MigrationLog -Message "Manifest not found in package 1: $manifest1Path" -Level Error
        throw "Manifest not found: $manifest1Path"
    }
    if (-not (Test-Path $manifest2Path)) {
        Write-MigrationLog -Message "Manifest not found in package 2: $manifest2Path" -Level Error
        throw "Manifest not found: $manifest2Path"
    }

    # Load manifests using the existing reader
    $manifest1 = Read-MigrationManifest -ManifestPath $manifest1Path
    $manifest2 = Read-MigrationManifest -ManifestPath $manifest2Path

    # --- Compare Apps ---
    $apps1ByName = @{}
    foreach ($app in $manifest1.Apps) {
        $key = if ($app.NormalizedName) { $app.NormalizedName } else { $app.Name }
        $apps1ByName[$key] = $app
    }

    $apps2ByName = @{}
    foreach ($app in $manifest2.Apps) {
        $key = if ($app.NormalizedName) { $app.NormalizedName } else { $app.Name }
        $apps2ByName[$key] = $app
    }

    $appsAdded   = @()
    $appsRemoved = @()
    $appsCommon  = 0

    foreach ($key in $apps2ByName.Keys) {
        if ($apps1ByName.ContainsKey($key)) {
            $appsCommon++
        }
        else {
            $appsAdded += $apps2ByName[$key].Name
        }
    }
    foreach ($key in $apps1ByName.Keys) {
        if (-not $apps2ByName.ContainsKey($key)) {
            $appsRemoved += $apps1ByName[$key].Name
        }
    }

    # --- Compare UserData ---
    $data1ByCategory = @{}
    foreach ($item in $manifest1.UserData) {
        $key = if ($item.RelativePath) { $item.RelativePath } else { $item.Category }
        $data1ByCategory[$key] = $item
    }

    $data2ByCategory = @{}
    foreach ($item in $manifest2.UserData) {
        $key = if ($item.RelativePath) { $item.RelativePath } else { $item.Category }
        $data2ByCategory[$key] = $item
    }

    $dataAdded   = @()
    $dataRemoved = @()
    $dataSizeChange = [long]0

    foreach ($key in $data2ByCategory.Keys) {
        if (-not $data1ByCategory.ContainsKey($key)) {
            $dataAdded += $key
        }
        else {
            $dataSizeChange += ($data2ByCategory[$key].SizeBytes - $data1ByCategory[$key].SizeBytes)
        }
    }
    foreach ($key in $data1ByCategory.Keys) {
        if (-not $data2ByCategory.ContainsKey($key)) {
            $dataRemoved += $key
        }
    }

    # --- Compare BrowserProfiles ---
    $browsers1 = @{}
    foreach ($bp in $manifest1.BrowserProfiles) {
        $key = "$($bp.Browser)|$($bp.ProfileName)"
        $browsers1[$key] = $bp
    }

    $browsers2 = @{}
    foreach ($bp in $manifest2.BrowserProfiles) {
        $key = "$($bp.Browser)|$($bp.ProfileName)"
        $browsers2[$key] = $bp
    }

    $browsersAdded   = @()
    $browsersRemoved = @()

    foreach ($key in $browsers2.Keys) {
        if (-not $browsers1.ContainsKey($key)) {
            $browsersAdded += $key
        }
    }
    foreach ($key in $browsers1.Keys) {
        if (-not $browsers2.ContainsKey($key)) {
            $browsersRemoved += $key
        }
    }

    # --- Compare SystemSettings ---
    $settings1 = @{}
    foreach ($s in $manifest1.SystemSettings) {
        $key = "$($s.Category)|$($s.Name)"
        $settings1[$key] = $s
    }

    $settings2 = @{}
    foreach ($s in $manifest2.SystemSettings) {
        $key = "$($s.Category)|$($s.Name)"
        $settings2[$key] = $s
    }

    $settingsAdded   = @()
    $settingsRemoved = @()

    foreach ($key in $settings2.Keys) {
        if (-not $settings1.ContainsKey($key)) {
            $settingsAdded += $key
        }
    }
    foreach ($key in $settings1.Keys) {
        if (-not $settings2.ContainsKey($key)) {
            $settingsRemoved += $key
        }
    }

    # --- Build result ---
    $result = @{
        Package1 = @{
            ComputerName = $manifest1.SourceComputerName
            ExportDate   = $manifest1.ExportDate
            AppCount     = $manifest1.Apps.Count
            DataCount    = $manifest1.UserData.Count
        }
        Package2 = @{
            ComputerName = $manifest2.SourceComputerName
            ExportDate   = $manifest2.ExportDate
            AppCount     = $manifest2.Apps.Count
            DataCount    = $manifest2.UserData.Count
        }
        Apps = @{
            Added   = $appsAdded
            Removed = $appsRemoved
            Common  = $appsCommon
        }
        UserData = @{
            Added      = $dataAdded
            Removed    = $dataRemoved
            SizeChange = $dataSizeChange
        }
        BrowserProfiles = @{
            Added   = $browsersAdded
            Removed = $browsersRemoved
        }
        SystemSettings = @{
            Added   = $settingsAdded
            Removed = $settingsRemoved
        }
    }

    Write-MigrationLog -Message "Package comparison complete. Apps: +$($appsAdded.Count)/-$($appsRemoved.Count)/$appsCommon common. Data: +$($dataAdded.Count)/-$($dataRemoved.Count). Browsers: +$($browsersAdded.Count)/-$($browsersRemoved.Count). Settings: +$($settingsAdded.Count)/-$($settingsRemoved.Count)" -Level Info

    return $result
}
