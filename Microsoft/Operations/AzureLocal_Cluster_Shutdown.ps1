
<#
.SYNOPSIS
    Gracefully shuts down an Azure Local (HCI) cluster.

.DESCRIPTION
    Performs a controlled shutdown of an Azure Local cluster by stopping cluster groups, cluster resources,
    and services in the correct order. Includes safety prompts and verbose logging for each step.

.PARAMETER ClusterName
    Name of the cluster to shut down. If not specified, the local cluster is used.

.PARAMETER Force
    If specified, bypasses the safety prompt and continues shutdown even if storage jobs do not complete within the timeout.

.PARAMETER Log
    If specified, logs all output to the given file path. The file will be appended if it exists.

.PARAMETER PowerOff
    If specified, shuts down all cluster nodes after the cluster service has been stopped.

.EXAMPLE
    .\AzureLocal_Cluster_Shutdown.ps1
    Shuts down the local Azure Local cluster after confirmation.

.EXAMPLE
    .\AzureLocal_Cluster_Shutdown.ps1 -ClusterName HCI-CLUSTER01
    Shuts down the cluster named HCI-CLUSTER01 after confirmation.

.EXAMPLE
    .\AzureLocal_Cluster_Shutdown.ps1 -ClusterName HCI-CLUSTER01 -Force
    Shuts down the cluster named HCI-CLUSTER01 without safety prompt and without waiting for storage jobs to complete.

.EXAMPLE
    .\AzureLocal_Cluster_Shutdown.ps1 -Log "C:\Logs\AzureLocal_Cluster_Shutdown.log"
    Shuts down the local cluster after confirmation and logs all output to the specified file.

.EXAMPLE
    .\AzureLocal_Cluster_Shutdown.ps1 -ClusterName HCI-CLUSTER01 -Force -Log "C:\Logs\AzureLocal_Cluster_Shutdown.log" -Verbose
    Shuts down the cluster with force mode, detailed logging to file, and verbose output to console.

.EXAMPLE
    .\AzureLocal_Cluster_Shutdown.ps1 -ClusterName HCI-CLUSTER01 -PowerOff
    Shuts down the cluster and powers off all nodes after confirmation.

.NOTES
    Author      : Peter Sommer
    Version     : 1.0.2
    Created     : 2026-03-25
    Changed     : 2026-03-30 - Added -PowerOff parameter to enable node shutdown after cluster shutdown
    Prerequisites: Administrative privileges, Failover Clustering tools.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ClusterName,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [string]$Log,

    [Parameter()]
    [switch]$PowerOff
)

# Section: Logging and transcript setup
if ($Log) {
    $LogDir = Split-Path $Log -Parent
    if ($LogDir -and -not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    Start-Transcript -Path $Log -Append
}

try {
    # Determine cluster name - use provided ClusterName parameter or retrieve local cluster
    $clusterName = if ($ClusterName) { $ClusterName } else { (Get-Cluster).Name }
    Write-Verbose "Target cluster: $clusterName"

    # Pre-shutdown check: Verify all cluster nodes are online
    Write-Verbose "Checking if all cluster nodes are online..."
    $nodes = (Get-ClusterNode -Cluster $clusterName)
    $offlineNodes = $nodes | Where-Object { $_.State -ne "Up" }
    if ($offlineNodes) {
        if ($Force) {
            Write-Host "Warning: The following nodes are offline: $($offlineNodes.Name -join ', '). Continuing due to -Force flag." -ForegroundColor Yellow
        } else {
            Write-Host "Error: Cluster nodes are offline. Cannot proceed with shutdown." -ForegroundColor Red
            throw "Offline nodes detected: $($offlineNodes.Name -join ', ')"
        }
    } else {
        Write-Host "All cluster nodes are online." -ForegroundColor Green
    }

    # Safety prompt - require explicit user confirmation before proceeding (unless -Force is used)
    if (-not $Force) {
        Write-Host "This will shut down the cluster '$clusterName'. This action cannot be undone easily." -ForegroundColor Red
        $confirm = Read-Host "Do you want to proceed? (yes/no)"
        if ($confirm -ne "yes") {
            Write-Host "Shutdown cancelled." -ForegroundColor Yellow
            exit
        }
    } else {
        Write-Host "Force mode enabled - bypassing safety prompt." -ForegroundColor Yellow
    }

    # Gracefully shut down all running virtual machines
    Write-Verbose "Shutting down virtual machines gracefully..."
    $vmGroups = Get-ClusterGroup -Cluster $clusterName | Where-Object { $_.GroupType -eq "VirtualMachine" }
    foreach ($vmGroup in $vmGroups) {
        try {
            if ($vmGroup.State -eq "Online") {
                $vmName = $vmGroup.Name
                $ownerNode = $vmGroup.OwnerNode.Name

                Invoke-Command -ComputerName $ownerNode -ScriptBlock {
                    param($Name)
                    # Stop-VM without -TurnOff requests a clean guest shutdown.
                    Stop-VM -Name $Name -Confirm:$false -ErrorAction Stop
                } -ArgumentList $vmName -ErrorAction Stop

                Write-Verbose "Shutdown command sent to VM '$vmName' on node '$ownerNode'."
            }
        }
        catch {
            Write-Host "Warning: Failed to send graceful shutdown to VM '$($vmGroup.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Wait for all virtual machines to shut down completely
    # Virtual machines must be fully shut down before proceeding with services
    if ($vmGroups) {
        Write-Host "Waiting for all virtual machines to shut down (timeout: 10 minutes)..." -ForegroundColor Yellow
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $timeout = [TimeSpan]::FromMinutes(10)
        
        # Poll cluster state for VM shutdown every 10 seconds
        while ($stopwatch.Elapsed -lt $timeout) {
            $runningVMs = Get-ClusterGroup -Cluster $clusterName |
            Where-Object { $_.GroupType -eq "VirtualMachine" -and ($_.State -eq "Online" -or $_.State -eq "Pending") }
            
            if (-not $runningVMs) {
                Write-Verbose "All virtual machines have shut down."
                Write-Host "All VMs shutdown complete." -ForegroundColor Green
                break
            }
            
            $vmStatus = $runningVMs | Select-Object -ExpandProperty Name
            Write-Verbose "Still waiting for VMs to shut down: $($vmStatus -join ', ') ($($stopwatch.Elapsed.Minutes)m $($stopwatch.Elapsed.Seconds)s elapsed)"
            Start-Sleep -Seconds 10
        }
        
        # Handle timeout - abort if not using -Force, otherwise warn and continue
        if ($stopwatch.Elapsed -ge $timeout) {
            $runningVMs = Get-ClusterGroup -Cluster $clusterName |
            Where-Object { $_.GroupType -eq "VirtualMachine" -and ($_.State -eq "Online" -or $_.State -eq "Pending") }
            if ($runningVMs) {
                $remainingVMs = $runningVMs | Select-Object -ExpandProperty Name
                if ($Force) {
                    Write-Host "Warning: The following VMs did not shut down within 10 minutes: $($remainingVMs -join ', '). Continuing due to -Force flag." -ForegroundColor Yellow
                } else {
                    Write-Host "Error: Virtual machines did not shut down within 10 minutes." -ForegroundColor Red
                    Write-Host "Remaining VMs: $($remainingVMs -join ', ')" -ForegroundColor Red
                    throw "VM shutdown timeout - the following VMs are still running: $($remainingVMs -join ', ')"
                }
            }
        }
    }

    # Stop all running service cluster groups
    Write-Verbose "Stopping cluster service groups..."
    Get-ClusterGroup -Cluster $clusterName |
    Where-Object { $_.Name -like "Azure Stack HCI *" -or $_.Name -eq "Cloud Management" -or $_.Name -eq "SDDC Group" -or ($_.GroupType -eq "GenericService" -and $_.Name -like "ca*") } |
    ForEach-Object { Stop-ClusterGroup -InputObject $_ -ErrorAction SilentlyContinue }

    # Wait for storage jobs to complete before bringing resources offline
    # Storage jobs must complete to avoid data corruption and cluster health issues
    Write-Verbose "Checking for running storage jobs..."
    if ($ClusterName) {
        $storageJobs = Invoke-Command -ComputerName $nodes[0].Name -ScriptBlock { Get-StorageJob } -ErrorAction SilentlyContinue
    } else {
        $storageJobs = Get-StorageJob -ErrorAction SilentlyContinue
    }
    if ($storageJobs) {
        Write-Host "Warning: Storage jobs are still running. Waiting for completion (timeout: 15 minutes)..." -ForegroundColor Yellow
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $timeout = [TimeSpan]::FromMinutes(15)
        
        # Poll for job completion every 30 seconds
        while ($stopwatch.Elapsed -lt $timeout) {
            if ($ClusterName) {
                $runningJobs = Invoke-Command -ComputerName $nodes[0].Name -ScriptBlock { Get-StorageJob } -ErrorAction SilentlyContinue
            } else {
                $runningJobs = Get-StorageJob -ErrorAction SilentlyContinue
            }
            if (-not $runningJobs) {
                Write-Verbose "All storage jobs completed."
                break
            }
            Write-Verbose "Still waiting for storage jobs... ($($stopwatch.Elapsed.Minutes)m $($stopwatch.Elapsed.Seconds)s elapsed)"
            Start-Sleep -Seconds 30
        }
        
        # Handle timeout - abort if not using -Force, otherwise warn and continue
        if ($stopwatch.Elapsed -ge $timeout) {
            if ($ClusterName) {
                $remainingJobs = Invoke-Command -ComputerName $nodes[0].Name -ScriptBlock { Get-StorageJob } -ErrorAction SilentlyContinue
            } else {
                $remainingJobs = Get-StorageJob -ErrorAction SilentlyContinue
            }
            if ($remainingJobs) {
                if ($Force) {
                    Write-Host "Warning: Storage jobs did not complete within 15 minutes. Continuing shutdown due to -Force flag." -ForegroundColor Yellow
                } else {
                    Write-Host "Error: Storage jobs did not complete within 15 minutes. Shutdown aborted." -ForegroundColor Red
                    Write-Host "Action required: The cluster roles may need to be restarted. Check cluster status and storage jobs before retrying shutdown." -ForegroundColor Yellow
                    throw "Storage jobs timeout - cluster roles may need restart."
                }
            }
        }
    }

    # Bring cluster shared volumes (CSVs) offline
    Write-Verbose "Bringing cluster shared volumes offline..."
    Get-ClusterSharedVolume -Cluster $clusterName -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-ClusterResource -InputObject $_ -ErrorAction SilentlyContinue }

    # Bring storage pool offline
    Write-Verbose "Bringing cluster storage pool offline..."
    Get-ClusterResource -Cluster $clusterName -ErrorAction SilentlyContinue |
    Where-Object { $_.ResourceType -eq "Storage pool" } |
    ForEach-Object { Stop-ClusterResource -InputObject $_ -ErrorAction SilentlyContinue }

    # Disable cluster service on all nodes to prevent automatic restart
    # Executed remotely on each node to ensure proper service handling
    Write-Verbose "Changing cluster service status to Running-Disabled on all nodes..."
    $nodeNames = $nodes.Name
    $nodeNames | ForEach-Object {
        try {
            Invoke-Command -ComputerName $_ -ScriptBlock {
                Set-Service -Name clussvc -StartupType Disabled
            } -ErrorAction Stop
            Write-Verbose "Cluster service disabled on $_"
        }
        catch {
            Write-Host "Warning: Failed to disable cluster service on $_ : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Stop the failover cluster
    Write-Verbose "Stopping failover cluster..."
    Stop-Cluster -Cluster $clusterName -Force -ErrorAction Stop

    # Power off cluster nodes if requested
    if ($PowerOff) {
        Write-Host "Powering off cluster nodes..." -ForegroundColor Yellow
        $nodeNames | ForEach-Object {
            try {
                Write-Verbose "Sending shutdown command to $_"
                Invoke-Command -ComputerName $_ -ScriptBlock {
                    Stop-Computer -Force
                } -ErrorAction Stop
                Write-Host "Node $_ is shutting down." -ForegroundColor Green
            }
            catch {
                Write-Host "Warning: Failed to power off node $_ : $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        Write-Host "Shutdown command sent to all nodes." -ForegroundColor Green
    }

    Write-Host "Cluster '$clusterName' has been shut down successfully." -ForegroundColor Green
}
catch {
    Write-Error "An error occurred during cluster shutdown: $($_.Exception.Message)"
    exit 1
}
if ($Log) { Stop-Transcript | Out-Null }
exit 0

