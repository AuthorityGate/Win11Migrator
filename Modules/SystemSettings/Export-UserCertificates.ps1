<#
========================================================================================================
    Title:          Win11Migrator - User Certificates Exporter
    Filename:       Export-UserCertificates.ps1
    Description:    Exports user certificates from the personal certificate store for migration.
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
    Exports user certificates from Cert:\CurrentUser\My.
.DESCRIPTION
    Enumerates certificates in the current user's personal certificate store,
    exports public certificates as DER (.cer) files, and logs warnings for
    certificates with private keys that cannot be exported without a password.
    Returns [SystemSetting[]] with Category='Certificate'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-UserCertificates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting user certificates export" -Level Info

    [SystemSetting[]]$results = @()

    # Ensure the output directory exists
    $certDir = Join-Path $ExportPath "UserCertificates"
    if (-not (Test-Path $certDir)) {
        New-Item -Path $certDir -ItemType Directory -Force | Out-Null
    }

    # ----------------------------------------------------------------
    # 1. Enumerate and export certificates
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Enumerating certificates in Cert:\\CurrentUser\\My" -Level Debug

        $certStorePath = 'Cert:\CurrentUser\My'
        $certs = Get-ChildItem -Path $certStorePath -ErrorAction Stop

        $certMetadata = @()
        $exportedCount = 0
        $privateKeyCount = 0
        $failedCount = 0

        foreach ($cert in $certs) {
            try {
                $certInfo = @{
                    Subject        = $cert.Subject
                    Issuer         = $cert.Issuer
                    Thumbprint     = $cert.Thumbprint
                    FriendlyName   = $cert.FriendlyName
                    NotBefore      = $cert.NotBefore.ToString('yyyy-MM-dd HH:mm:ss')
                    NotAfter       = $cert.NotAfter.ToString('yyyy-MM-dd HH:mm:ss')
                    SerialNumber   = $cert.SerialNumber
                    HasPrivateKey  = $cert.HasPrivateKey
                    Exported       = $false
                    ExportFileName = ''
                }

                if ($cert.HasPrivateKey) {
                    # Certificates with private keys cannot be exported without a password
                    # and Export-PfxCertificate requires a SecureString password.
                    # We log a warning and skip the private key export.
                    $privateKeyCount++
                    $certInfo['ExportNote'] = 'Certificate has a private key. Private key export requires a password and is not supported in automated migration. The public certificate has been exported.'
                    Write-MigrationLog -Message "Certificate '$($cert.Subject)' has a private key -- exporting public cert only (Thumbprint: $($cert.Thumbprint))" -Level Warning
                }

                # Export the public certificate as DER (.cer)
                $safeName = $cert.Thumbprint
                $certFileName = "$safeName.cer"
                $certFilePath = Join-Path $certDir $certFileName

                try {
                    Export-Certificate -Cert $cert -FilePath $certFilePath -Type CERT -Force -ErrorAction Stop | Out-Null
                    $certInfo['Exported'] = $true
                    $certInfo['ExportFileName'] = $certFileName
                    $exportedCount++
                    Write-MigrationLog -Message "Exported certificate: $($cert.Subject) ($($cert.Thumbprint))" -Level Debug
                }
                catch {
                    $certInfo['ExportNote'] = "Failed to export: $($_.Exception.Message)"
                    $failedCount++
                    Write-MigrationLog -Message "Failed to export certificate $($cert.Thumbprint): $($_.Exception.Message)" -Level Warning
                }

                $certMetadata += $certInfo
            }
            catch {
                $failedCount++
                Write-MigrationLog -Message "Error processing certificate: $($_.Exception.Message)" -Level Warning
            }
        }

        # Create a SystemSetting for each exported certificate
        foreach ($meta in $certMetadata) {
            $setting = [SystemSetting]::new()
            $setting.Category     = 'Certificate'
            $setting.Name         = "Cert_$($meta.Thumbprint)"
            $setting.Data         = $meta
            $setting.ExportStatus = if ($meta.Exported) { 'Success' } else { 'Failed' }
            $results += $setting
        }

        Write-MigrationLog -Message "Certificate enumeration complete: $($certs.Count) found, $exportedCount exported, $privateKeyCount with private keys, $failedCount failed" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'Certificate'
        $setting.Name         = 'CertificateStore'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to enumerate certificates: $($_.Exception.Message)" -Level Error
    }

    # Save certificate metadata to JSON
    try {
        $jsonFile = Join-Path $certDir "CertificateMetadata.json"
        $certMetadata | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-MigrationLog -Message "Saved certificate metadata to CertificateMetadata.json" -Level Debug
    }
    catch {
        Write-MigrationLog -Message "Failed to save CertificateMetadata.json: $($_.Exception.Message)" -Level Warning
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "User certificates export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
