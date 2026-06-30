<#
.SYNOPSIS
Displays VM UIDs (VMId) and status per cluster node.

.DESCRIPTION
The script reads all nodes in a failover cluster and retrieves the virtual
machines available on each node. The output includes cluster node name, VM name,
VMId, and state.

.PARAMETER ClusterName
Optional failover cluster name.
If the parameter is empty, the local cluster is used.

.EXAMPLE
.\Hyper-V_Show_VM_UID.ps1
Uses the local cluster and shows all VMs including VMId.

.EXAMPLE
.\Hyper-V_Show_VM_UID.ps1 -ClusterName "Cluster01"
Reads VM data from the specified cluster "Cluster01".

.NOTES
Requirements:
- Failover-Clustering PowerShell-Modul
- Hyper-V PowerShell-Modul
- Sufficient permissions on the cluster and nodes
#>

[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$ClusterName
)

$Cluster = if ([string]::IsNullOrWhiteSpace($ClusterName)) {
    (Get-Cluster).Name
}
else {
    $ClusterName
}

$Nodes = Get-ClusterNode -Cluster $Cluster

$Result = foreach ($Node in $Nodes) {
    $VMs = Get-VM -ComputerName $Node.Name

    foreach ($VM in $VMs) {
        [PSCustomObject]@{
            ClusterNode = $Node.Name
            VMName      = $VM.Name
            VMId        = $VM.VMId
            State       = $VM.State
        }
    }
}

$Result | Sort-Object -Property VMID | Format-Table -AutoSize