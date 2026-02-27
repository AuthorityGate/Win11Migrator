<#
========================================================================================================
    Title:          Win11Migrator - USMT LoadState Invoker
    Filename:       Invoke-USMTLoadState.ps1
    Description:    Executes USMT loadstate.exe to restore user state data onto the target machine.
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
    Runs USMT loadstate.exe to restore user profiles, files, and settings from a migration store.
.DESCRIPTION
    Builds and executes the loadstate.exe command with the specified migration
    XMLs and options. Supports store decryption, user mapping, local account
    creation, custom XMLs, and configurable verbosity. Monitors the process
    exit code against known USMT return codes and logs the outcome.
.OUTPUTS
    [hashtable] with Success, ExitCode, LogFile, and ErrorMessage keys.
#>

function Invoke-USMTLoadState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LoadStatePath,

        [Parameter(Mandatory)]
        [string]$StorePath,

        [string[]]$MigrationXmls,

        [string]$CustomXml,

        [switch]$DecryptStore,

        [securestring]$DecryptKey,

        [string]$UserMapping,

        [switch]$CreateLocalAccount,

        [int]$Verbosity = 13,

        [string]$LogPath
    )

    Write-MigrationLog -Message "Preparing USMT LoadState restore from: $StorePath" -Level Info

    # Validate loadstate.exe exists
    if (-not (Test-Path -Path $LoadStatePath -PathType Leaf)) {
        Write-MigrationLog -Message "loadstate.exe not found: $LoadStatePath" -Level Error
        return @{
            Success      = $false
            ExitCode     = -1
            LogFile      = ''
            ErrorMessage = "loadstate.exe not found at: $LoadStatePath"
        }
    }

    # Validate store path exists
    if (-not (Test-Path -Path $StorePath)) {
        Write-MigrationLog -Message "USMT store not found: $StorePath" -Level Error
        return @{
            Success      = $false
            ExitCode     = -1
            LogFile      = ''
            ErrorMessage = "USMT store not found at: $StorePath"
        }
    }

    # Set default log path if not specified
    if (-not $LogPath) {
        $LogPath = Join-Path -Path $StorePath -ChildPath 'loadstate.log'
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

    # Verbosity
    [void]$arguments.Add("/v:$Verbosity")

    # Continue on errors
    [void]$arguments.Add('/c')

    # Log file
    [void]$arguments.Add("/l:`"$LogPath`"")

    # Store decryption
    if ($DecryptStore -and $DecryptKey) {
        $keyPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($DecryptKey)
        )
        [void]$arguments.Add('/decrypt')
        [void]$arguments.Add("/key:$keyPlain")
        $keyPlain = $null
        Write-MigrationLog -Message "Store decryption enabled" -Level Debug
    } elseif ($DecryptStore) {
        Write-MigrationLog -Message "DecryptStore specified but no DecryptKey provided, skipping decryption" -Level Warning
    }

    # User mapping
    if ($UserMapping) {
        [void]$arguments.Add("/mu:$UserMapping")
        Write-MigrationLog -Message "User mapping configured: $UserMapping" -Level Debug
    }

    # Local account creation
    if ($CreateLocalAccount) {
        [void]$arguments.Add('/lac')
        [void]$arguments.Add('/lae')
        Write-MigrationLog -Message "Local account creation and enable flags set" -Level Debug
    }

    $argString = $arguments -join ' '
    # Log arguments with encryption key masked
    $safeArgString = $argString -replace '/key:\S+', '/key:********'
    Write-MigrationLog -Message "LoadState command: `"$LoadStatePath`" $safeArgString" -Level Debug

    # ---- Execute loadstate.exe ----
    try {
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName               = $LoadStatePath
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
            0       { 'Success: LoadState completed without errors' }
            26      { 'Some data failed to restore but process completed' }
            27      { 'Insufficient disk space' }
            29      { 'LoadState requires admin privileges' }
            31      { 'Store is not accessible' }
            32      { 'Another migration is in progress' }
            33      { 'Encryption key mismatch or decryption failed' }
            34      { 'Config XML syntax error' }
            35      { 'USMT could not write progress data' }
            36      { 'Store path is not accessible' }
            37      { 'Incompatible USMT versions between scanstate and loadstate' }
            38      { 'Object already exists in the destination' }
            39      { 'Target user profile not found' }
            40      { 'Invalid command line' }
            41      { 'Store file is corrupted or invalid' }
            61      { 'USMT could not apply user profile settings' }
            71      { 'USMT store was corrupted during restore' }
            default { "Unknown exit code: $exitCode" }
        }

        if ($exitCode -eq 0) {
            Write-MigrationLog -Message "LoadState completed successfully" -Level Success
        } elseif ($exitCode -eq 26) {
            Write-MigrationLog -Message "LoadState completed with warnings: $exitMessage" -Level Warning
        } else {
            Write-MigrationLog -Message "LoadState failed (exit code $exitCode): $exitMessage" -Level Error
            if ($stderr) {
                Write-MigrationLog -Message "LoadState stderr: $stderr" -Level Error
            }
        }

        return @{
            Success      = ($exitCode -eq 0 -or $exitCode -eq 26)
            ExitCode     = $exitCode
            LogFile      = $LogPath
            ErrorMessage = if ($exitCode -eq 0) { '' } else { $exitMessage }
        }

    } catch {
        Write-MigrationLog -Message "Failed to execute loadstate.exe: $($_.Exception.Message)" -Level Error
        return @{
            Success      = $false
            ExitCode     = -1
            LogFile      = $LogPath
            ErrorMessage = $_.Exception.Message
        }
    }
}
