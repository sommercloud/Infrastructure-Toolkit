<#
.SYNOPSIS
    Creates required inbound Windows Firewall rules for Veeam Hyper-V backups on one or more servers.

.DESCRIPTION
    This script connects remotely to one or more target servers and creates the required inbound
    firewall rules for Veeam Backup and Replication communication.

.PARAMETER Server
    One or more server names. Supports array input and comma-separated values.

.EXAMPLE
    .\WindowsServer_HyperV_Firewall.ps1 -Server SRV01

    Creates the Veeam firewall rules on SRV01.

.EXAMPLE
    .\WindowsServer_HyperV_Firewall.ps1 -Server "SRV01,SRV02"

    Creates the Veeam firewall rules on SRV01 and SRV02.

.EXAMPLE
    .\WindowsServer_HyperV_Firewall.ps1 -Server SRV01,SRV02,SRV03

    Creates the Veeam firewall rules on multiple servers.

.NOTES
    Author       : Peter Sommer (Sommercloud)
    Prerequisites: Administrative privileges
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Server
)

$servers = $Server | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique

Invoke-Command -ComputerName $servers -ScriptBlock {
    $rules = @(
        @{ DisplayName = "VEEAM Backup and Replication TCP"; Protocol = "TCP"; LocalPort = "135,137-139,445" }
        @{ DisplayName = "VEEAM Backup and Replication UDP"; Protocol = "UDP"; LocalPort = "137-138" }
        @{ DisplayName = "VEEAM Installer Service"; Protocol = "TCP"; LocalPort = "6160" }
        @{ DisplayName = "VEEAM Backup Proxy Service"; Protocol = "TCP"; LocalPort = "6162" }
        @{ DisplayName = "VEEAM Hyper-V Integration Service"; Protocol = "TCP"; LocalPort = "6163" }
        @{ DisplayName = "VEEAM Dynamic RPC Range 49152-65535"; Protocol = "TCP"; LocalPort = "49152-65535" }
        @{ DisplayName = "VEEAM Dynamic RPC Range 2500-3300"; Protocol = "TCP"; LocalPort = "2500-3300" }
    )

    foreach ($rule in $rules) {
        New-NetFirewallRule -DisplayName $rule.DisplayName -Direction Inbound -Action Allow -Protocol $rule.Protocol -LocalPort $rule.LocalPort -Profile Domain,Private,Public
    }
}