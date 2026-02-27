<#
========================================================================================================
    Title:          Win11Migrator - Vendor Download URL Search
    Filename:       Search-VendorDownload.ps1
    Description:    Matches applications against the VendorDownloadUrls catalog for direct installer downloads.
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
    Searches VendorDownloadUrls.json for a direct download URL matching an application name.
    Returns the vendor download information with a confidence score.
#>

function Search-VendorDownload {
    <#
    .SYNOPSIS
        Looks up a normalized application name in the vendor download URL catalog.
    .PARAMETER AppName
        The application name to search for.
    .PARAMETER NormalizedName
        Pre-normalized app name. If not provided, the AppName will be normalized.
    .OUTPUTS
        [PSCustomObject] with properties: Found, DownloadUrl, SilentArgs, InstallerType, Notes, PackageName, Confidence, Source
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$AppName,

        [Parameter()]
        [string]$NormalizedName
    )

    $emptyResult = [PSCustomObject]@{
        Found         = $false
        DownloadUrl   = ''
        SilentArgs    = ''
        InstallerType = ''
        Notes         = ''
        PackageName   = ''
        Confidence    = 0.0
        Source        = 'VendorDownload'
    }

    if ([string]::IsNullOrWhiteSpace($NormalizedName)) {
        $NormalizedName = Get-NormalizedAppName -Name $AppName
    }

    if ([string]::IsNullOrWhiteSpace($NormalizedName)) {
        return $emptyResult
    }

    # Load the vendor download catalog
    $catalogPath = Join-Path $script:MigratorRoot "Config\VendorDownloadUrls.json"
    if (-not (Test-Path $catalogPath)) {
        Write-MigrationLog -Message "VendorDownloadUrls.json not found at $catalogPath" -Level Warning
        return $emptyResult
    }

    if (-not $script:CachedVendorUrlsData) {
        try {
            $script:CachedVendorUrlsData = Get-Content $catalogPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-MigrationLog -Message "Failed to parse VendorDownloadUrls.json: $($_.Exception.Message)" -Level Warning
            return $emptyResult
        }
    }
    $catalogRaw = $script:CachedVendorUrlsData

    # Convert to dictionary
    $catalog = [ordered]@{}
    $catalogRaw.PSObject.Properties | ForEach-Object {
        $catalog[$_.Name] = $_.Value
    }

    Write-MigrationLog -Message "Searching vendor download catalog ($($catalog.Count) entries) for: $NormalizedName" -Level Debug

    # Phase 1: Exact match
    if ($catalog.Contains($NormalizedName)) {
        $entry = $catalog[$NormalizedName]
        $notes = if ($entry.PSObject.Properties.Name -contains 'Notes') { $entry.Notes } else { '' }
        Write-MigrationLog -Message "VendorDownload: exact match '$NormalizedName' -> $($entry.Url)" -Level Debug
        return [PSCustomObject]@{
            Found         = $true
            DownloadUrl   = $entry.Url
            SilentArgs    = $entry.SilentArgs
            InstallerType = $entry.InstallerType
            Notes         = $notes
            PackageName   = $NormalizedName
            Confidence    = 1.0
            Source        = 'VendorDownload'
        }
    }

    # Phase 2: Fuzzy match
    $bestKey        = ''
    $bestSimilarity = 0.0

    foreach ($key in $catalog.Keys) {
        $similarity = Get-AppNameSimilarity -Name1 $NormalizedName -Name2 $key
        if ($similarity -gt $bestSimilarity) {
            $bestSimilarity = $similarity
            $bestKey = $key
        }
    }

    # Require minimum confidence of 0.6
    if ($bestSimilarity -ge 0.6 -and -not [string]::IsNullOrWhiteSpace($bestKey)) {
        $entry = $catalog[$bestKey]
        $notes = if ($entry.PSObject.Properties.Name -contains 'Notes') { $entry.Notes } else { '' }
        Write-MigrationLog -Message "VendorDownload: fuzzy match '$NormalizedName' -> '$bestKey' = $($entry.Url) (confidence: $([Math]::Round($bestSimilarity, 2)))" -Level Debug
        return [PSCustomObject]@{
            Found         = $true
            DownloadUrl   = $entry.Url
            SilentArgs    = $entry.SilentArgs
            InstallerType = $entry.InstallerType
            Notes         = $notes
            PackageName   = $bestKey
            Confidence    = $bestSimilarity
            Source        = 'VendorDownload'
        }
    }

    Write-MigrationLog -Message "VendorDownload: no match for '$NormalizedName' (best was '$bestKey' at $([Math]::Round($bestSimilarity, 2)))" -Level Debug
    return $emptyResult
}
