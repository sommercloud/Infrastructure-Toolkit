<#
.SYNOPSIS
Checks whether the Secure Boot 2023 CA certificate is present in the UEFI db on remote servers.

.DESCRIPTION
Connects to one or more servers via PowerShell Remoting and verifies whether the
"Windows UEFI CA 2023" certificate is active in the UEFI Allowed Signature Database (db).
Also reads the native Servicing registry status if available (Windows Server 2019+).

.PARAMETER ComputerName
One or more target hostnames. PSRemoting must be enabled.

.PARAMETER Credential
Optional credentials for the remote session.

.PARAMETER LogPath
Optional CSV export path for documentation purposes.

.EXAMPLE
.\Check-SecureBoot-CA.ps1 -ComputerName Server01
Checks a single server.

.EXAMPLE
.\Check-SecureBoot-CA.ps1 -ComputerName Server01,Server02 -Credential (Get-Credential)
Checks multiple servers with alternate credentials.

.EXAMPLE
.\Check-SecureBoot-CA.ps1 -ComputerName Server01,Server02 -LogPath "C:\Logs\SecureBoot.csv"
Checks multiple servers and exports results to CSV.

.NOTES
    Author       : Peter Sommer (Sommercloud)
    Prerequisites: PSRemoting enabled on target servers, Secure Boot active (Gen2 VM required)
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory)]
    [string[]]$ComputerName,

    [PSCredential]$Credential,

    [string]$LogPath
)

$scriptBlock = {
    $result = [PSCustomObject]@{
        ComputerName      = $env:COMPUTERNAME
        SecureBootEnabled = $false
        UEFICA2023_DB     = $false
        ServicingStatus   = $null
        Status            = 'Unknown'
        Error             = $null
    }

    try {
        $sbEnabled = Confirm-SecureBootUEFI -ErrorAction Stop
        $result.SecureBootEnabled = $sbEnabled

        if (-not $sbEnabled) {
            $result.Status = 'Secure Boot disabled'
            return $result
        }

        $dbBytes = (Get-SecureBootUEFI -Name db).Bytes
        $dbText  = [System.Text.Encoding]::ASCII.GetString($dbBytes)
        $result.UEFICA2023_DB = ($dbText -match 'Windows UEFI CA 2023')

        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing'
        if (Test-Path $regPath) {
            $result.ServicingStatus = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).UEFICA2023Status
        }

        $result.Status = if ($result.UEFICA2023_DB) { 'OK - 2023 CA active' } else { 'WARNING - 2011 CA only' }
    }
    catch {
        $result.Error  = $_.Exception.Message
        $result.Status = 'Query failed'
    }

    return $result
}

$invokeParams = @{
    ComputerName = $ComputerName
    ScriptBlock  = $scriptBlock
    ErrorAction  = 'SilentlyContinue'
}
if ($Credential) { $invokeParams.Credential = $Credential }

$results = Invoke-Command @invokeParams |
    Select-Object ComputerName, SecureBootEnabled, UEFICA2023_DB, ServicingStatus, Status, Error |
    Sort-Object Status

$results | Format-Table -AutoSize

if ($LogPath) {
    $results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    Write-Host "Results exported to $LogPath" -ForegroundColor Green
}
