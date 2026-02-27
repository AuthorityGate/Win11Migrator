<#
========================================================================================================
    Title:          Win11Migrator - User Certificates Importer
    Filename:       Import-UserCertificates.ps1
    Description:    Restores user certificates to the personal certificate store on the target machine.
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
    Restores user certificates to Cert:\CurrentUser\My on the target machine.
.DESCRIPTION
    Reads exported certificate files (.cer) from the migration package and
    imports them into the current user's personal certificate store via
    Import-Certificate. Returns updated [SystemSetting[]] with ImportStatus.
.OUTPUTS
    [SystemSetting[]]
#>

function Import-UserCertificates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [SystemSetting[]]$Settings
    )

    Write-MigrationLog -Message "Starting user certificates import" -Level Info

    $certDir = Join-Path $PackagePath "UserCertificates"
    if (-not (Test-Path $certDir)) {
        Write-MigrationLog -Message "UserCertificates directory not found at $certDir" -Level Warning
        foreach ($s in $Settings) {
            $s.ImportStatus = 'Skipped'
            if (-not $s.Data) { $s.Data = @{} }
            $s.Data['ImportNote'] = 'Export directory not found'
        }
        return $Settings
    }

    $certStorePath = 'Cert:\CurrentUser\My'

    foreach ($setting in $Settings) {
        if (-not $setting.Selected) {
            $setting.ImportStatus = 'Skipped'
            Write-MigrationLog -Message "Skipping certificate '$($setting.Name)' (not selected)" -Level Debug
            continue
        }

        try {
            $thumbprint = $setting.Data['Thumbprint']
            $exportFileName = $setting.Data['ExportFileName']
            $hasPrivateKey = $setting.Data['HasPrivateKey']

            if (-not $exportFileName) {
                $setting.ImportStatus = 'Skipped'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = 'No exported certificate file available'
                Write-MigrationLog -Message "No export file for certificate $($setting.Name) -- skipping" -Level Debug
                continue
            }

            $certFilePath = Join-Path $certDir $exportFileName
            if (-not (Test-Path $certFilePath)) {
                throw "Certificate file not found: $exportFileName"
            }

            # Check if certificate already exists in the store
            $existing = Get-ChildItem -Path $certStorePath -ErrorAction SilentlyContinue |
                        Where-Object { $_.Thumbprint -eq $thumbprint }

            if ($existing) {
                $setting.ImportStatus = 'Success'
                if (-not $setting.Data) { $setting.Data = @{} }
                $setting.Data['ImportNote'] = 'Certificate already exists in the store'
                Write-MigrationLog -Message "Certificate $thumbprint already exists in store -- skipping import" -Level Debug
                continue
            }

            # Import the certificate
            Import-Certificate -FilePath $certFilePath -CertStoreLocation $certStorePath -ErrorAction Stop | Out-Null

            $setting.ImportStatus = 'Success'
            if (-not $setting.Data) { $setting.Data = @{} }
            $importNote = "Certificate imported successfully (public key only)"
            if ($hasPrivateKey) {
                $importNote += ". Original certificate had a private key that was not migrated. Re-enroll or re-import with the private key manually if needed."
            }
            $setting.Data['ImportNote'] = $importNote
            Write-MigrationLog -Message "Imported certificate: $($setting.Data['Subject']) ($thumbprint)" -Level Debug
        }
        catch {
            $setting.ImportStatus = 'Failed'
            if (-not $setting.Data) { $setting.Data = @{} }
            $setting.Data['ImportError'] = $_.Exception.Message
            Write-MigrationLog -Message "Failed to import certificate '$($setting.Name)': $($_.Exception.Message)" -Level Error
        }
    }

    $successCount = ($Settings | Where-Object { $_.ImportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "User certificates import complete: $successCount/$($Settings.Count) succeeded" -Level Success

    return $Settings
}
