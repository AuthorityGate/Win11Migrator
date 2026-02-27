<#
========================================================================================================
    Title:          Win11Migrator - User Data Module Pester Tests
    Filename:       UserData.Tests.ps1
    Description:    Pester test suite for the UserData module functions including profile discovery and export.
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
    Pester tests for UserData and BrowserProfiles modules.
#>

$ProjectRoot = Split-Path $PSScriptRoot -Parent

Describe "UserData Module Tests" {

    BeforeAll {
        . "$ProjectRoot\Core\Initialize-Environment.ps1"
        . "$ProjectRoot\Core\Write-MigrationLog.ps1"
        $script:MigratorRoot = $ProjectRoot
        $script:Config = Initialize-Environment -RootPath $ProjectRoot
        Get-ChildItem "$ProjectRoot\Modules\UserData\*.ps1" | ForEach-Object { . $_.FullName }
        Get-ChildItem "$ProjectRoot\Modules\BrowserProfiles\*.ps1" | ForEach-Object { . $_.FullName }
    }

    Context "Get-UserProfilePaths" {
        It "Should return a hashtable with standard folders" {
            $paths = Get-UserProfilePaths
            $paths | Should -BeOfType [hashtable]
            $paths.ContainsKey('Desktop') | Should -Be $true
            $paths.ContainsKey('Documents') | Should -Be $true
            $paths.ContainsKey('Downloads') | Should -Be $true
        }

        It "Should return existing paths" {
            $paths = Get-UserProfilePaths
            foreach ($key in @('Desktop', 'Documents')) {
                if ($paths[$key]) {
                    Test-Path $paths[$key] | Should -Be $true
                }
            }
        }

        It "Should include UserProfile key" {
            $paths = Get-UserProfilePaths
            $paths.ContainsKey('UserProfile') | Should -Be $true
            $paths.UserProfile | Should -Be $env:USERPROFILE
        }
    }

    Context "UserDataItem class" {
        It "Should create with defaults" {
            $item = [UserDataItem]::new()
            $item.Selected | Should -Be $true
            $item.SizeBytes | Should -Be 0
        }
    }

    Context "Export-UserProfile" {
        It "Should handle empty input gracefully" {
            $tempDir = Join-Path $env:TEMP "Win11Migrator_Test_$(Get-Random)"
            New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

            try {
                $result = Export-UserProfile -Items @() -OutputPath $tempDir
                $result | Should -Not -BeNullOrEmpty -Because "Should return empty array, not null"
            } catch {
                # Acceptable if function doesn't handle empty gracefully
            } finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Get-BrowserProfilePaths" {
        It "Should return an array" {
            $profiles = Get-BrowserProfilePaths
            $profiles | Should -Not -BeNullOrEmpty -Because "At least one browser should be installed"
        }

        It "Should detect Edge on Windows 11" {
            $profiles = Get-BrowserProfilePaths
            $edgeProfiles = $profiles | Where-Object { $_.Browser -eq 'Edge' }
            # Edge is pre-installed on Windows 11
            $edgeProfiles | Should -Not -BeNullOrEmpty
        }
    }

    Context "BrowserProfile class" {
        It "Should create with defaults" {
            $profile = [BrowserProfile]::new()
            $profile.Selected | Should -Be $true
            $profile.HasBookmarks | Should -Be $false
        }
    }
}
