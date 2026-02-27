<#
========================================================================================================
    Title:          Win11Migrator - Progress Panel Control
    Filename:       ProgressPanel.ps1
    Description:    Code-behind for the progress panel control that displays operation status and progress bars.
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
    Code-behind for the ProgressPanel reusable control.
#>

function Initialize-ProgressPanel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Control,
        [string]$PhaseName = "Processing"
    )

    $txtPhase = $Control.FindName('txtPhase')
    $txtPercent = $Control.FindName('txtPercent')
    $progressFill = $Control.FindName('progressFill')
    $txtStatus = $Control.FindName('txtStatus')
    $txtCounter = $Control.FindName('txtCounter')

    $txtPhase.Text = $PhaseName
    $txtPercent.Text = "0%"
    $txtStatus.Text = "Waiting..."
    $txtCounter.Text = ""

    # Return an update function
    return {
        param(
            [int]$Percent,
            [string]$Status,
            [int]$Completed,
            [int]$Total
        )

        $txtPercent.Text = "$Percent%"
        $txtStatus.Text = $Status

        # Animate progress bar width
        $maxWidth = $progressFill.Parent.ActualWidth
        if ($maxWidth -gt 0) {
            $progressFill.Width = ($maxWidth * $Percent / 100)
        }

        if ($Total -gt 0) {
            $txtCounter.Text = "$Completed of $Total"
        }

        # Color changes at completion
        if ($Percent -ge 100) {
            $progressFill.Background = [System.Windows.Media.SolidColorBrush]::new(
                [System.Windows.Media.ColorConverter]::ConvertFromString('#107C10'))
            $txtPercent.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                [System.Windows.Media.ColorConverter]::ConvertFromString('#107C10'))
        }
    }.GetNewClosure()
}
