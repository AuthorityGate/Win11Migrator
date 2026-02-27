<#
========================================================================================================
    Title:          Win11Migrator - Ninite Package Search
    Filename:       Search-NinitePackage.ps1
    Description:    Matches applications against the Ninite supported application catalog.
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
    Searches the NiniteAppList.json catalog for an application match.
    Returns the Ninite-compatible package name with a confidence score.
#>

function Search-NinitePackage {
    <#
    .SYNOPSIS
        Looks up a normalized application name in the Ninite app catalog.
    .PARAMETER AppName
        The application name to search for.
    .PARAMETER NormalizedName
        Pre-normalized app name. If not provided, the AppName will be normalized.
    .OUTPUTS
        [PSCustomObject] with properties: Found, PackageId, PackageName, Confidence, Source
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
        Found       = $false
        PackageId   = ''
        PackageName = ''
        Confidence  = 0.0
        Source      = 'Ninite'
    }

    if ([string]::IsNullOrWhiteSpace($NormalizedName)) {
        $NormalizedName = Get-NormalizedAppName -Name $AppName
    }

    if ([string]::IsNullOrWhiteSpace($NormalizedName)) {
        return $emptyResult
    }

    # Load the Ninite catalog
    $catalogPath = Join-Path $script:MigratorRoot "Config\NiniteAppList.json"
    if (-not (Test-Path $catalogPath)) {
        Write-MigrationLog -Message "NiniteAppList.json not found at $catalogPath" -Level Warning
        return $emptyResult
    }

    if (-not $script:CachedNiniteListData) {
        try {
            $script:CachedNiniteListData = Get-Content $catalogPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-MigrationLog -Message "Failed to parse NiniteAppList.json: $($_.Exception.Message)" -Level Warning
            return $emptyResult
        }
    }
    $catalogRaw = $script:CachedNiniteListData

    # Convert PSCustomObject to a dictionary for iteration
    $catalog = @{}
    $catalogRaw.PSObject.Properties | ForEach-Object {
        $catalog[$_.Name] = $_.Value
    }

    Write-MigrationLog -Message "Searching Ninite catalog ($($catalog.Count) entries) for: $NormalizedName" -Level Debug

    # Phase 1: Exact match on normalized name
    if ($catalog.ContainsKey($NormalizedName)) {
        Write-MigrationLog -Message "Ninite: exact match '$NormalizedName' -> '$($catalog[$NormalizedName])'" -Level Debug
        return [PSCustomObject]@{
            Found       = $true
            PackageId   = $catalog[$NormalizedName]
            PackageName = $NormalizedName
            Confidence  = 1.0
            Source      = 'Ninite'
        }
    }

    # Phase 2: Fuzzy match against catalog keys
    $bestKey        = ''
    $bestSimilarity = 0.0

    foreach ($key in $catalog.Keys) {
        $similarity = Get-AppNameSimilarity -Name1 $NormalizedName -Name2 $key
        if ($similarity -gt $bestSimilarity) {
            $bestSimilarity = $similarity
            $bestKey = $key
        }
    }

    # Require a minimum confidence of 0.6 for Ninite matches
    if ($bestSimilarity -ge 0.6 -and -not [string]::IsNullOrWhiteSpace($bestKey)) {
        Write-MigrationLog -Message "Ninite: fuzzy match '$NormalizedName' -> '$bestKey' = '$($catalog[$bestKey])' (confidence: $([Math]::Round($bestSimilarity, 2)))" -Level Debug
        return [PSCustomObject]@{
            Found       = $true
            PackageId   = $catalog[$bestKey]
            PackageName = $bestKey
            Confidence  = $bestSimilarity
            Source      = 'Ninite'
        }
    }

    Write-MigrationLog -Message "Ninite: no match for '$NormalizedName' (best was '$bestKey' at $([Math]::Round($bestSimilarity, 2)))" -Level Debug
    return $emptyResult
}
