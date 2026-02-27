<#
========================================================================================================
    Title:          Win11Migrator - Microsoft Store Package Search
    Filename:       Search-StorePackage.ps1
    Description:    Searches the Microsoft Store catalog for a matching package for a given application.
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
    Searches the StoreAppCatalog.json for a Microsoft Store package matching an application name.
    Returns the Store app ID and PackageFamilyName with a confidence score.
#>

function Search-StorePackage {
    <#
    .SYNOPSIS
        Looks up a normalized application name in the Store app catalog.
    .PARAMETER AppName
        The application name to search for.
    .PARAMETER NormalizedName
        Pre-normalized app name. If not provided, the AppName will be normalized.
    .OUTPUTS
        [PSCustomObject] with properties: Found, PackageId, StoreId, PackageFamilyName, PackageName, Confidence, Source
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
        Found             = $false
        PackageId         = ''
        StoreId           = ''
        PackageFamilyName = ''
        PackageName       = ''
        Confidence        = 0.0
        Source            = 'Store'
    }

    if ([string]::IsNullOrWhiteSpace($NormalizedName)) {
        $NormalizedName = Get-NormalizedAppName -Name $AppName
    }

    if ([string]::IsNullOrWhiteSpace($NormalizedName)) {
        return $emptyResult
    }

    # Load the Store catalog
    $catalogPath = Join-Path $script:MigratorRoot "Config\StoreAppCatalog.json"
    if (-not (Test-Path $catalogPath)) {
        Write-MigrationLog -Message "StoreAppCatalog.json not found at $catalogPath" -Level Warning
        return $emptyResult
    }

    if (-not $script:CachedStoreCatalogData) {
        try {
            $script:CachedStoreCatalogData = Get-Content $catalogPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-MigrationLog -Message "Failed to parse StoreAppCatalog.json: $($_.Exception.Message)" -Level Warning
            return $emptyResult
        }
    }
    $catalogRaw = $script:CachedStoreCatalogData

    # Convert to dictionary
    $catalog = [ordered]@{}
    $catalogRaw.PSObject.Properties | ForEach-Object {
        $catalog[$_.Name] = $_.Value
    }

    Write-MigrationLog -Message "Searching Store catalog ($($catalog.Count) entries) for: $NormalizedName" -Level Debug

    # Phase 1: Exact match
    if ($catalog.Contains($NormalizedName)) {
        $entry = $catalog[$NormalizedName]
        Write-MigrationLog -Message "Store: exact match '$NormalizedName' -> StoreId=$($entry.StoreId)" -Level Debug
        return [PSCustomObject]@{
            Found             = $true
            PackageId         = $entry.PackageFamilyName
            StoreId           = $entry.StoreId
            PackageFamilyName = $entry.PackageFamilyName
            PackageName       = $NormalizedName
            Confidence        = 1.0
            Source            = 'Store'
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
        Write-MigrationLog -Message "Store: fuzzy match '$NormalizedName' -> '$bestKey' StoreId=$($entry.StoreId) (confidence: $([Math]::Round($bestSimilarity, 2)))" -Level Debug
        return [PSCustomObject]@{
            Found             = $true
            PackageId         = $entry.PackageFamilyName
            StoreId           = $entry.StoreId
            PackageFamilyName = $entry.PackageFamilyName
            PackageName       = $bestKey
            Confidence        = $bestSimilarity
            Source            = 'Store'
        }
    }

    Write-MigrationLog -Message "Store: no match for '$NormalizedName' (best was '$bestKey' at $([Math]::Round($bestSimilarity, 2)))" -Level Debug
    return $emptyResult
}
