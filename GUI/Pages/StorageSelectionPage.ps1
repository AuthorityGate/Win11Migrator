<#
========================================================================================================
    Title:          Win11Migrator - Storage Target Selection Page
    Filename:       StorageSelectionPage.ps1
    Description:    Lets users choose a storage target (USB drive, OneDrive, or Google Drive) for the migration package.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-StorageSelectionPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    # Store controls in hashtable for closure access
    $ui = @{
        CardUSB       = $Page.FindName('cardUSB')
        TxtUSBStatus  = $Page.FindName('txtUSBStatus')
        CboUSBDrives  = $Page.FindName('cboUSBDrives')
        CardOneDrive  = $Page.FindName('cardOneDrive')
        TxtODStatus   = $Page.FindName('txtOneDriveStatus')
        TxtODPath     = $Page.FindName('txtOneDrivePath')
        CardGDrive    = $Page.FindName('cardGoogleDrive')
        TxtGDStatus   = $Page.FindName('txtGDriveStatus')
        TxtGDPath     = $Page.FindName('txtGDrivePath')
        CardNetShare  = $Page.FindName('cardNetworkShare')
        TxtNetPath    = $Page.FindName('txtNetworkPath')
        CardCustom    = $Page.FindName('cardCustom')
        BtnBrowse     = $Page.FindName('btnBrowse')
        CardNetDirect = $Page.FindName('cardNetworkDirect')
        ChkEncrypt    = $Page.FindName('chkEncrypt')
        PanelEncPwd   = $Page.FindName('panelEncryptPassword')
        TxtEncPwd     = $Page.FindName('txtEncryptPassword')
        TxtEncPwdConf = $Page.FindName('txtEncryptPasswordConfirm')
        TxtEncErr     = $Page.FindName('txtEncryptError')
    }

    $State.BtnNext.IsEnabled = $false

    # Card selection helper - highlights selected card
    $allCards = @($ui.CardUSB, $ui.CardOneDrive, $ui.CardGDrive, $ui.CardNetShare, $ui.CardCustom, $ui.CardNetDirect)

    # Detect USB drives
    Write-Host "[STORAGE] Detecting USB drives..." -ForegroundColor Cyan
    try {
        $usbDrives = Get-USBDrives
        if ($usbDrives -and @($usbDrives).Count -gt 0) {
            $usbDrives = @($usbDrives)
            if ($ui.TxtUSBStatus) { $ui.TxtUSBStatus.Text = "$($usbDrives.Count) USB drive(s) available" }
            if ($ui.CboUSBDrives) {
                $ui.CboUSBDrives.Visibility = 'Visible'
                foreach ($drive in $usbDrives) {
                    $label = "$($drive.DriveLetter) $($drive.Label) ($($drive.FreeGB) GB free)"
                    $ui.CboUSBDrives.Items.Add($label) | Out-Null
                }
                $ui.CboUSBDrives.SelectedIndex = 0
            }
            $State['USBDrives'] = $usbDrives
            Write-Host "[STORAGE] Found $($usbDrives.Count) USB drive(s)" -ForegroundColor Green
        } else {
            if ($ui.TxtUSBStatus) { $ui.TxtUSBStatus.Text = "No USB drives detected" }
            if ($ui.CardUSB) { $ui.CardUSB.Opacity = 0.5 }
            Write-Host "[STORAGE] No USB drives found" -ForegroundColor Yellow
        }
    } catch {
        if ($ui.TxtUSBStatus) { $ui.TxtUSBStatus.Text = "Unable to detect USB drives" }
        if ($ui.CardUSB) { $ui.CardUSB.Opacity = 0.5 }
        Write-Host "[STORAGE] USB detection error: $($_.Exception.Message)" -ForegroundColor Red
    }

    # Detect cloud sync folders
    Write-Host "[STORAGE] Detecting cloud sync folders..." -ForegroundColor Cyan
    try {
        $cloudFolders = Find-CloudSyncFolders
        if ($cloudFolders.OneDrivePath -and (Test-Path $cloudFolders.OneDrivePath)) {
            if ($ui.TxtODStatus) { $ui.TxtODStatus.Text = "OneDrive sync folder found" }
            if ($ui.TxtODPath) { $ui.TxtODPath.Text = $cloudFolders.OneDrivePath }
            $State['OneDrivePath'] = $cloudFolders.OneDrivePath
            Write-Host "[STORAGE] OneDrive: $($cloudFolders.OneDrivePath)" -ForegroundColor Green
        } else {
            if ($ui.TxtODStatus) { $ui.TxtODStatus.Text = "OneDrive not available" }
            if ($ui.CardOneDrive) { $ui.CardOneDrive.Opacity = 0.5 }
        }

        if ($cloudFolders.GoogleDrivePath -and (Test-Path $cloudFolders.GoogleDrivePath)) {
            if ($ui.TxtGDStatus) { $ui.TxtGDStatus.Text = "Google Drive sync folder found" }
            if ($ui.TxtGDPath) { $ui.TxtGDPath.Text = $cloudFolders.GoogleDrivePath }
            $State['GoogleDrivePath'] = $cloudFolders.GoogleDrivePath
            Write-Host "[STORAGE] Google Drive: $($cloudFolders.GoogleDrivePath)" -ForegroundColor Green
        } else {
            if ($ui.TxtGDStatus) { $ui.TxtGDStatus.Text = "Google Drive not available" }
            if ($ui.CardGDrive) { $ui.CardGDrive.Opacity = 0.5 }
        }
    } catch {
        if ($ui.TxtODStatus) { $ui.TxtODStatus.Text = "Detection failed" }
        if ($ui.TxtGDStatus) { $ui.TxtGDStatus.Text = "Detection failed" }
        Write-Host "[STORAGE] Cloud detection error: $($_.Exception.Message)" -ForegroundColor Red
    }

    # Helper: remove NetworkTargetPage when switching away from NetworkDirect
    $removeNetPage = { if ($State.RemoveNetworkPage) { & $State.RemoveNetworkPage $State } }

    # Card click handlers
    $ui.CardUSB.Add_MouseLeftButtonUp({
        if ($ui.CardUSB.Opacity -ge 1) {
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardUSB.BorderBrush = $Page.FindResource('PrimaryBrush')
            & $removeNetPage
            $State.BtnNext.IsEnabled = $true
            $driveIdx = $ui.CboUSBDrives.SelectedIndex
            if ($driveIdx -ge 0 -and $State.USBDrives) {
                $State.StorageTarget = @{ Type = 'USB'; Path = "$($State.USBDrives[$driveIdx].DriveLetter)\" }
            }
        }
    }.GetNewClosure())

    $ui.CardOneDrive.Add_MouseLeftButtonUp({
        if ($ui.CardOneDrive.Opacity -ge 1) {
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardOneDrive.BorderBrush = $Page.FindResource('PrimaryBrush')
            & $removeNetPage
            $State.BtnNext.IsEnabled = $true
            $State.StorageTarget = @{ Type = 'OneDrive'; Path = $State.OneDrivePath }
        }
    }.GetNewClosure())

    $ui.CardGDrive.Add_MouseLeftButtonUp({
        if ($ui.CardGDrive.Opacity -ge 1) {
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardGDrive.BorderBrush = $Page.FindResource('PrimaryBrush')
            & $removeNetPage
            $State.BtnNext.IsEnabled = $true
            $State.StorageTarget = @{ Type = 'GoogleDrive'; Path = $State.GoogleDrivePath }
        }
    }.GetNewClosure())

    # Network Share card
    if ($ui.CardNetShare) {
        $ui.CardNetShare.Add_MouseLeftButtonUp({
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardNetShare.BorderBrush = $Page.FindResource('PrimaryBrush')
            & $removeNetPage
            $uncPath = $ui.TxtNetPath.Text.Trim()
            if ($uncPath -match '^\\\\[^\\]+\\[^\\]+') {
                $State.StorageTarget = @{ Type = 'NetworkShare'; Path = $uncPath }
                $State.BtnNext.IsEnabled = $true
            } else {
                $State.BtnNext.IsEnabled = $false
            }
        }.GetNewClosure())

        # Also validate on text change
        if ($ui.TxtNetPath) {
            $ui.TxtNetPath.Add_TextChanged({
                $uncPath = $ui.TxtNetPath.Text.Trim()
                if ($uncPath -match '^\\\\[^\\]+\\[^\\]+' -and $ui.CardNetShare.BorderBrush -eq $Page.FindResource('PrimaryBrush')) {
                    $State.StorageTarget = @{ Type = 'NetworkShare'; Path = $uncPath }
                    $State.BtnNext.IsEnabled = $true
                }
            }.GetNewClosure())
        }
    }

    $ui.CardCustom.Add_MouseLeftButtonUp({
        foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
        $ui.CardCustom.BorderBrush = $Page.FindResource('PrimaryBrush')
        & $removeNetPage
        # Don't enable Next until Browse dialog succeeds and sets StorageTarget
    }.GetNewClosure())

    $ui.BtnBrowse.Add_Click({
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = "Select a folder for the migration package"
        $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $State.StorageTarget = @{ Type = 'Custom'; Path = $dialog.SelectedPath }
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardCustom.BorderBrush = $Page.FindResource('PrimaryBrush')
            $State.BtnNext.IsEnabled = $true
        }
    }.GetNewClosure())

    # Direct Network Transfer card
    if ($ui.CardNetDirect) {
        $ui.CardNetDirect.Add_MouseLeftButtonUp({
            foreach ($c in $allCards) { $c.BorderBrush = $Page.FindResource('BorderBrush') }
            $ui.CardNetDirect.BorderBrush = $Page.FindResource('PrimaryBrush')
            $State.StorageTarget = @{ Type = 'NetworkDirect'; Path = '' }
            # Insert NetworkTargetPage into the wizard so user is prompted for hostname/credentials
            if ($State.InsertNetworkPage) { & $State.InsertNetworkPage $State }
            $State.BtnNext.IsEnabled = $true
        }.GetNewClosure())
    }

    # Encryption checkbox
    if ($ui.ChkEncrypt) {
        $ui.ChkEncrypt.Add_Checked({
            $ui.PanelEncPwd.Visibility = 'Visible'
            $State['EncryptPackage'] = $true
        }.GetNewClosure())
        $ui.ChkEncrypt.Add_Unchecked({
            $ui.PanelEncPwd.Visibility = 'Collapsed'
            $State['EncryptPackage'] = $false
            $State['EncryptPassword'] = $null
        }.GetNewClosure())
    }

    # Validate encryption passwords on text change
    if ($ui.TxtEncPwd -and $ui.TxtEncPwdConf) {
        $validatePasswords = {
            if ($State.EncryptPackage) {
                $pwd1 = $ui.TxtEncPwd.Password
                $pwd2 = $ui.TxtEncPwdConf.Password
                if ([string]::IsNullOrEmpty($pwd1)) {
                    $ui.TxtEncErr.Text = "Password is required"
                    $State['EncryptPassword'] = $null
                } elseif ($pwd1.Length -lt 8) {
                    $ui.TxtEncErr.Text = "Password must be at least 8 characters"
                    $State['EncryptPassword'] = $null
                } elseif ($pwd1 -ne $pwd2) {
                    $ui.TxtEncErr.Text = "Passwords do not match"
                    $State['EncryptPassword'] = $null
                } else {
                    $ui.TxtEncErr.Text = ""
                    $State['EncryptPassword'] = ConvertTo-SecureString $pwd1 -AsPlainText -Force
                }
            }
        }.GetNewClosure()
        $ui.TxtEncPwd.Add_PasswordChanged($validatePasswords)
        $ui.TxtEncPwdConf.Add_PasswordChanged($validatePasswords)
    }

    Write-Host "[STORAGE] Storage selection page initialized" -ForegroundColor Cyan
}
