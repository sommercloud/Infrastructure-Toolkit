<# 
============== QUICK USAGE COPY & PASTE =================

$Server = "HCI-NODE01", "HCI-NODE02", "HCI-NODE03"

Invoke-Command -ComputerName $servers -ScriptBlock {
    Enable-ASRemoteDesktop
}
=========================================================
#>

<#
.SYNOPSIS
    Enable/Disable RDP on all Nodes in a Azure Local Cluster or on a single Node.

.DESCRIPTION
    This script enables/disables Remote Desktop Protocol (RDP) on all nodes in an Azure Local Cluster or on a single node.
    It iterates through each node and configures the necessary settings for RDP.

.PARAMETER ClusterName
Name of the failover cluster whose nodes should be queried and processed.

.PARAMETER Node
Name of a single Node on which Remote Desktop should be enabled or disabled.

.PARAMETER Disable
If specified, Disable-ASRemoteDesktop is executed.
If not specified, Enable-ASRemoteDesktop is executed.

.EXAMPLE
.\AzureLocal-Configure-RDP.ps1 -ClusterName HCI-CLUSTER01

Enables Remote Desktop on all nodes of cluster HCI-CLUSTER01.

.EXAMPLE
.\AzureLocal-Configure-RDP.ps1 -ClusterName HCI-CLUSTER01 -Disable

Disables Remote Desktop on all nodes of cluster HCI-CLUSTER01.

.EXAMPLE
.\AzureLocal-Configure-RDP.ps1 -Node HCI-NODE01

Enables Remote Desktop on the single Node HCI-NODE01.

.EXAMPLE
.\AzureLocal-Configure-RDP.ps1 -Node HCI-NODE01 -Disable

Disables Remote Desktop on the single Node HCI-NODE01.

.NOTES
    Author       : Peter Sommer (Sommercloud)
    Prerequisites: Administrative privileges, Failover Clustering tools if using -ClusterName.
#>


[CmdletBinding(DefaultParameterSetName = 'Cluster')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Cluster')]
    [ValidateNotNullOrEmpty()]
    [string]$ClusterName,

    [Parameter(Mandatory = $true, ParameterSetName = 'Node')]
    [ValidateNotNullOrEmpty()]
    [string]$Node,

    [Parameter()]
    [switch]$Disable
)

try {
    $Targets = @()

    if ($PSCmdlet.ParameterSetName -eq 'Cluster') {
        Write-Verbose "Checking if Get-ClusterNode cmdlet is available."

        $clusterCommand = Get-Command -Name Get-ClusterNode -ErrorAction SilentlyContinue
        if (-not $clusterCommand) {
            throw "The cmdlet 'Get-ClusterNode' was not found. Please install Failover Clustering management tools."
        }

        Write-Verbose "Querying cluster nodes for cluster '$ClusterName'."
        $Targets = (Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop).Name

        if (-not $Targets -or $Targets.Count -eq 0) {
            throw "No cluster nodes found in cluster '$ClusterName'."
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Node') {
        Write-Verbose "Single node '$Node' specified."
        $Targets = @($Node)
    }

    Write-Host "Target systems:" -ForegroundColor Green
    $Targets | ForEach-Object { Write-Host " - $_" }

    $Successful = @()
    $Failed = @()

    $action = if ($Disable) { "Disabling" } else { "Enabling" }
    Write-Host "$action Remote Desktop on target systems..." -ForegroundColor Yellow

    foreach ($target in $Targets) {
        Write-Verbose "Processing $target..."
        try {
            if ($Disable) {
                Invoke-Command -ComputerName $target -ScriptBlock {
                    Disable-ASRemoteDesktop
                } -ErrorAction Stop -Verbose
            }
            else {
                Invoke-Command -ComputerName $target -ScriptBlock {
                    Enable-ASRemoteDesktop
                } -ErrorAction Stop -Verbose
            }
            $Successful += $target
        }
        catch {
            $Failed += "$target : $($_.Exception.Message)"
        }
    }

    Write-Host "Successful: $($Successful -join ', ')" -ForegroundColor Green
    if ($Failed) {
        Write-Host "Failed: $($Failed -join '; ')" -ForegroundColor Red
    }
    else {
        Write-Host "Operation completed successfully." -ForegroundColor Green
    }
}
catch {
    Write-Error $_.Exception.Message
}