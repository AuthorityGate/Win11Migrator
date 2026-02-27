<#
========================================================================================================
    Title:          Win11Migrator - USMT ScanState Invoker
    Filename:       Invoke-USMTScanState.ps1
    Description:    Executes USMT scanstate.exe to capture user state data from the source machine.
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
    Runs USMT scanstate.exe to capture user profiles, files, and settings into a migration store.
.DESCRIPTION
    Builds and executes the scanstate.exe command with the specified migration
    XMLs and options. Supports EFS capture, store encryption, custom XMLs,
    and configurable verbosity. Monitors the process exit code against known
    USMT return codes and logs the outcome.
.OUTPUTS
    [hashtable] with Success, ExitCode, LogFile, StorePath, and ErrorMessage keys.
#>

function Invoke-USMTScanState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScanStatePath,

        [Parameter(Mandatory)]
        [string]$StorePath,

        [string[]]$MigrationXmls,

        [string]$CustomXml,

        [switch]$EFSCopyRaw,

        [switch]$EncryptStore,

        [securestring]$EncryptKey,

        [int]$Verbosity = 13,

        [string]$LogPath
    )

    Write-MigrationLog -Message "Preparing USMT ScanState capture to: $StorePath" -Level Info

    # Validate scanstate.exe exists
    if (-not (Test-Path -Path $ScanStatePath -PathType Leaf)) {
        Write-MigrationLog -Message "scanstate.exe not found: $ScanStatePath" -Level Error
        return @{
            Success      = $false
            ExitCode     = -1
            LogFile      = ''
            StorePath    = $StorePath
            ErrorMessage = "scanstate.exe not found at: $ScanStatePath"
        }
    }

    # Ensure store directory exists
    if (-not (Test-Path -Path $StorePath)) {
        New-Item -Path $StorePath -ItemType Directory -Force | Out-Null
        Write-MigrationLog -Message "Created USMT store directory: $StorePath" -Level Debug
    }

    # Set default log path if not specified
    if (-not $LogPath) {
        $LogPath = Join-Path -Path $StorePath -ChildPath 'scanstate.log'
    }

    # ---- Build argument list ----
    $arguments = [System.Collections.ArrayList]::new()

    # Store path (first positional argument)
    [void]$arguments.Add("`"$StorePath`"")

    # Migration XML includes
    if ($MigrationXmls) {
        foreach ($xml in $MigrationXmls) {
            if (Test-Path -Path $xml -PathType Leaf) {
                [void]$arguments.Add("/i:`"$xml`"")
            } else {
                Write-MigrationLog -Message "Migration XML not found, skipping: $xml" -Level Warning
            }
        }
    }

    # Custom XML
    if ($CustomXml -and (Test-Path -Path $CustomXml -PathType Leaf)) {
        [void]$arguments.Add("/i:`"$CustomXml`"")
        Write-MigrationLog -Message "Including custom migration XML: $CustomXml" -Level Debug
    } elseif ($CustomXml) {
        Write-MigrationLog -Message "Custom XML not found, skipping: $CustomXml" -Level Warning
    }

    # Overwrite existing store
    [void]$arguments.Add('/o')

    # Verbosity
    [void]$arguments.Add("/v:$Verbosity")

    # Continue on errors
    [void]$arguments.Add('/c')

    # Log file
    [void]$arguments.Add("/l:`"$LogPath`"")

    # EFS handling
    if ($EFSCopyRaw) {
        [void]$arguments.Add('/efs:copyraw')
        Write-MigrationLog -Message "EFS copy raw mode enabled" -Level Debug
    }

    # Store encryption
    if ($EncryptStore -and $EncryptKey) {
        $keyPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($EncryptKey)
        )
        [void]$arguments.Add('/encrypt')
        [void]$arguments.Add("/key:$keyPlain")
        $keyPlain = $null
        Write-MigrationLog -Message "Store encryption enabled" -Level Debug
    } elseif ($EncryptStore) {
        Write-MigrationLog -Message "EncryptStore specified but no EncryptKey provided, skipping encryption" -Level Warning
    }

    $argString = $arguments -join ' '
    # Log arguments with encryption key masked
    $safeArgString = $argString -replace '/key:\S+', '/key:********'
    Write-MigrationLog -Message "ScanState command: `"$ScanStatePath`" $safeArgString" -Level Debug

    # ---- Execute scanstate.exe ----
    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName               = $ScanStatePath
        $processInfo.Arguments              = $argString
        $processInfo.UseShellExecute        = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError  = $true
        $processInfo.CreateNoWindow         = $true

        $process = [System.Diagnostics.Process]::Start($processInfo)
        $stdout  = $process.StandardOutput.ReadToEnd()
        $stderr  = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        $exitCode = $process.ExitCode
        $process.Dispose()

        # Interpret USMT exit codes
        $exitMessage = switch ($exitCode) {
            0       { 'Success: ScanState completed without errors' }
            26      { 'Some data failed to migrate but process completed' }
            27      { 'Insufficient disk space' }
            29      { 'Scanstate requires admin privileges' }
            31      { 'No writable store location' }
            32      { 'Another migration is in progress' }
            33      { 'Encryption key mismatch' }
            34      { 'Config XML syntax error' }
            35      { 'USMT could not write progress data' }
            36      { 'Store path is not accessible' }
            37      { 'Incompatible USMT versions' }
            38      { 'Object already exists in the store' }
            39      { 'User has no profile' }
            40      { 'Invalid command line' }
            71      { 'USMT store was corrupted' }
            default { "Unknown exit code: $exitCode" }
        }

        if ($exitCode -eq 0) {
            Write-MigrationLog -Message "ScanState completed successfully" -Level Success
        } elseif ($exitCode -eq 26) {
            Write-MigrationLog -Message "ScanState completed with warnings: $exitMessage" -Level Warning
        } else {
            Write-MigrationLog -Message "ScanState failed (exit code $exitCode): $exitMessage" -Level Error
            if ($stderr) {
                Write-MigrationLog -Message "ScanState stderr: $stderr" -Level Error
            }
        }

        return @{
            Success      = ($exitCode -eq 0 -or $exitCode -eq 26)
            ExitCode     = $exitCode
            LogFile      = $LogPath
            StorePath    = $StorePath
            ErrorMessage = if ($exitCode -eq 0) { '' } else { $exitMessage }
        }

    } catch {
        Write-MigrationLog -Message "Failed to execute scanstate.exe: $($_.Exception.Message)" -Level Error
        return @{
            Success      = $false
            ExitCode     = -1
            LogFile      = $LogPath
            StorePath    = $StorePath
            ErrorMessage = $_.Exception.Message
        }
    }
}
