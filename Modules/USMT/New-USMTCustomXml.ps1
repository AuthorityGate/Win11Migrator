<#
========================================================================================================
    Title:          Win11Migrator - USMT Custom Migration XML Generator
    Filename:       New-USMTCustomXml.ps1
    Description:    Generates custom USMT migration XML files to capture additional registry keys, files, and app profiles.
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
    Creates a custom USMT migration XML that captures items beyond the standard MigApp/MigDocs/MigUser scope.
.DESCRIPTION
    Generates a valid USMT migration XML file containing components for
    additional registry keys, file paths, and application profiles provided
    by the Win11Migrator catalog. The XML follows the USMT migration schema
    and can be passed to scanstate.exe and loadstate.exe via the /i: flag.
.OUTPUTS
    [hashtable] with OutputPath and ComponentCount keys.
#>

function New-USMTCustomXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [string[]]$AdditionalRegistryKeys,

        [string[]]$AdditionalFilePaths,

        [hashtable[]]$AppProfiles
    )

    Write-MigrationLog -Message "Generating custom USMT migration XML: $OutputPath" -Level Info

    $componentCount = 0

    # ---- Build XML document ----
    $xmlSettings = New-Object System.Xml.XmlWriterSettings
    $xmlSettings.Indent             = $true
    $xmlSettings.IndentChars        = '  '
    $xmlSettings.Encoding           = [System.Text.Encoding]::UTF8
    $xmlSettings.OmitXmlDeclaration = $false

    # Ensure output directory exists
    $outputDir = Split-Path -Path $OutputPath -Parent
    if ($outputDir -and -not (Test-Path -Path $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
    }

    try {
        $writer = [System.Xml.XmlWriter]::Create($OutputPath, $xmlSettings)

        try {
            $writer.WriteStartDocument()

            # Root migration element
            $writer.WriteStartElement('migration', 'http://www.microsoft.com/migration/1.0/migxmlext/migxml')
            $writer.WriteAttributeString('urlid', 'http://www.microsoft.com/migration/1.0/migxmlext/custom')

            # ---- Component: Additional Registry Keys ----
            if ($AdditionalRegistryKeys -and $AdditionalRegistryKeys.Count -gt 0) {
                $writer.WriteStartElement('component')
                $writer.WriteAttributeString('type', 'System')
                $writer.WriteAttributeString('context', 'User')

                $writer.WriteElementString('displayName', 'Win11Migrator Custom Registry Rules')

                $writer.WriteStartElement('role')
                $writer.WriteAttributeString('role', 'Settings')

                $writer.WriteStartElement('rules')
                $writer.WriteStartElement('include')
                $writer.WriteStartElement('objectSet')

                foreach ($regKey in $AdditionalRegistryKeys) {
                    # Convert standard registry paths to USMT pattern format
                    # HKCU\Software\AppName -> HKCU\Software\AppName\* [*]
                    $usmtPattern = $regKey.TrimEnd('\')
                    $writer.WriteStartElement('pattern')
                    $writer.WriteAttributeString('type', 'Registry')
                    $writer.WriteString("$usmtPattern\* [*]")
                    $writer.WriteEndElement()  # pattern
                }

                $writer.WriteEndElement()  # objectSet
                $writer.WriteEndElement()  # include
                $writer.WriteEndElement()  # rules
                $writer.WriteEndElement()  # role
                $writer.WriteEndElement()  # component

                $componentCount++
                Write-MigrationLog -Message "Added registry component with $($AdditionalRegistryKeys.Count) key patterns" -Level Debug
            }

            # ---- Component: Additional File Paths ----
            if ($AdditionalFilePaths -and $AdditionalFilePaths.Count -gt 0) {
                $writer.WriteStartElement('component')
                $writer.WriteAttributeString('type', 'Documents')
                $writer.WriteAttributeString('context', 'User')

                $writer.WriteElementString('displayName', 'Win11Migrator Custom File Rules')

                $writer.WriteStartElement('role')
                $writer.WriteAttributeString('role', 'Data')

                $writer.WriteStartElement('rules')
                $writer.WriteStartElement('include')
                $writer.WriteStartElement('objectSet')

                foreach ($filePath in $AdditionalFilePaths) {
                    # Convert paths to USMT pattern format
                    # C:\Users\*\AppData\Roaming\AppName -> %CSIDL_APPDATA%\AppName\* [*]
                    # Or pass through if already in USMT format
                    $usmtPattern = $filePath.TrimEnd('\')
                    $writer.WriteStartElement('pattern')
                    $writer.WriteAttributeString('type', 'File')
                    $writer.WriteString("$usmtPattern\* [*]")
                    $writer.WriteEndElement()  # pattern
                }

                $writer.WriteEndElement()  # objectSet
                $writer.WriteEndElement()  # include
                $writer.WriteEndElement()  # rules
                $writer.WriteEndElement()  # role
                $writer.WriteEndElement()  # component

                $componentCount++
                Write-MigrationLog -Message "Added file component with $($AdditionalFilePaths.Count) path patterns" -Level Debug
            }

            # ---- Components: Application Profiles ----
            if ($AppProfiles -and $AppProfiles.Count -gt 0) {
                foreach ($profile in $AppProfiles) {
                    $appName    = if ($profile.ContainsKey('Name'))        { $profile['Name'] }        else { 'Unknown App' }
                    $appDataPaths = if ($profile.ContainsKey('AppDataPaths')) { $profile['AppDataPaths'] } else { @() }
                    $regPaths     = if ($profile.ContainsKey('RegistryPaths')) { $profile['RegistryPaths'] } else { @() }

                    # Skip profiles with no paths to capture
                    if (($appDataPaths.Count -eq 0) -and ($regPaths.Count -eq 0)) {
                        Write-MigrationLog -Message "Skipping app profile '$appName': no paths defined" -Level Debug
                        continue
                    }

                    # File data component for this app
                    if ($appDataPaths.Count -gt 0) {
                        $writer.WriteStartElement('component')
                        $writer.WriteAttributeString('type', 'Documents')
                        $writer.WriteAttributeString('context', 'User')

                        $writer.WriteElementString('displayName', "Win11Migrator App: $appName (Files)")

                        $writer.WriteStartElement('role')
                        $writer.WriteAttributeString('role', 'Data')

                        $writer.WriteStartElement('rules')
                        $writer.WriteStartElement('include')
                        $writer.WriteStartElement('objectSet')

                        foreach ($appPath in $appDataPaths) {
                            $usmtPattern = $appPath.TrimEnd('\')
                            $writer.WriteStartElement('pattern')
                            $writer.WriteAttributeString('type', 'File')
                            $writer.WriteString("$usmtPattern\* [*]")
                            $writer.WriteEndElement()  # pattern
                        }

                        $writer.WriteEndElement()  # objectSet
                        $writer.WriteEndElement()  # include
                        $writer.WriteEndElement()  # rules
                        $writer.WriteEndElement()  # role
                        $writer.WriteEndElement()  # component

                        $componentCount++
                    }

                    # Registry component for this app
                    if ($regPaths.Count -gt 0) {
                        $writer.WriteStartElement('component')
                        $writer.WriteAttributeString('type', 'System')
                        $writer.WriteAttributeString('context', 'User')

                        $writer.WriteElementString('displayName', "Win11Migrator App: $appName (Registry)")

                        $writer.WriteStartElement('role')
                        $writer.WriteAttributeString('role', 'Settings')

                        $writer.WriteStartElement('rules')
                        $writer.WriteStartElement('include')
                        $writer.WriteStartElement('objectSet')

                        foreach ($regPath in $regPaths) {
                            $usmtPattern = $regPath.TrimEnd('\')
                            $writer.WriteStartElement('pattern')
                            $writer.WriteAttributeString('type', 'Registry')
                            $writer.WriteString("$usmtPattern\* [*]")
                            $writer.WriteEndElement()  # pattern
                        }

                        $writer.WriteEndElement()  # objectSet
                        $writer.WriteEndElement()  # include
                        $writer.WriteEndElement()  # rules
                        $writer.WriteEndElement()  # role
                        $writer.WriteEndElement()  # component

                        $componentCount++
                    }

                    Write-MigrationLog -Message "Added app profile component: $appName (files=$($appDataPaths.Count), registry=$($regPaths.Count))" -Level Debug
                }
            }

            $writer.WriteEndElement()  # migration
            $writer.WriteEndDocument()

        } finally {
            $writer.Flush()
            $writer.Dispose()
        }

        Write-MigrationLog -Message "Custom USMT XML generated: $OutputPath ($componentCount components)" -Level Success

        return @{
            OutputPath     = $OutputPath
            ComponentCount = $componentCount
        }

    } catch {
        Write-MigrationLog -Message "Failed to generate custom USMT XML: $($_.Exception.Message)" -Level Error
        return @{
            OutputPath     = ''
            ComponentCount = 0
        }
    }
}
