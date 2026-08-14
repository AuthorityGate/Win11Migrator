function Get-Win11MigratorUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][version]$CurrentVersion)

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = 'AuthorityGate-Win11Migrator' }
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/AuthorityGate/Win11Migrator/releases/latest' -Headers $headers -UseBasicParsing -TimeoutSec 8
        $latest = [version]([string]$release.tag_name -replace '^[vV]', '')
        $asset = $release.assets | Where-Object { $_.name -match '^Win11Migrator[-_]Setup.*\.exe$' } | Select-Object -First 1
        [pscustomobject]@{
            CurrentVersion = $CurrentVersion
            LatestVersion = $latest
            UpdateAvailable = ($latest -gt $CurrentVersion -and $null -ne $asset)
            DownloadUrl = if ($asset) { [string]$asset.browser_download_url } else { $null }
            FileName = if ($asset) { [string]$asset.name } else { $null }
        }
    } catch {
        [pscustomobject]@{ CurrentVersion=$CurrentVersion; LatestVersion=$null; UpdateAvailable=$false; Error=$_.Exception.Message }
    }
}

function Invoke-Win11MigratorSelfUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][version]$CurrentVersion, [switch]$Automatic)

    $registryPath = 'HKCU:\SOFTWARE\AuthorityGate\Win11Migrator'
    if (-not (Test-Path $registryPath)) { New-Item -Path $registryPath -Force | Out-Null }
    if ($Automatic) {
        $lastCheck = (Get-ItemProperty -Path $registryPath -Name LastUpdateCheck -ErrorAction SilentlyContinue).LastUpdateCheck
        if ($lastCheck) {
            try { if ((Get-Date) - [datetime]$lastCheck -lt [timespan]::FromHours(24)) { return } } catch {}
        }
    }
    Set-ItemProperty -Path $registryPath -Name LastUpdateCheck -Value (Get-Date).ToString('o')

    $update = Get-Win11MigratorUpdate -CurrentVersion $CurrentVersion
    if (-not $update.UpdateAvailable) {
        if (-not $Automatic) {
            $message = if ($update.Error) { "The update service could not be reached.`n`n$($update.Error)" } else { "Win11Migrator $CurrentVersion is current." }
            [System.Windows.MessageBox]::Show($message, 'Win11Migrator Update', 'OK', 'Information') | Out-Null
        }
        return
    }

    $answer = [System.Windows.MessageBox]::Show("Win11Migrator $($update.LatestVersion) is available. Download the signed update now?", 'Win11Migrator Update', 'YesNo', 'Information')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $destination = Join-Path $env:TEMP $update.FileName
    Invoke-WebRequest -Uri $update.DownloadUrl -OutFile $destination -UseBasicParsing -TimeoutSec 180
    $signature = Get-AuthenticodeSignature -FilePath $destination
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=AUTHORITYGATE INC') {
        Remove-Item $destination -Force -ErrorAction SilentlyContinue
        throw 'The downloaded update did not have a valid AUTHORITYGATE INC signature.'
    }
    Start-Process -FilePath $destination -Verb RunAs
}
