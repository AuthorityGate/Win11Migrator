<#
========================================================================================================
    Title:          Win11Migrator - Import Source Selection Page
    Filename:       ImportSourcePage.ps1
    Description:    Allows users to select a migration package source for import on the target machine.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-ImportSourcePage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $txtPackagePath = $Page.FindName('txtPackagePath')
    $btnBrowsePackage = $Page.FindName('btnBrowsePackage')
    $panelDetectedSources = $Page.FindName('panelDetectedSources')
    $panelPackageInfo = $Page.FindName('panelPackageInfo')
    $txtSourceComputer = $Page.FindName('txtSourceComputer')
    $txtExportDate = $Page.FindName('txtExportDate')
    $txtSourceOS = $Page.FindName('txtSourceOS')
    $txtAppCount = $Page.FindName('txtAppCount')
    $txtDataCount = $Page.FindName('txtDataCount')
    $txtSourceUser = $Page.FindName('txtSourceUser')

    $State.BtnNext.IsEnabled = $false

    $loadManifest = {
        param([string]$PkgPath)

        # Check if this is an encrypted package file
        if ((Test-Path $PkgPath) -and -not (Test-Path (Join-Path $PkgPath "manifest.json"))) {
            # Might be an encrypted .w11mcrypt file or a directory without manifest
            $w11mFiles = @(Get-ChildItem $PkgPath -Filter "*.w11mcrypt" -ErrorAction SilentlyContinue)
            if ($w11mFiles.Count -gt 0) {
                # Prompt for password
                $pwdDialog = [System.Windows.MessageBox]::Show(
                    "Encrypted migration package detected.`nYou will be prompted for the decryption password.",
                    "Encrypted Package",
                    [System.Windows.MessageBoxButton]::OKCancel,
                    [System.Windows.MessageBoxImage]::Information
                )
                if ($pwdDialog -eq [System.Windows.MessageBoxResult]::Cancel) { return }

                # Use a simple input for password (in production, use a proper dialog)
                try {
                    $encFile = $w11mFiles[0].FullName
                    $decryptDir = Join-Path $PkgPath "Decrypted"
                    # For now, log that decryption would happen here
                    # The actual password prompt would need a custom WPF dialog
                    Write-MigrationLog -Message "Encrypted package detected: $encFile" -Level Info
                } catch {
                    [System.Windows.MessageBox]::Show(
                        "Decryption failed: $($_.Exception.Message)",
                        "Error",
                        [System.Windows.MessageBoxButton]::OK,
                        [System.Windows.MessageBoxImage]::Error
                    )
                    return
                }
            }
        }

        $manifestFile = Join-Path $PkgPath "manifest.json"
        if (-not (Test-Path $manifestFile)) {
            [System.Windows.MessageBox]::Show(
                "No manifest.json found in the selected folder.`nPlease select the root folder of a Win11Migrator package.",
                "Invalid Package",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            )
            return
        }

        try {
            $manifest = Read-MigrationManifest -ManifestPath $manifestFile
            $State.Manifest = $manifest
            $State.PackagePath = $PkgPath
            $State.Apps = $manifest.Apps
            $State.UserData = $manifest.UserData
            $State.BrowserProfiles = $manifest.BrowserProfiles
            $State.SystemSettings = $manifest.SystemSettings
            $State.AppProfiles = if ($manifest.AppProfiles) { $manifest.AppProfiles } else { @() }

            $txtPackagePath.Text = $PkgPath
            $panelPackageInfo.Visibility = 'Visible'
            $txtSourceComputer.Text = $manifest.SourceComputerName
            $txtExportDate.Text = $manifest.ExportDate
            $txtSourceOS.Text = $manifest.SourceOSVersion
            $txtAppCount.Text = "$($manifest.Apps.Count) applications"
            $txtDataCount.Text = "$($manifest.UserData.Count) folders, $($manifest.BrowserProfiles.Count) browser profiles, $($manifest.SystemSettings.Count) settings"
            $txtSourceUser.Text = $manifest.SourceUserName

            $State.BtnNext.IsEnabled = $true
            Write-MigrationLog -Message "Package loaded from $PkgPath" -Level Success
        } catch {
            [System.Windows.MessageBox]::Show(
                "Error reading manifest: $($_.Exception.Message)",
                "Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        }
    }

    # Browse button
    $btnBrowsePackage.Add_Click({
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = "Select the Win11Migrator migration package folder"
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            & $loadManifest $dialog.SelectedPath
        }
    }.GetNewClosure())

    # Auto-detect packages on USB drives and cloud folders
    $searchPaths = @()

    # Check USB drives
    try {
        $usbDrives = Get-USBDrives
        foreach ($drive in $usbDrives) {
            $searchPaths += "$($drive.DriveLetter.TrimEnd(':')):"
        }
    } catch {}

    # Check cloud sync folders
    try {
        $cloud = Find-CloudSyncFolders
        if ($cloud.OneDrivePath) { $searchPaths += $cloud.OneDrivePath }
        if ($cloud.GoogleDrivePath) { $searchPaths += $cloud.GoogleDrivePath }
    } catch {}

    foreach ($basePath in $searchPaths) {
        try {
            $migFolders = Get-ChildItem $basePath -Directory -Filter "Win11Migration_*" -ErrorAction SilentlyContinue
            if (-not $migFolders) {
                $migFolders = Get-ChildItem $basePath -Directory -Filter "Win11Migrator" -ErrorAction SilentlyContinue
                if ($migFolders) {
                    $migFolders = Get-ChildItem $migFolders.FullName -Directory -Filter "Win11Migration_*" -ErrorAction SilentlyContinue
                }
            }

            foreach ($folder in $migFolders) {
                $manifestCheck = Join-Path $folder.FullName "manifest.json"
                if (Test-Path $manifestCheck) {
                    $btn = [System.Windows.Controls.Button]::new()
                    $btn.Content = $folder.FullName
                    $btn.Style = $Page.FindResource('SecondaryButton')
                    $btn.HorizontalAlignment = 'Left'
                    $btn.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
                    $btn.Tag = $folder.FullName
                    $btn.Add_Click({
                        & $loadManifest $this.Tag
                    }.GetNewClosure())
                    $panelDetectedSources.Children.Add($btn)
                }
            }
        } catch {}
    }

    if ($panelDetectedSources.Children.Count -eq 0) {
        $noPackages = [System.Windows.Controls.TextBlock]::new()
        $noPackages.Text = "No migration packages detected. Use Browse to locate your package."
        $noPackages.Style = $Page.FindResource('CaptionText')
        $panelDetectedSources.Children.Add($noPackages)
    }
}
