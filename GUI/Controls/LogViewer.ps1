<#
========================================================================================================
    Title:          Win11Migrator - Log Viewer Control
    Filename:       LogViewer.ps1
    Description:    Code-behind for the LogViewer control with auto-scrolling and level-based coloring.
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
    Code-behind for the LogViewer control with auto-scrolling and level-based coloring.
#>

function Initialize-LogViewer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Control,
        [int]$MaxLines = 1000
    )

    $txtLogContent = $Control.FindName('txtLogContent')
    $chkAutoScroll = $Control.FindName('chkAutoScroll')
    $btnClearLog = $Control.FindName('btnClearLog')

    $lineCount = 0

    $btnClearLog.Add_Click({
        $txtLogContent.Clear()
        $lineCount = 0
    }.GetNewClosure())

    # Return append function for external use
    return {
        param([string]$Entry)

        $txtLogContent.AppendText("$Entry`n")
        $lineCount++

        # Trim if too many lines
        if ($lineCount -gt $MaxLines) {
            $text = $txtLogContent.Text
            $firstNewline = $text.IndexOf("`n")
            if ($firstNewline -ge 0) {
                $txtLogContent.Text = $text.Substring($firstNewline + 1)
                $lineCount--
            }
        }

        # Auto-scroll
        if ($chkAutoScroll.IsChecked) {
            $txtLogContent.ScrollToEnd()
        }
    }.GetNewClosure()
}

function Update-LogViewerFromQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$AppendFunc,
        [int]$MaxEntries = 20
    )

    $entries = Get-LogEntries -MaxEntries $MaxEntries
    foreach ($entry in $entries) {
        & $AppendFunc $entry
    }
}
