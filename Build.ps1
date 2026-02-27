<#
========================================================================================================
    Title:          Win11Migrator - Build & Packaging Script
    Filename:       Build.ps1
    Description:    Creates a distributable ZIP package and optional self-extracting EXE for deployment.
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
    Build script for Win11Migrator - creates a distributable ZIP package.
.DESCRIPTION
    Packages all project files into a ZIP archive ready for distribution.
    Optionally creates a self-extracting EXE using 7-Zip SFX if 7z is available.
.PARAMETER OutputPath
    Directory where the build output will be placed. Defaults to .\Build
.PARAMETER Version
    Version string to stamp on the package. Defaults to reading from AppSettings.json.
.PARAMETER CreateSFX
    If specified and 7-Zip is available, creates a self-extracting EXE.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "Build"),
    [string]$Version,
    [switch]$CreateSFX
)

$ErrorActionPreference = 'Stop'

# --- Read version from config if not specified ---
if (-not $Version) {
    $configPath = Join-Path $PSScriptRoot "Config\AppSettings.json"
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $Version = $config.Version
}

Write-Host "Building Win11Migrator v$Version" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan

# --- Prepare output directory ---
if (Test-Path $OutputPath) {
    Remove-Item $OutputPath -Recurse -Force
}
New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null

# --- Define what to include ---
$includeItems = @(
    'Win11Migrator.ps1',
    'Win11Migrator.bat',
    'README.md',
    'LICENSE',
    'Config',
    'Core',
    'Modules',
    'GUI',
    'Reports'
)

# --- Create staging directory ---
$stagingDir = Join-Path $OutputPath "Win11Migrator_v$Version"
New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null

Write-Host "Copying files to staging directory..." -ForegroundColor Gray

foreach ($item in $includeItems) {
    $sourcePath = Join-Path $PSScriptRoot $item
    if (Test-Path $sourcePath) {
        $destPath = Join-Path $stagingDir $item
        if ((Get-Item $sourcePath).PSIsContainer) {
            Copy-Item $sourcePath $destPath -Recurse -Force
        } else {
            Copy-Item $sourcePath $destPath -Force
        }
        Write-Host "  + $item" -ForegroundColor DarkGray
    } else {
        Write-Warning "  - Skipping missing: $item"
    }
}

# --- Stamp version ---
$versionFile = Join-Path $stagingDir "VERSION.txt"
@"
Win11Migrator
Version: $Version
Built: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Machine: $env:COMPUTERNAME
"@ | Set-Content $versionFile -Encoding UTF8

# --- Count files ---
$fileCount = (Get-ChildItem $stagingDir -Recurse -File).Count
$totalSize = (Get-ChildItem $stagingDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
$totalSizeMB = [math]::Round($totalSize / 1MB, 2)
Write-Host "Staged $fileCount files ($totalSizeMB MB)" -ForegroundColor Gray

# --- Create ZIP ---
$zipName = "Win11Migrator_v$Version.zip"
$zipPath = Join-Path $OutputPath $zipName

Write-Host "Creating ZIP: $zipName" -ForegroundColor Gray

# Use .NET compression (available in PS 5.1)
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stagingDir, $zipPath, 'Optimal', $true)

$zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
Write-Host "ZIP created: $zipPath ($zipSize MB)" -ForegroundColor Green

# --- Optionally create SFX ---
if ($CreateSFX) {
    $7zPath = $null
    $searchPaths = @(
        "${env:ProgramFiles}\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        (Get-Command 7z -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
    )
    foreach ($path in $searchPaths) {
        if ($path -and (Test-Path $path)) {
            $7zPath = $path
            break
        }
    }

    if ($7zPath) {
        Write-Host "Creating self-extracting EXE..." -ForegroundColor Gray

        $sfxName = "Win11Migrator_v$Version.exe"
        $sfxPath = Join-Path $OutputPath $sfxName
        $7zSfxModule = Join-Path (Split-Path $7zPath) "7z.sfx"

        if (Test-Path $7zSfxModule) {
            # Create 7z archive first
            $7zArchive = Join-Path $OutputPath "temp.7z"
            & $7zPath a $7zArchive "$stagingDir\*" -r -mx=9 | Out-Null

            # Create SFX config
            $sfxConfig = Join-Path $OutputPath "sfx_config.txt"
            @"
;!@Install@!UTF-8!
Title="Win11Migrator v$Version"
BeginPrompt="Install Win11Migrator v$Version?"
RunProgram="Win11Migrator.bat"
;!@InstallEnd@!
"@ | Set-Content $sfxConfig -Encoding UTF8

            # Combine: SFX module + config + archive = EXE
            $sfxBytes = [System.IO.File]::ReadAllBytes($7zSfxModule)
            $configBytes = [System.IO.File]::ReadAllBytes($sfxConfig)
            $archiveBytes = [System.IO.File]::ReadAllBytes($7zArchive)

            $stream = [System.IO.File]::Create($sfxPath)
            $stream.Write($sfxBytes, 0, $sfxBytes.Length)
            $stream.Write($configBytes, 0, $configBytes.Length)
            $stream.Write($archiveBytes, 0, $archiveBytes.Length)
            $stream.Close()

            # Cleanup temp files
            Remove-Item $7zArchive -ErrorAction SilentlyContinue
            Remove-Item $sfxConfig -ErrorAction SilentlyContinue

            $sfxSize = [math]::Round((Get-Item $sfxPath).Length / 1MB, 2)
            Write-Host "SFX created: $sfxPath ($sfxSize MB)" -ForegroundColor Green
        } else {
            Write-Warning "7z.sfx module not found at: $7zSfxModule"
            Write-Warning "SFX creation skipped. ZIP is still available."
        }
    } else {
        Write-Warning "7-Zip not found. SFX creation skipped. ZIP is still available."
    }
}

# --- Summary ---
Write-Host ""
Write-Host "Build complete!" -ForegroundColor Green
Write-Host "  Version:  $Version" -ForegroundColor White
Write-Host "  Files:    $fileCount" -ForegroundColor White
Write-Host "  ZIP:      $zipPath" -ForegroundColor White
Write-Host "  Size:     $zipSize MB" -ForegroundColor White
