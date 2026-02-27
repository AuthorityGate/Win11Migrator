<#
========================================================================================================
    Title:          Win11Migrator - Application Name Normalizer
    Filename:       Get-NormalizedAppName.ps1
    Description:    Normalizes application names using Levenshtein/Jaccard similarity for deduplication and matching.
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
    Normalizes application names for deduplication and matching.
    Provides Levenshtein distance and Jaccard similarity for fuzzy matching.
#>

function Get-LevenshteinDistance {
    <#
    .SYNOPSIS
        Computes the Levenshtein edit distance between two strings.
    .OUTPUTS
        [int] The number of single-character edits required.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Source,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Target
    )

    $sourceLen = $Source.Length
    $targetLen = $Target.Length

    if ($sourceLen -eq 0) { return $targetLen }
    if ($targetLen -eq 0) { return $sourceLen }

    # Use two-row optimization instead of full matrix to save memory
    $previousRow = [int[]]::new($targetLen + 1)
    $currentRow  = [int[]]::new($targetLen + 1)

    for ($j = 0; $j -le $targetLen; $j++) {
        $previousRow[$j] = $j
    }

    for ($i = 1; $i -le $sourceLen; $i++) {
        $currentRow[0] = $i
        for ($j = 1; $j -le $targetLen; $j++) {
            $cost = if ($Source[$i - 1] -eq $Target[$j - 1]) { 0 } else { 1 }
            $insertion    = $currentRow[$j - 1] + 1
            $deletion     = $previousRow[$j] + 1
            $substitution = $previousRow[$j - 1] + $cost
            $currentRow[$j] = [Math]::Min([Math]::Min($insertion, $deletion), $substitution)
        }
        # Swap rows
        $temp = $previousRow
        $previousRow = $currentRow
        $currentRow = $temp
    }

    return $previousRow[$targetLen]
}

function Get-JaccardSimilarity {
    <#
    .SYNOPSIS
        Computes the Jaccard similarity coefficient between two strings using word tokens.
    .OUTPUTS
        [double] A value between 0.0 (no overlap) and 1.0 (identical token sets).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$StringA,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$StringB
    )

    if ([string]::IsNullOrWhiteSpace($StringA) -and [string]::IsNullOrWhiteSpace($StringB)) {
        return 1.0
    }
    if ([string]::IsNullOrWhiteSpace($StringA) -or [string]::IsNullOrWhiteSpace($StringB)) {
        return 0.0
    }

    $tokensA = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    $tokensB = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )

    $StringA -split '\s+' | Where-Object { $_.Length -gt 0 } | ForEach-Object { $null = $tokensA.Add($_) }
    $StringB -split '\s+' | Where-Object { $_.Length -gt 0 } | ForEach-Object { $null = $tokensB.Add($_) }

    if ($tokensA.Count -eq 0 -and $tokensB.Count -eq 0) { return 1.0 }
    if ($tokensA.Count -eq 0 -or $tokensB.Count -eq 0) { return 0.0 }

    $intersection = [System.Collections.Generic.HashSet[string]]::new($tokensA, [StringComparer]::OrdinalIgnoreCase)
    $intersection.IntersectWith($tokensB)

    $union = [System.Collections.Generic.HashSet[string]]::new($tokensA, [StringComparer]::OrdinalIgnoreCase)
    $union.UnionWith($tokensB)

    if ($union.Count -eq 0) { return 0.0 }

    return [double]$intersection.Count / [double]$union.Count
}

function Get-NormalizedAppName {
    <#
    .SYNOPSIS
        Normalizes an application display name by stripping version numbers,
        edition markers, architecture tags, and parenthetical info.
    .PARAMETER Name
        The raw application display name.
    .OUTPUTS
        [string] The cleaned, normalized name.
    .EXAMPLE
        Get-NormalizedAppName -Name "Google Chrome (64-bit) v120.0.6099.130"
        # Returns: "google chrome"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    $normalized = $Name.Trim()

    # Remove parenthetical content: (64-bit), (x86), (Preview), etc.
    $normalized = [regex]::Replace($normalized, '\([^)]*\)', '')

    # Remove bracket content: [64-bit], [Preview], etc.
    $normalized = [regex]::Replace($normalized, '\[[^\]]*\]', '')

    # Remove version strings: v1.2.3, 1.2.3.4, version 1.0, Ver. 2.0
    $normalized = [regex]::Replace($normalized, '\b[vV](?:er(?:sion)?\.?\s*)?\d+[\d.]*\b', '')
    $normalized = [regex]::Replace($normalized, '\b\d+\.\d+[\d.]*\b', '')

    # Remove standalone large build/version numbers (e.g. trailing "12345")
    $normalized = [regex]::Replace($normalized, '\b\d{4,}\b', '')

    # Remove architecture tags
    $normalized = [regex]::Replace($normalized, '\b(?:x64|x86|amd64|arm64|ia64|win64|win32|64-bit|32-bit)\b', '', 'IgnoreCase')

    # Remove edition markers
    $normalized = [regex]::Replace($normalized, '\b(?:Edition|Professional|Enterprise|Community|Ultimate|Premium|Standard|Home|Pro|Lite|Free|Trial|Beta|Alpha|RC\d*|Preview|Insider|Update\s*\d*)\b', '', 'IgnoreCase')

    # Remove installer-related suffixes
    $normalized = [regex]::Replace($normalized, '\b(?:Setup|Installer|Install|Portable|Standalone)\b', '', 'IgnoreCase')

    # Remove trademark symbols
    $normalized = [regex]::Replace($normalized, '[^\w\s.+#-]', '')

    # Collapse multiple spaces and trim
    $normalized = [regex]::Replace($normalized, '\s{2,}', ' ').Trim()

    # Lowercase for consistent matching
    $normalized = $normalized.ToLower()

    # Remove trailing dots or dashes
    $normalized = $normalized.TrimEnd('.', '-', ' ')

    return $normalized
}

function Get-AppNameSimilarity {
    <#
    .SYNOPSIS
        Computes a combined similarity score between two application names.
        Uses weighted Levenshtein distance and Jaccard similarity on normalized names.
    .PARAMETER Name1
        First application name.
    .PARAMETER Name2
        Second application name.
    .OUTPUTS
        [double] A similarity score between 0.0 (completely different) and 1.0 (identical).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [string]$Name1,

        [Parameter(Mandatory)]
        [string]$Name2
    )

    $norm1 = Get-NormalizedAppName -Name $Name1
    $norm2 = Get-NormalizedAppName -Name $Name2

    if ([string]::IsNullOrWhiteSpace($norm1) -or [string]::IsNullOrWhiteSpace($norm2)) {
        return 0.0
    }

    # Exact match after normalization
    if ($norm1 -eq $norm2) {
        return 1.0
    }

    # Levenshtein-based similarity (normalized to 0-1)
    $maxLen = [Math]::Max($norm1.Length, $norm2.Length)
    $levenshteinDist = Get-LevenshteinDistance -Source $norm1 -Target $norm2
    $levenshteinSim = 1.0 - ([double]$levenshteinDist / [double]$maxLen)

    # Jaccard similarity on word tokens
    $jaccardSim = Get-JaccardSimilarity -StringA $norm1 -StringB $norm2

    # Substring containment bonus: if one name fully contains the other
    $containsBonus = 0.0
    if ($norm1.Contains($norm2) -or $norm2.Contains($norm1)) {
        $containsBonus = 0.15
    }

    # Weighted combination: Jaccard 50%, Levenshtein 40%, containment 10%
    $combined = ($jaccardSim * 0.50) + ($levenshteinSim * 0.40) + ($containsBonus * 0.10)

    # Clamp to [0, 1]
    return [Math]::Min(1.0, [Math]::Max(0.0, $combined))
}
