<#
.SYNOPSIS
    Gracefully starts up an Azure Local (HCI) cluster.

.DESCRIPTION
    Performs a controlled startup of an Azure Local cluster by first checking node reachability,
    then starting cluster resources, services, and groups in the correct order. Includes verbose logging for each step.

.PARAMETER ClusterName
    Name of the cluster to start up.

.PARAMETER ClusterNodes
    Array of cluster nodes to check for reachability before startup. Can be passed as separate quoted strings or a comma-separated string.

.PARAMETER StartVM
    If specified, starts all virtual machine cluster groups after cluster startup.

.PARAMETER Log
    If specified, logs all output to the given file path. The file will be appended if it exists.

.EXAMPLE
    .\AzureLocal_Cluster_Startup.ps1 -ClusterName HCI-CLUSTER01 -ClusterNodes "Node1","Node2","Node3"
    Starts up the cluster named HCI-CLUSTER01, starting the specified nodes if offline.

.EXAMPLE
    .\AzureLocal_Cluster_Startup.ps1 -ClusterName HCI-CLUSTER01 -ClusterNodes "Node1,Node2,Node3"
    Starts up the cluster named HCI-CLUSTER01, starting the specified nodes if offline (comma-separated).

.EXAMPLE
    .\AzureLocal_Cluster_Startup.ps1 -ClusterName HCI-CLUSTER01 -ClusterNodes "Node1","Node2","Node3" -StartVM
    Starts up the cluster and all virtual machines.

.EXAMPLE
    .\AzureLocal_Cluster_Startup.ps1 -ClusterName HCI-CLUSTER01 -ClusterNodes "Node1,Node2,Node3" -Log "C:\Logs\AzureLocal_Cluster_Startup.log"
    Starts up the cluster and logs all output to the specified file.

.NOTES
    Author      : Peter Sommer
    Version     : 1.0.0
    Created     : 2026-03-25
    Prerequisites: Administrative privileges, Failover Clustering tools.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterName,

    [Parameter(Mandatory = $true)]
    [string[]]$ClusterNodes,

    [Parameter()]
    [switch]$StartVM,

    [Parameter()]
    [string]$Log
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
    Write-Verbose "Target cluster: $ClusterName"
    Write-Verbose "Cluster nodes: $($ClusterNodes -join ', ')"

    # Phase 1: Check if all cluster nodes are reachable
    Write-Verbose "Checking if all cluster nodes are reachable..."
    $unreachableNodes = @()
    foreach ($node in $ClusterNodes) {
        try {
            $reachable = Test-Connection -ComputerName $node -Count 1 -Quiet
            if (-not $reachable) {
                $unreachableNodes += $node
            } else {
                Write-Host "Node $node is reachable." -ForegroundColor Green
            }
        } catch {
            $unreachableNodes += $node
            Write-Host "Warning: Could not check reachability for node $node : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if ($unreachableNodes) {
        Write-Host "Error: The following nodes are not reachable: $($unreachableNodes -join ', '). Cannot proceed with cluster startup." -ForegroundColor Red
        throw "Unreachable nodes: $($unreachableNodes -join ', ')"
    } else {
        Write-Host "All cluster nodes are reachable." -ForegroundColor Green
    }

    # Phase 2: Set cluster service startup type and ensure the service is running on all nodes
    Write-Verbose "Configuring and starting cluster service on all nodes..."
    $ClusterNodes | ForEach-Object {
        try {
            Invoke-Command -ComputerName $_ -ScriptBlock {
                Set-Service -Name clussvc -StartupType Automatic

                $svc = Get-Service -Name clussvc -ErrorAction Stop
                if ($svc.Status -ne 'Running') {
                    Start-Service -Name clussvc -ErrorAction Stop
                    $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
                }
            } -ErrorAction Stop
            Write-Verbose "Cluster service is running on $_"
        } catch {
            Write-Host "Warning: Failed to configure/start cluster service on $_ : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Phase 3: Start the failover cluster
    Write-Verbose "Starting failover cluster..."
    try {
        Start-Cluster -Cluster $ClusterName -ErrorAction Stop
    }
    catch {
        # If started from a non-cluster node, local Start-Cluster can fail.
        # Fallback to running the cmdlet directly on a cluster node.
        Write-Verbose "Local Start-Cluster failed: $($_.Exception.Message)"
        Write-Verbose "Retrying Start-Cluster remotely on node '$($ClusterNodes[0])'."
        Invoke-Command -ComputerName $ClusterNodes[0] -ScriptBlock {
            param($Name)
            Start-Cluster -Cluster $Name -ErrorAction Stop
        } -ArgumentList $ClusterName -ErrorAction Stop
    }
    Write-Host "Cluster '$ClusterName' has been started." -ForegroundColor Green

    # Phase 4: Start storage pool
    Write-Verbose "Starting cluster storage pool..."
    Get-ClusterResource -Cluster $ClusterName -ErrorAction SilentlyContinue |
    Where-Object { $_.ResourceType -eq "Storage pool" } |
    ForEach-Object { Start-ClusterResource -InputObject $_ -ErrorAction SilentlyContinue }

    # Phase 5: Start cluster shared volumes (CSVs)
    Write-Verbose "Starting cluster shared volumes..."
    Get-ClusterSharedVolume -Cluster $ClusterName -ErrorAction SilentlyContinue |
    ForEach-Object { 
        Start-ClusterResource -InputObject $_ -ErrorAction SilentlyContinue
        Write-Host "Started CSV: $($_.Name)" -ForegroundColor Green
    }

    # Phase 6: Wait for storage jobs to complete
    Write-Verbose "Checking for running storage jobs..."
    $storageJobs = Get-StorageJob -ErrorAction SilentlyContinue
    if ($storageJobs) {
        Write-Host "Waiting for storage jobs to complete..." -ForegroundColor Yellow
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $timeout = [TimeSpan]::FromMinutes(15)

        while ($stopwatch.Elapsed -lt $timeout) {
            $runningJobs = Get-StorageJob -ErrorAction SilentlyContinue
            if (-not $runningJobs) {
                Write-Verbose "All storage jobs completed."
                break
            }
            Write-Verbose "Still waiting for storage jobs... ($($stopwatch.Elapsed.Minutes)m $($stopwatch.Elapsed.Seconds)s elapsed)"
            Start-Sleep -Seconds 30
        }

        if ($stopwatch.Elapsed -ge $timeout) {
            $remainingJobs = Get-StorageJob -ErrorAction SilentlyContinue
            if ($remainingJobs) {
                Write-Host "Warning: Storage jobs did not complete within 15 minutes. Continuing startup." -ForegroundColor Yellow
            }
        }
    }

    # Check CSV and virtual disk health after storage jobs
    Write-Verbose "Checking CSV health..."
    $unhealthyCSVs = Get-ClusterSharedVolume -Cluster $ClusterName -ErrorAction SilentlyContinue |
    Where-Object { $_.State -ne "Online" }
    if ($unhealthyCSVs) {
        Write-Host "Warning: The following CSVs are not healthy: $($unhealthyCSVs.Name -join ', '). Virtual machines will not be started." -ForegroundColor Yellow
        throw "Unhealthy CSVs detected: $($unhealthyCSVs.Name -join ', ')"
    } else {
        Write-Host "All CSVs are healthy." -ForegroundColor Green
    }

    Write-Verbose "Checking virtual disk health..."
    $unhealthyVDs = Get-VirtualDisk -ErrorAction SilentlyContinue |
    Where-Object { $_.HealthStatus -ne "Healthy" }
    if ($unhealthyVDs) {
        Write-Host "Warning: The following virtual disks are not healthy: $($unhealthyVDs.FriendlyName -join ', ') (Status: $($unhealthyVDs.HealthStatus -join ', ')). Virtual machines will not be started." -ForegroundColor Yellow
        throw "Unhealthy virtual disks detected: $($unhealthyVDs.FriendlyName -join ', ')"
    } else {
        Write-Host "All virtual disks are healthy." -ForegroundColor Green
    }

    # Phase 7: Start cluster service groups
    Write-Verbose "Starting cluster service groups..."
    Get-ClusterGroup -Cluster $ClusterName |
    Where-Object { $_.Name -like "Azure Stack HCI *" -or $_.Name -eq "Cloud Management" -or $_.Name -eq "SDDC Group" -or ($_.GroupType -eq "GenericService" -and $_.Name -like "ca*") } |
    ForEach-Object { Start-ClusterGroup -InputObject $_ -ErrorAction SilentlyContinue }

    # Phase 8: Start virtual machines if -StartVM is specified
    if ($StartVM) {
        Write-Verbose "Starting cluster virtual machine groups..."
        Get-ClusterGroup -Cluster $ClusterName |
        Where-Object { $_.GroupType -eq "VirtualMachine" } |
        ForEach-Object { Start-ClusterGroup -InputObject $_ -ErrorAction SilentlyContinue }
    }

    Write-Host "Cluster '$ClusterName' startup completed successfully." -ForegroundColor Green
}
catch {
    Write-Error "An error occurred during cluster startup: $($_.Exception.Message)"
    exit 1
}
if ($Log) { Stop-Transcript | Out-Null }
exit 0