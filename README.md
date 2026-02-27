# Win11Migrator

Migrate your apps, files, and settings from one Windows 11 PC to another.

Win11Migrator scans a source machine for installed applications, user data, browser profiles, and system settings. It packages everything into a portable migration bundle with a JSON manifest, transfers it via USB drive, OneDrive, or Google Drive, and then reinstalls and restores everything on the target machine through a step-by-step WPF wizard.

---

## Table of Contents

- [Requirements](#requirements)
- [Getting Started](#getting-started)
- [Usage](#usage)
  - [Export (Source PC)](#export-source-pc)
  - [Import (Target PC)](#import-target-pc)
- [What Gets Migrated](#what-gets-migrated)
- [App Installation Methods](#app-installation-methods)
- [Transfer Methods](#transfer-methods)
- [Configuration](#configuration)
- [Migration Package Format](#migration-package-format)
- [Building from Source](#building-from-source)
- [Running Tests](#running-tests)
- [Project Structure](#project-structure)
- [Architecture](#architecture)
- [Known Limitations](#known-limitations)
- [License](#license)

---

## Requirements

| Requirement | Details |
|---|---|
| **Operating System** | Windows 11 (both source and target) |
| **PowerShell** | 5.1 (ships with Windows 11; do **not** use PowerShell 7 -- WPF requires Windows PowerShell) |
| **Privileges** | Administrator recommended. Required on the target machine for app installation. |
| **Disk Space** | Enough free space on the transfer medium to hold the migration package |

Optional tools that enhance functionality (detected automatically at runtime):

| Tool | Purpose |
|---|---|
| [WinGet](https://github.com/microsoft/winget-cli) | Primary app install method (pre-installed on Windows 11 22H2+) |
| [Chocolatey](https://chocolatey.org/) | Secondary app install method (auto-bootstrapped on target if needed) |
| [7-Zip](https://www.7-zip.org/) | Only needed if you want to build a self-extracting EXE via `Build.ps1 -CreateSFX` |

---

## Getting Started

### Option 1: Double-click (recommended for non-technical users)

1. Download or copy the `Win11Migrator` folder to your PC.
2. Double-click **`Win11Migrator.bat`**.
3. Accept the UAC elevation prompt.
4. The wizard GUI opens automatically.

The `.bat` launcher checks for admin rights, requests elevation if needed, sets the execution policy for the session, and launches the PowerShell script.

### Option 2: PowerShell

```powershell
# Open an elevated (Run as Administrator) PowerShell prompt
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Win11Migrator.ps1
```

### Parameters

```
Win11Migrator.ps1 [-CLI] [-Verbose]
```

| Parameter | Description |
|---|---|
| `-CLI` | Reserved for future CLI mode (not yet implemented; GUI launches by default) |
| `-Verbose` | Enable verbose logging output |

---

## Usage

### Export (Source PC)

Run Win11Migrator on the PC you are migrating **from**.

1. **Welcome** -- Select **Export**.
2. **Scan** -- The tool automatically scans for:
   - Installed applications (registry, WinGet, Microsoft Store, Program Files)
   - User data folders (Desktop, Documents, Downloads, Pictures, Videos, Music, Favorites)
   - Browser profiles (Chrome, Edge, Firefox, Brave)
   - System settings (WiFi, printers, mapped drives, environment variables, Windows preferences)
3. **App Selection** -- Review the discovered app list. Each app shows its detected install method (WinGet, Chocolatey, Ninite, Store, Vendor Download, or Manual). Use the search box to filter. Select or deselect individual apps.
4. **Data Selection** -- Toggle which user data folders, browser profiles, and system settings categories to include. Folder sizes are shown next to each item.
5. **Storage Selection** -- Choose a transfer method:
   - **USB Drive** -- Select from detected removable drives
   - **OneDrive** -- Copies to your OneDrive sync folder
   - **Google Drive** -- Copies to your Google Drive sync folder
   - **Custom Folder** -- Browse to any local or network path
6. **Export** -- The tool packages everything into a migration bundle and copies it to the selected destination. A `manifest.json` file is written with all metadata.
7. **Complete** -- Review the summary. For cloud transfers, wait for the sync to finish before proceeding to the target machine.

### Import (Target PC)

Run Win11Migrator on the PC you are migrating **to**.

1. **Welcome** -- Select **Import**.
2. **Select Package** -- Browse to the migration package folder, or select from auto-detected packages found on USB drives and cloud sync folders.
3. **Import** -- The tool reads `manifest.json` and performs the following in order:
   1. **Install applications** -- Sequentially installs each app using its resolved method (WinGet, Chocolatey, Ninite, Store, or direct download). Failed installs are logged but do not stop the pipeline.
   2. **Restore user data** -- Copies files back to the correct user profile folders using Robocopy.
   3. **Restore browser profiles** -- Restores bookmarks, preferences, and history. Generates an HTML page with extension reinstall links for each browser.
   4. **Restore system settings** -- Re-imports WiFi profiles, printer configurations, mapped network drives, environment variables, and Windows settings.
   5. **Restore AppData** -- Merges exported AppData folders into the target profile.
   6. **Generate reports** -- Creates an HTML completion report and a manual install guide for any apps that could not be automated.
4. **Complete** -- Review statistics and open the generated reports. A restart is recommended to apply all changes.

---

## What Gets Migrated

### Applications

| Source | Method |
|---|---|
| Registry uninstall keys (`HKLM`, `HKCU`, `WOW6432Node`) | Scans `DisplayName`, `DisplayVersion`, `Publisher`, `InstallLocation`, `UninstallString` |
| WinGet package list | Parses `winget list` output; pre-resolves package IDs |
| Microsoft Store apps | Filters `Get-AppxPackage`; excludes frameworks, system packages, and runtime components |
| Program Files folders | Fallback scanner; reads `FileVersionInfo` from discovered `.exe` files |

App names are normalized (stripped of version numbers, architecture tags, edition markers) and deduplicated across all sources using weighted metadata scoring. A fuzzy matching engine (Levenshtein distance + Jaccard similarity) resolves each app against package managers.

### User Data

The following profile folders are scanned and exported via Robocopy:

- Desktop, Documents, Downloads, Pictures, Videos, Music, Favorites
- Selected AppData folders (Sticky Notes, Windows Themes, Credentials -- configurable)

OneDrive Known Folder Move redirection is detected automatically through the registry (`User Shell Folders`).

### Browser Profiles

| Browser | Bookmarks | Preferences | History | Extensions | Passwords |
|---|---|---|---|---|---|
| Google Chrome | Yes | Yes | Yes | List + Web Store links | **No** (security) |
| Microsoft Edge | Yes | Yes | Yes | List + Add-ons links | **No** |
| Mozilla Firefox | Yes (`places.sqlite`) | Yes (`prefs.js`) | Yes | List + AMO links | **No** |
| Brave | Yes | Yes | Yes | List + Web Store links | **No** |

Passwords are intentionally never exported. On import, an HTML page is generated per browser with direct links to reinstall each extension from the appropriate store.

### System Settings

| Category | Export Method | Import Method |
|---|---|---|
| WiFi Profiles | `netsh wlan export profile` (XML with cleartext keys) | `netsh wlan add profile` |
| Printers | `Get-Printer` + `Get-PrinterPort` metadata | `Add-Printer` / `Add-PrinterPort` (network reconnect or local rebuild) |
| Mapped Drives | Registry (`HKCU:\Network`) + `net use` | `net use` with persistence flag |
| Environment Variables | `[System.Environment]::GetEnvironmentVariables('User')` | `SetEnvironmentVariable` with PATH merging (additive, not overwrite) |
| Windows Settings | File associations (`FileExts` registry), taskbar pins (`.lnk` shortcuts + `Taskband` binary), Start Menu layout | Best-effort restore (Windows protects some settings with hashes) |

---

## App Installation Methods

The install method resolver uses a cascade with confidence scoring. For each app, it tries each source in order and selects the first match above the confidence threshold:

| Priority | Method | Source | Notes |
|---|---|---|---|
| 1 | **WinGet** | `winget search` | Primary method. Silent install via `winget install --silent`. |
| 2 | **Chocolatey** | `choco search` / community API | Auto-bootstraps Chocolatey on target if not present. |
| 3 | **Ninite** | Local catalog (`NiniteAppList.json`, 55+ apps) | Free tier limitations logged. |
| 4 | **Microsoft Store** | Local catalog (`StoreAppCatalog.json`, 30+ apps) | Falls back to opening the Store page if `winget --source msstore` fails. |
| 5 | **Vendor Download** | URL database (`VendorDownloadUrls.json`, 30+ apps) | Downloads MSI/EXE, attempts common silent switches (`/S`, `/silent`, `/VERYSILENT`, `/quiet`). |
| 6 | **Manual** | N/A | Listed in the manual install HTML report with download links where available. |

Each install method has a configurable timeout (default 600 seconds) and uses the retry wrapper (default 3 attempts with 5-second delays). Apps are installed sequentially to avoid MSI mutex conflicts. Individual failures never abort the pipeline.

---

## Transfer Methods

| Method | How It Works | Requirements |
|---|---|---|
| **USB Drive** | Detected via WMI (`Win32_DiskDrive` chain). Copies with Robocopy. Post-copy integrity check (file count + total size). | USB drive with sufficient free space |
| **OneDrive** | Detected via `$env:OneDrive`, registry (`HKCU:\SOFTWARE\Microsoft\OneDrive`), and environment variables. Copies to a `Win11Migrator/` subfolder in the sync root. | OneDrive desktop app signed in and syncing |
| **Google Drive** | Detected via `$env:LOCALAPPDATA\Google\DriveFS`, registry, and common user profile paths. Copies to a `Win11Migrator/` subfolder. | Google Drive for Desktop installed and syncing |
| **Custom Folder** | Browse to any local or network (UNC) path. | Target path must be writable |

Cloud methods rely on the desktop sync client rather than APIs, avoiding OAuth complexity.

---

## Configuration

All settings are in **`Config/AppSettings.json`**:

```json
{
  "Version": "1.0.0",
  "LogLevel": "Info",
  "LogDirectory": "Logs",
  "MigrationPackageDirectory": "MigrationPackage",
  "MaxRetryCount": 3,
  "RetryDelaySeconds": 5,
  "DiskSpaceBufferMB": 500,
  "RobocopyThreads": 8,
  "RobocopyRetries": 3,
  "RobocopyWaitSeconds": 5,
  "UserDataFolders": ["Desktop", "Documents", "Downloads", "Pictures", "Videos", "Music", "Favorites"],
  "AppDataInclude": ["Microsoft\\Sticky Notes", "Microsoft\\Windows\\Themes", "Microsoft\\Credentials"],
  "ExcludeFilePatterns": ["*.tmp", "~$*", "Thumbs.db", "desktop.ini", "*.log"],
  "MaxFileSizeMB": 4096,
  "EnableWinget": true,
  "EnableChocolatey": true,
  "EnableNinite": true,
  "EnableStoreApps": true,
  "EnableVendorDownload": true,
  "SilentInstallTimeout": 600,
  "BrowserProfiles": { "Chrome": true, "Edge": true, "Firefox": true, "Brave": true },
  "SystemSettings": { "WiFiProfiles": true, "Printers": true, "MappedDrives": true, "EnvironmentVariables": true, "WindowsSettings": true }
}
```

| Setting | Default | Description |
|---|---|---|
| `LogLevel` | `Info` | Minimum log level: `Debug`, `Info`, `Warning`, `Error` |
| `LogDirectory` | `Logs` | Relative path for log files (auto-created) |
| `MigrationPackageDirectory` | `MigrationPackage` | Local staging directory for export packages |
| `MaxRetryCount` | `3` | Retry attempts for transient failures (installs, file copies) |
| `RetryDelaySeconds` | `5` | Seconds between retries |
| `DiskSpaceBufferMB` | `500` | Extra headroom required beyond estimated package size |
| `RobocopyThreads` | `8` | Robocopy `/MT` thread count for file operations |
| `RobocopyRetries` / `RobocopyWaitSeconds` | `3` / `5` | Robocopy `/R` and `/W` parameters |
| `UserDataFolders` | 7 folders | Which profile folders to scan and export |
| `AppDataInclude` | 3 folders | Which `%APPDATA%` / `%LOCALAPPDATA%` subfolders to include |
| `ExcludeFilePatterns` | 5 patterns | File patterns excluded from Robocopy operations |
| `MaxFileSizeMB` | `4096` | Skip individual files larger than this |
| `Enable*` | all `true` | Toggle individual install methods on/off |
| `SilentInstallTimeout` | `600` | Seconds before killing a hung installer process |
| `BrowserProfiles.*` | all `true` | Toggle individual browser scanning |
| `SystemSettings.*` | all `true` | Toggle individual system settings categories |

### Additional Config Files

| File | Purpose |
|---|---|
| `Config/ExcludedApps.json` | Wildcard patterns for apps to skip during discovery (runtimes, drivers, OEM bloatware -- 50+ patterns) |
| `Config/NiniteAppList.json` | Map of normalized app names to Ninite slugs (55+ apps) |
| `Config/VendorDownloadUrls.json` | Map of app names to `{ Url, SilentArgs, InstallerType }` objects (30+ apps) |
| `Config/StoreAppCatalog.json` | Map of app names to `{ StoreId, PackageFamilyName }` objects (30+ apps) |

---

## Migration Package Format

An exported migration package is a folder with the following structure:

```
Win11Migration_COMPUTERNAME_20260226_143052/
    manifest.json              # Machine info, app list, data inventory, settings
    UserData/
        Desktop/               # Robocopy mirror of user's Desktop
        Documents/
        Downloads/
        ...
    AppData/
        Roaming/               # Selected AppData\Roaming subfolders
        Local/                 # Selected AppData\Local subfolders
    BrowserProfiles/
        Chrome_Default/        # Bookmarks, Preferences, History, extensions_list.json
        Edge_Default/
        Firefox_default-release/
        Brave_Default/
    SystemSettings/
        WiFi/                  # Exported XML profiles
        Printers/              # Printer metadata (in manifest)
        MappedDrives/          # Drive mappings (in manifest)
        EnvVars/               # Environment variables (in manifest)
        WindowsSettings/       # File associations, taskbar pins, Start layout
    Reports/                   # Generated on import
        CompletionReport.html
        ManualInstallReport.html
```

### manifest.json

The manifest is the authoritative record of the migration. Structure:

```json
{
  "Version": "1.0.0",
  "ExportDate": "2026-02-26T14:30:52.0000000-05:00",
  "SourceComputerName": "DESKTOP-ABC123",
  "SourceOSVersion": "Microsoft Windows NT 10.0.22631.0",
  "SourceUserName": "john",
  "Apps": [
    {
      "Name": "Google Chrome",
      "NormalizedName": "google chrome",
      "Version": "122.0.6261.95",
      "Publisher": "Google LLC",
      "Source": "Registry",
      "InstallMethod": "Winget",
      "PackageId": "Google.Chrome",
      "MatchConfidence": 0.95,
      "Selected": true,
      "InstallStatus": "Pending"
    }
  ],
  "UserData": [...],
  "BrowserProfiles": [...],
  "SystemSettings": [...],
  "Metadata": {}
}
```

---

## Building from Source

The build script packages all project files into a distributable ZIP:

```powershell
# Basic ZIP build
.\Build.ps1

# Custom version
.\Build.ps1 -Version "1.2.0"

# Custom output directory
.\Build.ps1 -OutputPath "C:\Releases"

# ZIP + self-extracting EXE (requires 7-Zip installed)
.\Build.ps1 -CreateSFX
```

Build output is placed in `.\Build\` by default:

```
Build/
    Win11Migrator_v1.0.0/     # Staging directory
    Win11Migrator_v1.0.0.zip  # Distributable ZIP
    Win11Migrator_v1.0.0.exe  # Self-extracting EXE (if -CreateSFX)
```

The ZIP contains everything needed to run on any Windows 11 machine with no prerequisites beyond PowerShell 5.1.

---

## Running Tests

Tests use the [Pester](https://pester.dev/) framework (ships with Windows PowerShell 5.1).

```powershell
# Run all tests
Invoke-Pester -Path .\Tests\

# Run a specific test file
Invoke-Pester -Path .\Tests\Core.Tests.ps1

# Run with verbose output
Invoke-Pester -Path .\Tests\ -Output Detailed
```

### Test Suites

| File | Coverage |
|---|---|
| `Tests/Core.Tests.ps1` | Config loading, class instantiation, logging, retry wrapper, manifest round-trip, disk space estimation |
| `Tests/AppDiscovery.Tests.ps1` | Name normalization, fuzzy similarity scoring, config JSON validation, Ninite/Store/Vendor catalog lookups |
| `Tests/UserData.Tests.ps1` | Profile path detection, OneDrive redirection, browser profile enumeration, class defaults |
| `Tests/Integration.Tests.ps1` | Full scan pipeline, manifest create/read round-trip, USB/cloud detection, report generation, project structure validation |

---

## Project Structure

```
Win11Migrator/
    Win11Migrator.ps1              # Entry point: loads all modules, initializes environment, launches GUI
    Win11Migrator.bat              # Double-click launcher: handles UAC elevation and execution policy
    Build.ps1                      # Packaging script: ZIP and optional SFX EXE
    README.md
    LICENSE

    Config/
        AppSettings.json           # All runtime settings and feature flags
        ExcludedApps.json          # Wildcard patterns for apps to skip (runtimes, drivers, bloatware)
        NiniteAppList.json         # Normalized app name -> Ninite slug mapping
        VendorDownloadUrls.json    # App name -> { Url, SilentArgs, InstallerType } mapping
        StoreAppCatalog.json       # App name -> { StoreId, PackageFamilyName } mapping

    Core/
        Initialize-Environment.ps1 # PowerShell class definitions, config loading, prerequisite checks
        Write-MigrationLog.ps1     # Logging to file + concurrent queue for GUI + verbose stream
        Test-AdminPrivilege.ps1    # Admin check and elevation request
        Invoke-WithRetry.ps1       # Generic retry wrapper with configurable attempts and delay
        Get-DiskSpaceEstimate.ps1  # Estimate package size, verify target has sufficient space
        ConvertTo-MigrationManifest.ps1  # Serialize scan results to manifest.json
        Read-MigrationManifest.ps1       # Deserialize and validate manifest with typed reconstruction

    Modules/
        AppDiscovery/
            Get-InstalledApps.ps1      # Orchestrator: calls all scanners, deduplicates by weighted metadata score
            Get-RegistryApps.ps1       # HKLM + HKCU + WOW6432Node uninstall key scanner
            Get-WingetApps.ps1         # Parses `winget list` fixed-width table output
            Get-StoreApps.ps1          # Filters Get-AppxPackage (excludes frameworks, system packages)
            Get-ProgramFilesApps.ps1   # Fallback: scans Program Files folders for .exe FileVersionInfo
            Get-NormalizedAppName.ps1  # Name normalization + Levenshtein distance + Jaccard similarity
            Resolve-InstallMethod.ps1  # Cascade resolver: WinGet > Choco > Ninite > Store > Vendor > Manual
            Search-WingetPackage.ps1   # Fuzzy match against `winget search` output
            Search-ChocolateyPackage.ps1  # CLI search + OData v2 API fallback
            Search-NinitePackage.ps1   # Exact + fuzzy match against NiniteAppList.json
            Search-StorePackage.ps1    # Exact + fuzzy match against StoreAppCatalog.json
            Search-VendorDownload.ps1  # Exact + fuzzy match against VendorDownloadUrls.json

        AppInstaller/
            Invoke-AppInstallPipeline.ps1 # Sequential orchestrator: groups by method, retries, progress callbacks
            Install-AppViaWinget.ps1      # winget install --id <PackageId> --silent
            Install-AppViaChocolatey.ps1  # choco install <PackageId> -y --no-progress
            Install-Chocolatey.ps1        # Bootstrap Chocolatey on target if not present
            Install-AppViaNinite.ps1      # Download and run Ninite per-app installer
            Install-AppViaStore.ps1       # winget --source msstore, falls back to opening Store page
            Install-AppViaDownload.ps1    # Download MSI/EXE, detect type, try common silent switches

        UserData/
            Get-UserProfilePaths.ps1   # Resolve actual paths via registry; detect OneDrive KFM redirection
            Export-UserProfile.ps1     # Robocopy /MIR with multi-threading, excluded patterns, progress
            Import-UserProfile.ps1     # Robocopy /E (merge, not mirror) to target profile paths
            Export-AppDataSettings.ps1 # Copy selected Roaming/Local AppData subfolders
            Import-AppDataSettings.ps1 # Restore AppData with path remapping

        BrowserProfiles/
            Get-BrowserProfilePaths.ps1    # Detect all browsers, enumerate profiles, check for data files
            Export-ChromeProfile.ps1        # Bookmarks, Preferences, History, extension list (no passwords)
            Export-EdgeProfile.ps1          # Same as Chrome (Chromium-based)
            Export-FirefoxProfile.ps1       # places.sqlite, prefs.js, extensions.json (no logins.json)
            Export-BraveProfile.ps1         # Same as Chrome (Chromium-based)
            Import-ChromeProfile.ps1        # Restore files + generate extension reinstall HTML
            Import-EdgeProfile.ps1          # Restore files + generate extension reinstall HTML
            Import-FirefoxProfile.ps1       # Restore profile files + extension HTML
            Import-BraveProfile.ps1         # Restore files + generate extension reinstall HTML

        SystemSettings/
            Export-WiFiProfiles.ps1         # netsh wlan export (XML with cleartext keys)
            Import-WiFiProfiles.ps1         # netsh wlan add profile
            Export-PrinterConfigs.ps1       # Get-Printer + Get-PrinterPort metadata capture
            Import-PrinterConfigs.ps1       # Add-Printer / Add-PrinterPort reconstruction
            Export-MappedDrives.ps1         # Registry (HKCU:\Network) + net use
            Import-MappedDrives.ps1         # net use recreation with credential handling
            Export-WindowsSettings.ps1      # File associations, taskbar pins (.lnk + Taskband), Start layout
            Import-WindowsSettings.ps1      # Best-effort restore of associations, pins, and layout
            Export-EnvironmentVariables.ps1 # User-scope env vars with PATH split for merging
            Import-EnvironmentVariables.ps1 # SetEnvironmentVariable with additive PATH merge

        StorageTargets/
            Get-USBDrives.ps1              # WMI disk chain detection for removable USB drives
            Find-CloudSyncFolders.ps1      # Detect OneDrive and Google Drive sync roots
            Export-ToUSBDrive.ps1          # Robocopy + post-copy integrity verification
            Import-FromUSBDrive.ps1        # Locate package on USB, copy to local temp
            Export-ToOneDrive.ps1          # Copy to OneDrive/Win11Migrator/ subfolder
            Import-FromOneDrive.ps1        # Locate and copy from OneDrive sync folder
            Export-ToGoogleDrive.ps1       # Copy to Google Drive/Win11Migrator/ subfolder
            Import-FromGoogleDrive.ps1     # Locate and copy from Google Drive sync folder

    GUI/
        MainWindow.xaml                # WPF window shell with header, content frame, footer nav
        MainWindow.ps1                 # Window logic, wizard navigation, background runspace management
        Styles/
            Colors.xaml                # Color palette and brush resources
            Typography.xaml            # Font families and text styles
            Controls.xaml              # Button, TextBox, CheckBox, ProgressBar, Card templates
            Icons.xaml                 # Path-based vector icons (Material Design geometry)
        Pages/
            WelcomePage.xaml + .ps1        # Export vs Import mode selection cards
            ScanProgressPage.xaml + .ps1   # Background scanning with per-phase progress indicators
            AppSelectionPage.xaml + .ps1   # Filterable checkbox list with install method badges
            DataSelectionPage.xaml + .ps1  # Toggle data categories with size display
            StorageSelectionPage.xaml + .ps1  # USB / OneDrive / Google Drive / Custom folder picker
            ExportProgressPage.xaml + .ps1    # Multi-phase export with log viewer
            ImportSourcePage.xaml + .ps1      # Browse for package + auto-detect on USB/cloud
            ImportProgressPage.xaml + .ps1    # Install + restore progress with success/fail counters
            CompletionPage.xaml + .ps1        # Summary statistics, report links, next steps
        Controls/
            AppListItem.xaml + .ps1       # Custom app row with color-coded install method badge
            ProgressPanel.xaml + .ps1     # Reusable progress display with animated bar
            LogViewer.xaml + .ps1         # Dark-themed scrolling log with auto-tail and line limit

    Reports/
        New-ManualInstallReport.ps1    # Generate HTML report for apps needing manual install
        New-CompletionReport.ps1       # Generate HTML completion summary with CSS pie charts
        Templates/
            ManualInstallReport.html   # HTML template with {{PLACEHOLDER}} markers
            CompletionReport.html      # HTML template with status badges and conic-gradient charts

    Tests/
        Core.Tests.ps1                 # Config, classes, logging, retry, manifest, disk space
        AppDiscovery.Tests.ps1         # Normalization, similarity, config files, catalog lookups
        UserData.Tests.ps1             # Profile paths, browser detection, export/import
        Integration.Tests.ps1          # Full pipeline, structure validation, report generation
```

---

## Architecture

### Data Flow

```
Source PC                          Transfer Medium                    Target PC
---------                          ---------------                    ---------
Registry ──┐                                                    ┌── WinGet install
WinGet ────┤                                                    ├── Choco install
Store ─────┼── Get-InstalledApps                                ├── Ninite install
ProgFiles ─┘   Resolve-InstallMethod                            ├── Store install
               │                                                ├── Vendor download
User Data ─────┤   ConvertTo-          USB Drive                │
Browsers ──────┼── MigrationManifest ──OneDrive ── Read-Manifest┤
WiFi/Print ────┤   Export-UserProfile  Google Drive Import-User ├── Restore files
Env Vars ──────┘   Export-Browser*     Custom       Import-*    ├── Restore browsers
                   Export-Settings*                              ├── Restore WiFi/print
                                                                ├── Merge env vars
                                                                └── HTML reports
```

### Class Model

Defined in `Core/Initialize-Environment.ps1`:

| Class | Purpose |
|---|---|
| `MigrationApp` | Discovered application with name, version, publisher, source, resolved install method, package ID, confidence score, and install status |
| `UserDataItem` | A profile folder or AppData subfolder with path, category, size, and export/import status |
| `BrowserProfile` | Browser profile with path, detected data flags (bookmarks, extensions, history), extension list, and status |
| `SystemSetting` | A system configuration item (WiFi profile, printer, drive mapping, env var) with category, data hashtable, and status |
| `MigrationManifest` | Top-level container: machine info, export date, arrays of all four item types, and metadata |
| `MigrationProgress` | Progress reporting: phase, current item, counts, percentage, and status message |

### Design Decisions

| Decision | Rationale |
|---|---|
| **PowerShell 5.1** (not 7+) | Ships with Windows 11. WPF `PresentationFramework` requires Windows PowerShell. |
| **Cloud via sync folder** (not API) | Avoids OAuth token management, app registration, and API rate limits. Relies on already-configured desktop sync clients. |
| **Robocopy** for file operations | Handles long paths (>260 chars), automatic retries, multi-threading, and structured exit codes. |
| **Fuzzy name matching** | Registry display names rarely match package manager IDs exactly. Levenshtein + Jaccard combination gives robust matching. |
| **Sequential app install** | Multiple concurrent MSI installs fail due to the Windows Installer mutex. Sequential execution is slower but reliable. |
| **Individual failures don't abort** | A single failed app install or file copy should not prevent the rest of the migration. All errors are collected and shown in the completion report. |
| **No password export** | Browser password databases (`Login Data`, `logins.json`, `key4.db`) are never touched. This is a deliberate security decision. |
| **HTML reports** (no JS) | Self-contained, opens in any browser, no dependencies. CSS `conic-gradient` for pie charts. |

---

## Known Limitations

- **Passwords** are never migrated (browser passwords, Windows credentials). Users must re-enter these on the target machine.
- **Windows Settings** protection: Windows 10+ protects file association `UserChoice` entries with a hash that cannot be reproduced externally. File associations are restored on a best-effort basis.
- **Ninite free tier** does not provide granular exit codes or CLI control. Failures may not be precisely reported.
- **Store apps** that require specific hardware or account entitlements may fail to install via `winget --source msstore`.
- **Taskbar pins**: Windows 11 taskbar pin restoration is best-effort due to OS-level protections on the `Taskband` registry data.
- **CLI mode** is not yet implemented. The tool currently runs only as a GUI wizard.
- **SugarSync and Direct Network** transfer are planned but not yet implemented as storage targets.

---

## License

MIT -- see [LICENSE](LICENSE).
