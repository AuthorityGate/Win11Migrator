<#
========================================================================================================
    Title:          Win11Migrator - Network Computer Discovery
    Filename:       Find-NetworkComputers.ps1
    Description:    Discovers Windows machines on the local network using multiple discovery methods.
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
    Discovers Windows computers on the local network.
.DESCRIPTION
    Uses multiple discovery methods (Active Directory, ARP table, net view, subnet scan)
    to build a list of reachable Windows machines. Deduplicates by IP address and attempts
    to resolve OS information via WMI where accessible.
.PARAMETER TimeoutMs
    Timeout in milliseconds for individual ping/connection tests. Defaults to 1000.
.OUTPUTS
    [hashtable[]] Array of hashtables with ComputerName, IPAddress, OS, Online, Domain, Source keys.
.EXAMPLE
    $machines = Find-NetworkComputers -TimeoutMs 2000
#>

function Find-NetworkComputers {
    [CmdletBinding()]
    param(
        [int]$TimeoutMs = 1000
    )

    Write-MigrationLog -Message "Starting network computer discovery (timeout: ${TimeoutMs}ms)" -Level Info

    $computers = @{}  # Keyed by IP to deduplicate

    # -------------------------------------------------------------------------
    # Method 1: Active Directory (if domain-joined)
    # -------------------------------------------------------------------------
    if ($env:USERDNSDOMAIN) {
        Write-MigrationLog -Message "Machine is domain-joined ($env:USERDNSDOMAIN), trying AD discovery" -Level Info
        try {
            if (Get-Command Get-ADComputer -ErrorAction SilentlyContinue) {
                $adComputers = Get-ADComputer -Filter * -Properties DNSHostName, OperatingSystem, Enabled -ErrorAction Stop |
                    Where-Object { $_.Enabled -eq $true }
                foreach ($adc in $adComputers) {
                    try {
                        $ip = ([System.Net.Dns]::GetHostAddresses($adc.DNSHostName) |
                            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                            Select-Object -First 1).IPAddressToString
                        if ($ip -and -not $computers.ContainsKey($ip)) {
                            $computers[$ip] = @{
                                ComputerName = $adc.DNSHostName
                                IPAddress    = $ip
                                OS           = if ($adc.OperatingSystem) { $adc.OperatingSystem } else { 'Unknown' }
                                Online       = $false
                                Domain       = $env:USERDNSDOMAIN
                                Source       = 'ActiveDirectory'
                            }
                        }
                    } catch {
                        # DNS resolution failed for this entry, skip
                    }
                }
                Write-MigrationLog -Message "AD discovery found $($adComputers.Count) computer(s)" -Level Info
            }
        } catch {
            Write-MigrationLog -Message "AD discovery failed: $($_.Exception.Message)" -Level Warning
        }
    } else {
        Write-MigrationLog -Message "Machine is not domain-joined, skipping AD discovery" -Level Debug
    }

    # -------------------------------------------------------------------------
    # Method 2: ARP table + DNS reverse lookup
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Scanning ARP table for local network hosts" -Level Info
    try {
        $arpOutput = arp -a 2>&1
        $localIP = (Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.PrefixOrigin -ne 'WellKnown' } |
            Select-Object -First 1).IPAddress

        # Derive /24 subnet prefix from local IP
        $subnetPrefix = ''
        if ($localIP) {
            $octets = $localIP.Split('.')
            $subnetPrefix = "$($octets[0]).$($octets[1]).$($octets[2])."
        }

        foreach ($line in $arpOutput) {
            if ($line -match '^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([0-9a-f-]+)\s+(\w+)') {
                $ip = $Matches[1]
                $macType = $Matches[3]

                # Skip broadcast, multicast, and non-subnet IPs
                if ($macType -eq 'static') { continue }
                if ($ip -eq '255.255.255.255') { continue }
                if ($ip -match '\.255$') { continue }
                if ($subnetPrefix -and -not $ip.StartsWith($subnetPrefix)) { continue }
                if ($computers.ContainsKey($ip)) { continue }

                $hostname = $ip
                try {
                    $dnsEntry = [System.Net.Dns]::GetHostEntry($ip)
                    if ($dnsEntry.HostName) {
                        $hostname = $dnsEntry.HostName
                    }
                } catch {
                    # DNS reverse lookup failed, use IP as name
                }

                $computers[$ip] = @{
                    ComputerName = $hostname
                    IPAddress    = $ip
                    OS           = 'Unknown'
                    Online       = $false
                    Domain       = ''
                    Source       = 'ARP'
                }
            }
        }
        Write-MigrationLog -Message "ARP scan found $($computers.Count) unique host(s) so far" -Level Info
    } catch {
        Write-MigrationLog -Message "ARP scan failed: $($_.Exception.Message)" -Level Warning
    }

    # -------------------------------------------------------------------------
    # Method 3: Net view (quick network browse)
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Trying net view for network browse discovery" -Level Info
    try {
        $netViewOutput = net view 2>&1
        foreach ($line in $netViewOutput) {
            if ($line -match '^\\\\(\S+)') {
                $name = $Matches[1]
                try {
                    $ip = ([System.Net.Dns]::GetHostAddresses($name) |
                        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                        Select-Object -First 1).IPAddressToString
                    if ($ip -and -not $computers.ContainsKey($ip)) {
                        $computers[$ip] = @{
                            ComputerName = $name
                            IPAddress    = $ip
                            OS           = 'Unknown'
                            Online       = $false
                            Domain       = ''
                            Source       = 'NetView'
                        }
                    }
                } catch {
                    # Could not resolve net view entry
                }
            }
        }
        Write-MigrationLog -Message "Net view discovery complete, total unique hosts: $($computers.Count)" -Level Info
    } catch {
        Write-MigrationLog -Message "Net view failed: $($_.Exception.Message)" -Level Warning
    }

    # -------------------------------------------------------------------------
    # Method 4: Quick subnet scan (only if few results from above)
    # -------------------------------------------------------------------------
    if ($computers.Count -lt 5 -and $subnetPrefix) {
        Write-MigrationLog -Message "Few hosts found ($($computers.Count)), running subnet ping scan on $($subnetPrefix)0/24" -Level Info
        try {
            $jobs = @()
            for ($i = 1; $i -le 254; $i++) {
                $targetIP = "$subnetPrefix$i"
                if ($targetIP -eq $localIP) { continue }
                if ($computers.ContainsKey($targetIP)) { continue }
                $jobs += Test-Connection -ComputerName $targetIP -Count 1 -AsJob -ErrorAction SilentlyContinue
            }

            # Wait for all jobs with timeout
            if ($jobs.Count -gt 0) {
                $null = $jobs | Wait-Job -Timeout ([math]::Ceiling($TimeoutMs / 1000 * 2)) -ErrorAction SilentlyContinue
                foreach ($job in $jobs) {
                    try {
                        $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
                        if ($result -and $result.StatusCode -eq 0) {
                            $ip = $result.Address
                            if (-not $computers.ContainsKey($ip)) {
                                $hostname = $ip
                                try {
                                    $dnsEntry = [System.Net.Dns]::GetHostEntry($ip)
                                    if ($dnsEntry.HostName) { $hostname = $dnsEntry.HostName }
                                } catch { }

                                $computers[$ip] = @{
                                    ComputerName = $hostname
                                    IPAddress    = $ip
                                    OS           = 'Unknown'
                                    Online       = $false
                                    Domain       = ''
                                    Source       = 'SubnetScan'
                                }
                            }
                        }
                    } catch { }
                    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                }
            }
            Write-MigrationLog -Message "Subnet scan complete, total unique hosts: $($computers.Count)" -Level Info
        } catch {
            Write-MigrationLog -Message "Subnet scan failed: $($_.Exception.Message)" -Level Warning
        }
    }

    # -------------------------------------------------------------------------
    # Verify online status with quick ping
    # -------------------------------------------------------------------------
    Write-MigrationLog -Message "Verifying online status for $($computers.Count) discovered host(s)" -Level Info
    foreach ($ip in @($computers.Keys)) {
        try {
            $ping = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue
            $computers[$ip].Online = [bool]$ping
        } catch {
            $computers[$ip].Online = $false
        }
    }

    # -------------------------------------------------------------------------
    # Try to get OS info via WMI for online hosts
    # -------------------------------------------------------------------------
    foreach ($ip in @($computers.Keys)) {
        if ($computers[$ip].Online -and $computers[$ip].OS -eq 'Unknown') {
            try {
                $os = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $ip -ErrorAction Stop |
                    Select-Object -ExpandProperty Caption
                if ($os) {
                    $computers[$ip].OS = $os
                }
            } catch {
                # WMI not accessible, leave as Unknown
            }
        }
    }

    # -------------------------------------------------------------------------
    # Convert to array and sort by ComputerName
    # -------------------------------------------------------------------------
    $result = @($computers.Values | Sort-Object { $_.ComputerName })

    $onlineCount = @($result | Where-Object { $_.Online }).Count
    Write-MigrationLog -Message "Network discovery complete: $($result.Count) host(s) found, $onlineCount online" -Level Info

    return $result
}
