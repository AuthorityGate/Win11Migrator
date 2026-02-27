<#
========================================================================================================
    Title:          Win11Migrator - Chocolatey Package Search
    Filename:       Search-ChocolateyPackage.ps1
    Description:    Searches the Chocolatey repository for a matching package for a given application.
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
    Searches the Chocolatey community repository for a package matching a given application name.
    Uses the choco CLI if available, otherwise falls back to the Chocolatey community API.
#>

function Search-ChocolateyPackage {
    <#
    .SYNOPSIS
        Searches Chocolatey for a matching package by application name.
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
        Source      = 'Chocolatey'
    }

    if ([string]::IsNullOrWhiteSpace($NormalizedName)) {
        $NormalizedName = Get-NormalizedAppName -Name $AppName
    }

    if ([string]::IsNullOrWhiteSpace($NormalizedName)) {
        return $emptyResult
    }

    Write-MigrationLog -Message "Searching Chocolatey for: $NormalizedName" -Level Debug

    # --- Phase 0: Static ID map lookup (instant, no CLI/API call) ---
    if (-not $script:CachedChocolateyIdMap) {
        $mapPath = Join-Path $script:MigratorRoot "Config\ChocolateyIdMap.json"
        if (Test-Path $mapPath) {
            try {
                $mapRaw = Get-Content $mapPath -Raw | ConvertFrom-Json
                $script:CachedChocolateyIdMap = @{}
                $mapRaw.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object {
                    $script:CachedChocolateyIdMap[$_.Name] = $_.Value
                }
                Write-MigrationLog -Message "Loaded ChocolateyIdMap with $($script:CachedChocolateyIdMap.Count) entries" -Level Debug
            } catch {
                $script:CachedChocolateyIdMap = @{}
            }
        } else {
            $script:CachedChocolateyIdMap = @{}
        }
    }

    # Check static map with original name (lowercase) and normalized name
    $lookupKeys = @($NormalizedName, $AppName.ToLower().Trim()) | Select-Object -Unique
    foreach ($key in $lookupKeys) {
        if ($script:CachedChocolateyIdMap.ContainsKey($key)) {
            $mappedId = $script:CachedChocolateyIdMap[$key]
            Write-MigrationLog -Message "Chocolatey: static map match '$key' -> '$mappedId'" -Level Debug
            return [PSCustomObject]@{
                Found       = $true
                PackageId   = $mappedId
                PackageName = $AppName
                Confidence  = 0.95
                Source      = 'Chocolatey'
            }
        }
    }

    # --- Phase 1: Dynamic CLI/API search (fallback for unknown apps) ---
    # Try choco CLI first
    $chocoCmd = Get-Command choco -ErrorAction SilentlyContinue
    if ($chocoCmd) {
        $result = Search-ChocolateyViaCli -SearchTerm $NormalizedName -NormalizedName $NormalizedName
        if ($result.Found) {
            return $result
        }
    }

    # Fallback: Chocolatey community API (OData v2 endpoint)
    $result = Search-ChocolateyViaApi -SearchTerm $NormalizedName -NormalizedName $NormalizedName
    return $result
}

function Search-ChocolateyViaCli {
    <#
    .SYNOPSIS
        Searches Chocolatey using the choco CLI tool.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm,

        [Parameter(Mandatory)]
        [string]$NormalizedName
    )

    $emptyResult = [PSCustomObject]@{
        Found       = $false
        PackageId   = ''
        PackageName = ''
        Confidence  = 0.0
        Source      = 'Chocolatey'
    }

    try {
        $rawOutput = & choco search $SearchTerm --limit-output --exact 2>&1
        $lines = $rawOutput | Out-String -Stream | Where-Object {
            $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_)
        }
    }
    catch {
        Write-MigrationLog -Message "choco search (exact) failed: $($_.Exception.Message)" -Level Debug
        $lines = @()
    }

    # If exact search found nothing, try a broader search
    if (-not $lines -or $lines.Count -eq 0) {
        try {
            $rawOutput = & choco search $SearchTerm --limit-output 2>&1
            $lines = $rawOutput | Out-String -Stream | Where-Object {
                $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_)
            }
        }
        catch {
            Write-MigrationLog -Message "choco search (broad) failed: $($_.Exception.Message)" -Level Debug
            return $emptyResult
        }
    }

    if (-not $lines -or $lines.Count -eq 0) {
        return $emptyResult
    }

    # choco --limit-output format: "packageId|version"
    $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($line in $lines) {
        # Skip warning/info lines from choco
        if ($line -match '^Chocolatey' -or $line -match '^Did you know' -or $line -match '^\d+ packages') {
            continue
        }

        $parts = $line -split '\|'
        if ($parts.Count -lt 1) { continue }

        $pkgId = $parts[0].Trim()
        if ([string]::IsNullOrWhiteSpace($pkgId)) { continue }

        $normalizedCandidate = Get-NormalizedAppName -Name $pkgId
        $similarity = Get-AppNameSimilarity -Name1 $NormalizedName -Name2 $normalizedCandidate

        $candidates.Add([PSCustomObject]@{
            PackageId   = $pkgId
            PackageName = $pkgId
            Similarity  = $similarity
        })
    }

    if ($candidates.Count -eq 0) {
        return $emptyResult
    }

    $best = $candidates | Sort-Object -Property Similarity -Descending | Select-Object -First 1

    if ($best.Similarity -lt 0.4) {
        Write-MigrationLog -Message "Chocolatey CLI: best match for '$NormalizedName' was '$($best.PackageId)' with confidence $([Math]::Round($best.Similarity, 2)) - below threshold" -Level Debug
        return $emptyResult
    }

    Write-MigrationLog -Message "Chocolatey CLI: matched '$NormalizedName' -> '$($best.PackageId)' (confidence: $([Math]::Round($best.Similarity, 2)))" -Level Debug

    return [PSCustomObject]@{
        Found       = $true
        PackageId   = $best.PackageId
        PackageName = $best.PackageName
        Confidence  = $best.Similarity
        Source      = 'Chocolatey'
    }
}

function Search-ChocolateyViaApi {
    <#
    .SYNOPSIS
        Searches the Chocolatey community repository via the OData v2 REST API.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$SearchTerm,

        [Parameter(Mandatory)]
        [string]$NormalizedName
    )

    $emptyResult = [PSCustomObject]@{
        Found       = $false
        PackageId   = ''
        PackageName = ''
        Confidence  = 0.0
        Source      = 'Chocolatey'
    }

    # URL-encode the search term
    $encodedTerm = [System.Uri]::EscapeDataString($SearchTerm)
    $apiUrl = "https://community.chocolatey.org/api/v2/Search()?`$filter=IsLatestVersion&searchTerm='$encodedTerm'&targetFramework=''&includePrerelease=false&`$top=5"

    try {
        # Use TLS 1.2
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

        $response = Invoke-RestMethod -Uri $apiUrl -Method Get -TimeoutSec 15 -ErrorAction Stop
    }
    catch {
        Write-MigrationLog -Message "Chocolatey API search failed: $($_.Exception.Message)" -Level Debug
        return $emptyResult
    }

    if (-not $response) {
        return $emptyResult
    }

    # The OData response wraps entries; handle both single and multiple results
    $entries = @()
    if ($response -is [System.Xml.XmlDocument] -or $response.PSObject.Properties.Name -contains 'entry') {
        # XML-based OData response
        if ($response.feed -and $response.feed.entry) {
            $entries = @($response.feed.entry)
        }
        elseif ($response.entry) {
            $entries = @($response.entry)
        }
    }
    elseif ($response -is [array]) {
        $entries = $response
    }
    else {
        $entries = @($response)
    }

    if ($entries.Count -eq 0) {
        return $emptyResult
    }

    $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($entry in $entries) {
        $pkgId    = ''
        $pkgTitle = ''

        # Try various property access patterns for the OData response
        if ($entry.PSObject.Properties.Name -contains 'Id') {
            $pkgId = $entry.Id
        }
        if ($entry.title -and $entry.title.'#text') {
            $pkgTitle = $entry.title.'#text'
        }
        elseif ($entry.title -is [string]) {
            $pkgTitle = $entry.title
        }
        elseif ($entry.PSObject.Properties.Name -contains 'Title') {
            $pkgTitle = $entry.Title
        }

        if ([string]::IsNullOrWhiteSpace($pkgTitle) -and [string]::IsNullOrWhiteSpace($pkgId)) {
            continue
        }

        $nameForMatch = if (-not [string]::IsNullOrWhiteSpace($pkgTitle)) { $pkgTitle } else { $pkgId }
        $idForResult  = if (-not [string]::IsNullOrWhiteSpace($pkgId)) { $pkgId } else { $pkgTitle }

        $normalizedCandidate = Get-NormalizedAppName -Name $nameForMatch
        $similarity = Get-AppNameSimilarity -Name1 $NormalizedName -Name2 $normalizedCandidate

        $candidates.Add([PSCustomObject]@{
            PackageId   = $idForResult
            PackageName = $nameForMatch
            Similarity  = $similarity
        })
    }

    if ($candidates.Count -eq 0) {
        return $emptyResult
    }

    $best = $candidates | Sort-Object -Property Similarity -Descending | Select-Object -First 1

    if ($best.Similarity -lt 0.4) {
        Write-MigrationLog -Message "Chocolatey API: best match for '$NormalizedName' was '$($best.PackageName)' with confidence $([Math]::Round($best.Similarity, 2)) - below threshold" -Level Debug
        return $emptyResult
    }

    Write-MigrationLog -Message "Chocolatey API: matched '$NormalizedName' -> '$($best.PackageId)' (confidence: $([Math]::Round($best.Similarity, 2)))" -Level Debug

    return [PSCustomObject]@{
        Found       = $true
        PackageId   = $best.PackageId
        PackageName = $best.PackageName
        Confidence  = $best.Similarity
        Source      = 'Chocolatey'
    }
}
