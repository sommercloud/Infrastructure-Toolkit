<#
.SYNOPSIS
    Installs/updates the Microsoft.AzLocal.CSSTools module and runs Invoke-AzsSupportInsight
    either against all nodes of an Azure Local cluster or against a single node.

.EXAMPLE
    .\AzureLocal_CSS_Tool.ps1 -ClusterName azl-cluster-01

.EXAMPLE
    .\AzureLocal_CSS_Tool.ps1 -ComputerName azl-node-01
#>
[CmdletBinding(DefaultParameterSetName = 'Cluster')]
param(
    [Parameter(ParameterSetName = 'Cluster', Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(ParameterSetName = 'Node', Mandatory = $true)]
    [string]$ComputerName
)

#1 Install Module
if (-not (Get-Module -ListAvailable -Name Microsoft.AzLocal.CSSTools)) {
    Install-Module -Name Microsoft.AzLocal.CSSTools -Force -Confirm:$false
}

#2 Update Module
Update-Module -Name Microsoft.AzLocal.CSSTools -Force -Confirm:$false
Remove-Module -Name Microsoft.AzLocal.CSSTools -Force -ErrorAction SilentlyContinue
Import-Module -Name Microsoft.AzLocal.CSSTools -Force

#3 Run
if ($PSCmdlet.ParameterSetName -eq 'Cluster') {
    $TargetNodes = (Get-ClusterNode -Cluster $ClusterName).Name
} else {
    $TargetNodes = $ComputerName
}

Invoke-AzsSupportInsight -ComputerName $TargetNodes
