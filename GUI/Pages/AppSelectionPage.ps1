<#
========================================================================================================
    Title:          Win11Migrator - Application Selection Page
    Filename:       AppSelectionPage.ps1
    Description:    Displays discovered applications with checkboxes for user selection before migration.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1

function Initialize-AppSelectionPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Page,
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    # Store all controls in a single hashtable so closures can access them
    $ui = @{
        Search     = $Page.FindName('txtSearch')
        SelectAll  = $Page.FindName('btnSelectAll')
        DeselectAll= $Page.FindName('btnDeselectAll')
        Count      = $Page.FindName('txtSelectedCount')
        List       = $Page.FindName('listApps')
        Summary    = $Page.FindName('txtSummary')
    }

    # Debug: verify controls loaded
    foreach ($key in $ui.Keys) {
        if (-not $ui[$key]) { Write-Host "[WARN] AppSelection control '$key' is null" -ForegroundColor Yellow }
    }

    Write-Host "[APPS] Loading $($State.Apps.Count) apps into list" -ForegroundColor Cyan

    # Populate list
    $ui.List.ItemsSource = $State.Apps

    # Update selected count display
    $updateCount = {
        param($uiRef, $stateRef)
        $selected = @($stateRef.Apps | Where-Object { $_.Selected }).Count
        $total = $stateRef.Apps.Count
        if ($uiRef.Count) { $uiRef.Count.Text = "$selected of $total selected" }

        $auto = @($stateRef.Apps | Where-Object { $_.Selected -and $_.InstallMethod -and $_.InstallMethod -ne 'Manual' }).Count
        $manual = @($stateRef.Apps | Where-Object { $_.Selected -and ($_.InstallMethod -eq 'Manual' -or -not $_.InstallMethod) }).Count
        $excludedDrivers = if ($stateRef.ExcludedDriverCount) { $stateRef.ExcludedDriverCount } else { 0 }
        $totalRaw = if ($stateRef.TotalRawAppCount) { $stateRef.TotalRawAppCount } else { $total }
        $autoPct = if ($total -gt 0) { [Math]::Round(($auto / $total) * 100, 1) } else { 0 }

        $summary = "$auto auto-install ($autoPct%), $manual manual"
        if ($excludedDrivers -gt 0) {
            $summary += " | $excludedDrivers drivers/system components excluded"
        }
        if ($uiRef.Summary) { $uiRef.Summary.Text = $summary }
    }

    & $updateCount $ui $State

    # Handle checkbox Checked/Unchecked via routed events (TwoWay binding doesn't work without INotifyPropertyChanged)
    $ui.List.AddHandler(
        [System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent,
        [System.Windows.RoutedEventHandler]{
            param($sender, $e)
            $cb = $e.OriginalSource
            if ($cb -is [System.Windows.Controls.CheckBox] -and $cb.DataContext -and $cb.DataContext.PSObject.Properties['Selected']) {
                $cb.DataContext.Selected = $true
                & $updateCount $ui $State
            }
        }.GetNewClosure()
    )
    $ui.List.AddHandler(
        [System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,
        [System.Windows.RoutedEventHandler]{
            param($sender, $e)
            $cb = $e.OriginalSource
            if ($cb -is [System.Windows.Controls.CheckBox] -and $cb.DataContext -and $cb.DataContext.PSObject.Properties['Selected']) {
                $cb.DataContext.Selected = $false
                & $updateCount $ui $State
            }
        }.GetNewClosure()
    )

    # Search filter
    $ui.Search.Add_TextChanged({
        $filter = $ui.Search.Text.Trim()
        if ([string]::IsNullOrEmpty($filter)) {
            $ui.List.ItemsSource = $State.Apps
        } else {
            $filtered = @($State.Apps | Where-Object {
                $_.Name -like "*$filter*" -or
                $_.Publisher -like "*$filter*" -or
                ($_.InstallMethod -and $_.InstallMethod -like "*$filter*")
            })
            $ui.List.ItemsSource = $filtered
        }
    }.GetNewClosure())

    # Select All
    $ui.SelectAll.Add_Click({
        foreach ($app in $State.Apps) { $app.Selected = $true }
        # Refresh the list binding
        $ui.List.ItemsSource = $null
        $ui.List.ItemsSource = $State.Apps
        & $updateCount $ui $State
    }.GetNewClosure())

    # Deselect All
    $ui.DeselectAll.Add_Click({
        foreach ($app in $State.Apps) { $app.Selected = $false }
        $ui.List.ItemsSource = $null
        $ui.List.ItemsSource = $State.Apps
        & $updateCount $ui $State
    }.GetNewClosure())
}
