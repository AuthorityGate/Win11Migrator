<#
========================================================================================================
    Title:          Win11Migrator - Network Target Selection Page
    Filename:       NetworkTargetPage.ps1
    Description:    Lets users discover and select a target computer for direct network migration.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 27, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-NetworkTargetPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    # Store controls in hashtable for closure access
    $ui = @{
        BtnScanNetwork    = $Page.FindName('btnScanNetwork')
        LstComputers      = $Page.FindName('lstComputers')
        TxtScanStatus     = $Page.FindName('txtScanStatus')
        TxtHostname       = $Page.FindName('txtHostname')
        TxtUsername        = $Page.FindName('txtUsername')
        TxtPassword       = $Page.FindName('txtPassword')
        TxtTargetUser     = $Page.FindName('txtTargetUser')
        BtnTestConnection = $Page.FindName('btnTestConnection')
        TxtConnStatus     = $Page.FindName('txtConnectionStatus')
    }

    $State.BtnNext.IsEnabled = $false

    # -------------------------------------------------------------------------
    # Scan Network button
    # -------------------------------------------------------------------------
    $ui.BtnScanNetwork.Add_Click({
        Write-MigrationLog -Message "User clicked Scan Network" -Level Info
        $ui.BtnScanNetwork.IsEnabled = $false
        $ui.TxtScanStatus.Text = 'Scanning network, please wait...'
        $ui.LstComputers.Items.Clear()

        try {
            $computers = Find-NetworkComputers -TimeoutMs 1000
            $State['DiscoveredComputers'] = $computers

            if ($computers -and @($computers).Count -gt 0) {
                foreach ($pc in $computers) {
                    $ui.LstComputers.Items.Add([PSCustomObject]@{
                        ComputerName = $pc.ComputerName
                        IPAddress    = $pc.IPAddress
                        OS           = $pc.OS
                        Online       = $pc.Online
                    }) | Out-Null
                }
                $onlineCount = @($computers | Where-Object { $_.Online }).Count
                $ui.TxtScanStatus.Text = "Found $($computers.Count) computer(s), $onlineCount online."
                Write-MigrationLog -Message "Network scan found $($computers.Count) computer(s)" -Level Info
            } else {
                $ui.TxtScanStatus.Text = 'No computers found. Try entering a hostname manually.'
                Write-MigrationLog -Message "Network scan found no computers" -Level Warning
            }
        } catch {
            $ui.TxtScanStatus.Text = "Scan failed: $($_.Exception.Message)"
            Write-MigrationLog -Message "Network scan error: $($_.Exception.Message)" -Level Error
        }

        $ui.BtnScanNetwork.IsEnabled = $true
    }.GetNewClosure())

    # -------------------------------------------------------------------------
    # Computer list selection changed
    # -------------------------------------------------------------------------
    $ui.LstComputers.Add_SelectionChanged({
        $selected = $ui.LstComputers.SelectedItem
        if ($selected) {
            $ui.TxtHostname.Text = $selected.ComputerName
            Write-MigrationLog -Message "User selected computer: $($selected.ComputerName)" -Level Debug
        }
    }.GetNewClosure())

    # -------------------------------------------------------------------------
    # Test Connection button
    # -------------------------------------------------------------------------
    $ui.BtnTestConnection.Add_Click({
        $hostname = $ui.TxtHostname.Text.Trim()
        $username = $ui.TxtUsername.Text.Trim()
        $password = $ui.TxtPassword.Password
        $targetUser = $ui.TxtTargetUser.Text.Trim()

        # Validate inputs
        if ([string]::IsNullOrWhiteSpace($hostname)) {
            $ui.TxtConnStatus.Text = 'Please enter a hostname or IP address.'
            $ui.TxtConnStatus.Foreground = $Page.FindResource('ErrorBrush')
            return
        }

        if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
            $ui.TxtConnStatus.Text = 'Please enter both username and password.'
            $ui.TxtConnStatus.Foreground = $Page.FindResource('ErrorBrush')
            return
        }

        if ([string]::IsNullOrWhiteSpace($targetUser)) {
            $ui.TxtConnStatus.Text = 'Please enter the target user account name.'
            $ui.TxtConnStatus.Foreground = $Page.FindResource('ErrorBrush')
            return
        }

        Write-MigrationLog -Message "User clicked Test Connection for '$hostname'" -Level Info
        $ui.BtnTestConnection.IsEnabled = $false
        $ui.TxtConnStatus.Text = 'Testing connection...'
        $ui.TxtConnStatus.Foreground = $Page.FindResource('TextSecondaryBrush')

        try {
            # Build credential
            $secPassword = ConvertTo-SecureString $password -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential($username, $secPassword)

            # Run connectivity test
            $testResult = Test-RemoteAccess -ComputerName $hostname -Credential $cred -TimeoutMs 5000

            if ($testResult.PSSessionAvailable -or $testResult.AdminShareAvailable) {
                # Determine best access method
                $accessMethod = 'AdminShare'
                if ($testResult.PSSessionAvailable) { $accessMethod = 'WinRM' }

                $statusParts = @()
                if ($testResult.Reachable)          { $statusParts += 'Ping OK' }
                if ($testResult.WinRMAvailable)     { $statusParts += 'WinRM OK' }
                if ($testResult.AdminShareAvailable) { $statusParts += 'Admin Share OK' }
                if ($testResult.PSSessionAvailable) { $statusParts += 'PSSession OK' }

                $ui.TxtConnStatus.Text = "Connected successfully. [$($statusParts -join ', ')]"
                $ui.TxtConnStatus.Foreground = $Page.FindResource('SuccessBrush')

                # Store network target in state
                $State.NetworkTarget = @{
                    ComputerName   = $hostname
                    Credential     = $cred
                    TargetUserName = $targetUser
                    AccessMethod   = $accessMethod
                }

                $State.BtnNext.IsEnabled = $true
                Write-MigrationLog -Message "Connection test passed for '$hostname' via $accessMethod" -Level Info
            } else {
                $ui.TxtConnStatus.Text = "Connection failed. $($testResult.ErrorMessage)"
                $ui.TxtConnStatus.Foreground = $Page.FindResource('ErrorBrush')
                $State.BtnNext.IsEnabled = $false
                Write-MigrationLog -Message "Connection test failed for '$hostname': $($testResult.ErrorMessage)" -Level Warning
            }
        } catch {
            $ui.TxtConnStatus.Text = "Error: $($_.Exception.Message)"
            $ui.TxtConnStatus.Foreground = $Page.FindResource('ErrorBrush')
            $State.BtnNext.IsEnabled = $false
            Write-MigrationLog -Message "Connection test error: $($_.Exception.Message)" -Level Error
        }

        $ui.BtnTestConnection.IsEnabled = $true
    }.GetNewClosure())

    Write-MigrationLog -Message "Network target page initialized" -Level Info
    Write-Host "[NETWORK] Network target selection page initialized" -ForegroundColor Cyan
}
