<#
========================================================================================================
    Title:          Win11Migrator - Self-Extracting Installer Build Script
    Filename:       Build-Installer.ps1
    Description:    Creates a self-extracting EXE installer with zero external dependencies.
                    Compresses project files into a ZIP, embeds as Base64 in a PowerShell installer
                    script, then wraps in a compiled C# EXE stub.
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
    Builds a self-extracting installer EXE for Win11Migrator.
.DESCRIPTION
    Stages distributable files, compresses to ZIP, embeds inside a PowerShell installer script,
    then compiles a C# EXE stub that launches the installer via powershell.exe.
    The resulting EXE requires no external dependencies (no 7-Zip, NSIS, or Inno Setup).
.PARAMETER OutputPath
    Directory where the build output will be placed. Defaults to .\Build
.PARAMETER Version
    Version string to stamp on the package. Defaults to reading from AppSettings.json.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "Build"),
    [string]$Version
)

$ErrorActionPreference = 'Stop'

# ── Read version from config if not specified ──
if (-not $Version) {
    $configPath = Join-Path $PSScriptRoot "Config\AppSettings.json"
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $Version = $config.Version
}

Write-Host ""
Write-Host "Win11Migrator Installer Builder" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan
Write-Host "Version: $Version" -ForegroundColor White
Write-Host ""

# ── Prepare output directory ──
if (Test-Path $OutputPath) {
    Remove-Item $OutputPath -Recurse -Force
}
New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Stage distributable files
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "[1/5] Staging files..." -ForegroundColor Yellow

$includeItems = @(
    'Win11Migrator.ps1',
    'Win11Migrator.bat',
    'README.md',
    'LICENSE',
    'INSTALL.md',
    'Config',
    'Core',
    'Modules',
    'GUI',
    'Reports'
)

$stagingDir = Join-Path $OutputPath "_staging"
New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null

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

# Copy uninstaller template into staging
$uninstallSource = Join-Path $PSScriptRoot "Installer\Uninstall.cmd"
if (Test-Path $uninstallSource) {
    Copy-Item $uninstallSource (Join-Path $stagingDir "Uninstall.cmd") -Force
    Write-Host "  + Uninstall.cmd" -ForegroundColor DarkGray
}

# Stamp version
@"
Win11Migrator
Version: $Version
Built: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Machine: $env:COMPUTERNAME
"@ | Set-Content (Join-Path $stagingDir "VERSION.txt") -Encoding UTF8

$fileCount = (Get-ChildItem $stagingDir -Recurse -File).Count
$totalSize = (Get-ChildItem $stagingDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
$totalSizeMB = [math]::Round($totalSize / 1MB, 2)
Write-Host "  Staged $fileCount files ($totalSizeMB MB)" -ForegroundColor Gray

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Compress to ZIP
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "[2/5] Compressing to ZIP..." -ForegroundColor Yellow

$zipPath = Join-Path $OutputPath "_payload.zip"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stagingDir, $zipPath, 'Optimal', $false)

$zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
Write-Host "  ZIP payload: $zipSize MB" -ForegroundColor Gray

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Convert ZIP to Base64 and generate installer PS1
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "[3/5] Generating installer script..." -ForegroundColor Yellow

$zipBytes = [System.IO.File]::ReadAllBytes($zipPath)
$base64Payload = [Convert]::ToBase64String($zipBytes)
Write-Host "  Base64 payload: $($base64Payload.Length) chars" -ForegroundColor Gray

# The installer PS1 uses a here-string template with placeholder replacement
$installScript = @'
# ══════════════════════════════════════════════════════════════════════════════
# Win11Migrator Self-Extracting Installer
# Auto-generated by Build-Installer.ps1 — do not edit
# ══════════════════════════════════════════════════════════════════════════════

$ErrorActionPreference = 'Stop'
$Version = '@@VERSION@@'
$InstallPath = Join-Path $env:ProgramFiles 'AuthorityGate\Win11Migrator'

function Write-Status { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Gray }
function Write-Step   { param([string]$Msg) Write-Host $Msg -ForegroundColor Yellow }
function Write-Ok     { param([string]$Msg) Write-Host $Msg -ForegroundColor Green }

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Win11Migrator v$Version Installer" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── Verify admin ──
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host "Error: This installer must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click the EXE and select 'Run as administrator'." -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to exit..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

# ── Step 1: Set ExecutionPolicy ──
Write-Step "[1/5] Setting execution policy..."
try {
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine -Force
    Write-Status "ExecutionPolicy set to Bypass for LocalMachine"
} catch {
    Write-Status "ExecutionPolicy: using Process scope fallback"
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
}

# ── Step 2: Add Windows Defender exclusion ──
Write-Step "[2/5] Adding Windows Defender exclusion..."
try {
    Add-MpPreference -ExclusionPath $InstallPath -ErrorAction Stop
    Write-Status "Defender exclusion added: $InstallPath"
} catch {
    Write-Status "Note: Could not add Defender exclusion (non-critical): $_"
}

# ── Step 3: Extract files ──
Write-Step "[3/5] Extracting files to $InstallPath..."

$base64 = '@@PAYLOAD@@'

$zipBytes = [Convert]::FromBase64String($base64)
$tempZip = Join-Path $env:TEMP "Win11Migrator_install_$(Get-Random).zip"
[System.IO.File]::WriteAllBytes($tempZip, $zipBytes)

if (Test-Path $InstallPath) {
    Remove-Item $InstallPath -Recurse -Force
}

New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($tempZip, $InstallPath)

Remove-Item $tempZip -ErrorAction SilentlyContinue

$installedFiles = (Get-ChildItem $InstallPath -Recurse -File).Count
Write-Status "$installedFiles files installed"

# ── Step 4: Create shortcuts ──
Write-Step "[4/5] Creating shortcuts..."

$batPath = Join-Path $InstallPath "Win11Migrator.bat"
$iconPath = Join-Path $InstallPath "GUI\icon.ico"
$shell = New-Object -ComObject WScript.Shell

# Desktop shortcut (Public Desktop — visible to all users)
$desktopPath = [Environment]::GetFolderPath('CommonDesktopDirectory')
$desktopLnk = Join-Path $desktopPath "Win11Migrator.lnk"
$shortcut = $shell.CreateShortcut($desktopLnk)
$shortcut.TargetPath = $batPath
$shortcut.WorkingDirectory = $InstallPath
$shortcut.Description = "Win11Migrator v$Version - Windows Migration Tool"
$shortcut.WindowStyle = 7
if (Test-Path $iconPath) { $shortcut.IconLocation = $iconPath }
$shortcut.Save()
Write-Status "Desktop shortcut created"

# Start Menu shortcut
$startMenuDir = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) "AuthorityGate"
if (-not (Test-Path $startMenuDir)) {
    New-Item -Path $startMenuDir -ItemType Directory -Force | Out-Null
}
$startMenuLnk = Join-Path $startMenuDir "Win11Migrator.lnk"
$shortcut = $shell.CreateShortcut($startMenuLnk)
$shortcut.TargetPath = $batPath
$shortcut.WorkingDirectory = $InstallPath
$shortcut.Description = "Win11Migrator v$Version - Windows Migration Tool"
$shortcut.WindowStyle = 7
if (Test-Path $iconPath) { $shortcut.IconLocation = $iconPath }
$shortcut.Save()
Write-Status "Start Menu shortcut created"

# ── Step 5: Register in Add/Remove Programs ──
Write-Step "[5/5] Registering application..."

$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Win11Migrator'
$uninstallCmd = Join-Path $InstallPath "Uninstall.cmd"

New-Item -Path $uninstallKey -Force | Out-Null
Set-ItemProperty -Path $uninstallKey -Name 'DisplayName'     -Value 'Win11Migrator'
Set-ItemProperty -Path $uninstallKey -Name 'DisplayVersion'  -Value $Version
Set-ItemProperty -Path $uninstallKey -Name 'Publisher'       -Value 'AuthorityGate Inc.'
Set-ItemProperty -Path $uninstallKey -Name 'InstallLocation' -Value $InstallPath
Set-ItemProperty -Path $uninstallKey -Name 'UninstallString' -Value ('"' + $uninstallCmd + '"')
Set-ItemProperty -Path $uninstallKey -Name 'NoModify'        -Value 1
Set-ItemProperty -Path $uninstallKey -Name 'NoRepair'        -Value 1

$installSizeKB = [math]::Round(
    (Get-ChildItem $InstallPath -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1KB
)
Set-ItemProperty -Path $uninstallKey -Name 'EstimatedSize' -Value $installSizeKB

Write-Status "Registered in Add/Remove Programs"

# ── Done ──
Write-Host ""
Write-Ok "============================================"
Write-Ok "  Installation complete!"
Write-Ok "============================================"
Write-Host ""
Write-Host "  Install path: $InstallPath" -ForegroundColor White
Write-Host "  To uninstall: Add/Remove Programs or run Uninstall.cmd" -ForegroundColor White
Write-Host ""

Write-Host "Launching Win11Migrator..." -ForegroundColor Cyan
Start-Process -FilePath $batPath -WorkingDirectory $InstallPath

Start-Sleep -Seconds 2
exit 0
'@

# Inject version and payload into the installer script
$installScript = $installScript.Replace('@@VERSION@@', $Version)
$installScript = $installScript.Replace('@@PAYLOAD@@', $base64Payload)

$installerPs1Path = Join-Path $OutputPath "_installer_payload.ps1"
[System.IO.File]::WriteAllText($installerPs1Path, $installScript, [System.Text.Encoding]::UTF8)

$ps1Size = [math]::Round((Get-Item $installerPs1Path).Length / 1MB, 2)
Write-Host "  Installer script: $ps1Size MB" -ForegroundColor Gray

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Compile C# EXE stub
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "[4/5] Compiling EXE stub..." -ForegroundColor Yellow

# Strategy: The EXE embeds the installer PS1 as Base64 (safe for C# string literals —
# only [A-Za-z0-9+/=] characters). At runtime it decodes to the PS1 text, writes to
# a temp file, and launches powershell.exe with -File and UAC elevation.

$ps1Bytes = [System.IO.File]::ReadAllBytes($installerPs1Path)
$ps1Base64 = [Convert]::ToBase64String($ps1Bytes)

# Split the Base64 into 100-char chunks for C# string concatenation (avoids
# compiler issues with extremely long string literals)
$chunkSize = 100000  # 100K chars per chunk — csc handles this fine
$chunks = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $ps1Base64.Length; $i += $chunkSize) {
    $len = [Math]::Min($chunkSize, $ps1Base64.Length - $i)
    $chunks.Add($ps1Base64.Substring($i, $len))
}

$chunkedLiteral = ($chunks | ForEach-Object { "`"$_`"" }) -join " +`n            "

$csharpSource = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace Win11Migrator
{
    class Installer
    {
        static int Main(string[] args)
        {
            try
            {
                // Decode the embedded installer script from Base64
                string payloadBase64 = $chunkedLiteral;

                byte[] scriptBytes = Convert.FromBase64String(payloadBase64);
                string scriptContent = Encoding.UTF8.GetString(scriptBytes);

                // Write to a temp file
                string tempScript = Path.Combine(
                    Path.GetTempPath(),
                    "Win11Migrator_Setup_" + Path.GetRandomFileName() + ".ps1"
                );
                File.WriteAllText(tempScript, scriptContent, Encoding.UTF8);

                // Launch PowerShell with UAC elevation
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + tempScript + "\"";
                psi.UseShellExecute = true;
                psi.Verb = "runas";

                Process p = Process.Start(psi);
                p.WaitForExit();

                // Cleanup temp script
                try { File.Delete(tempScript); } catch { }

                return p.ExitCode;
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // User declined the UAC prompt
                return 1;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("Installer error: " + ex.Message);
                Console.Error.WriteLine("Press any key to exit...");
                try { Console.ReadKey(true); } catch { }
                return 1;
            }
        }
    }
}
"@

$csPath = Join-Path $OutputPath "_installer.cs"
[System.IO.File]::WriteAllText($csPath, $csharpSource, [System.Text.Encoding]::UTF8)

# Find csc.exe from the .NET Framework
$cscPath = $null
$runtimeDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
$cscCandidate = Join-Path $runtimeDir "csc.exe"
if (Test-Path $cscCandidate) {
    $cscPath = $cscCandidate
} else {
    # Search all .NET Framework directories, prefer newest
    $cscPath = Get-ChildItem "$env:WINDIR\Microsoft.NET\Framework64\*\csc.exe",
                             "$env:WINDIR\Microsoft.NET\Framework\*\csc.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Directory.Name -replace '^v', '') } -Descending -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

if (-not $cscPath -or -not (Test-Path $cscPath)) {
    Write-Error "Cannot find csc.exe. Ensure .NET Framework is installed on this build machine."
}

Write-Host "  Compiler: $cscPath" -ForegroundColor DarkGray

$exeName = "Win11Migrator_Setup.exe"
$exePath = Join-Path $OutputPath $exeName

# Compile
$compileArgs = @(
    '/nologo',
    '/target:winexe',
    '/platform:anycpu',
    '/optimize+',
    "/out:$exePath",
    $csPath
)

$compileResult = & $cscPath @compileArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ($compileResult | Out-String) -ForegroundColor Red
    Write-Error "C# compilation failed (exit code $LASTEXITCODE)"
}

$exeSize = [math]::Round((Get-Item $exePath).Length / 1MB, 2)
Write-Host "  Compiled: $exeName ($exeSize MB)" -ForegroundColor Gray

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Cleanup intermediate files
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "[5/5] Cleaning up..." -ForegroundColor Yellow

Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $installerPs1Path -Force -ErrorAction SilentlyContinue
Remove-Item $csPath -Force -ErrorAction SilentlyContinue

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "Build complete!" -ForegroundColor Green
Write-Host "  Version:     $Version" -ForegroundColor White
Write-Host "  Installer:   $exePath" -ForegroundColor White
Write-Host "  EXE size:    $exeSize MB" -ForegroundColor White
Write-Host "  Files:       $fileCount packaged" -ForegroundColor White
Write-Host "  ZIP payload: $zipSize MB (compressed)" -ForegroundColor White
Write-Host ""
Write-Host "To install: double-click $exeName" -ForegroundColor Cyan
Write-Host ""
