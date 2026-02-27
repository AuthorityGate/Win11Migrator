<#
========================================================================================================
    Title:          Win11Migrator - Application List Item Control
    Filename:       AppListItem.ps1
    Description:    Code-behind for the AppListItem custom control used in application selection.
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
    Code-behind for the AppListItem custom control.
#>

function Initialize-AppListItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Control,
        [Parameter(Mandatory)]
        [MigrationApp]$App
    )

    $txtAppName = $Control.FindName('txtAppName')
    $txtPublisher = $Control.FindName('txtPublisher')
    $txtVersion = $Control.FindName('txtVersion')
    $txtMethod = $Control.FindName('txtMethod')
    $badgeMethod = $Control.FindName('badgeMethod')
    $txtSource = $Control.FindName('txtSource')
    $chkSelected = $Control.FindName('chkSelected')
    $rootBorder = $Control.FindName('rootBorder')

    $txtAppName.Text = $App.Name
    $txtPublisher.Text = if ($App.Publisher) { $App.Publisher } else { '' }
    $txtVersion.Text = if ($App.Version) { $App.Version } else { '' }
    $txtMethod.Text = if ($App.InstallMethod) { $App.InstallMethod } else { 'Unknown' }
    $txtSource.Text = if ($App.Source) { $App.Source } else { '' }
    $chkSelected.IsChecked = $App.Selected

    # Color-code the install method badge
    $methodColors = @{
        'Winget'         = @{ Bg = '#E1EFFA'; Fg = '#0078D4' }
        'Chocolatey'     = @{ Bg = '#FFF4CE'; Fg = '#8B6914' }
        'Ninite'         = @{ Bg = '#DFF6DD'; Fg = '#107C10' }
        'Store'          = @{ Bg = '#E8E1F5'; Fg = '#6B3FA0' }
        'VendorDownload' = @{ Bg = '#FCE4EC'; Fg = '#C62828' }
        'Manual'         = @{ Bg = '#F5F0E6'; Fg = '#8A8580' }
    }

    $colors = $methodColors[$App.InstallMethod]
    if (-not $colors) { $colors = @{ Bg = '#F5F0E6'; Fg = '#8A8580' } }
    $badgeMethod.Background = [System.Windows.Media.SolidColorBrush]::new(
        [System.Windows.Media.ColorConverter]::ConvertFromString($colors.Bg))
    $txtMethod.Foreground = [System.Windows.Media.SolidColorBrush]::new(
        [System.Windows.Media.ColorConverter]::ConvertFromString($colors.Fg))

    # Bind checkbox
    $chkSelected.Add_Checked({ $App.Selected = $true }.GetNewClosure())
    $chkSelected.Add_Unchecked({ $App.Selected = $false }.GetNewClosure())

    # Hover effect
    $rootBorder.Add_MouseEnter({ $this.Background = [System.Windows.Media.SolidColorBrush]::new(
        [System.Windows.Media.ColorConverter]::ConvertFromString('#F5F5F5')) })
    $rootBorder.Add_MouseLeave({ $this.Background = [System.Windows.Media.Brushes]::Transparent })
}
