<#
.SYNOPSIS
Creates a large clustered Hyper-V test VM, starts it, and live migrates it to measure RDMA performance during large memory transfers.

.DESCRIPTION
This script creates a new Hyper-V virtual machine on a specified failover cluster
to validate and measure RDMA-based live migration performance under large memory workloads.

The VM is created without any virtual hard disk and is configured with static startup memory.
After creation, the VM is added as a clustered role and started so that the configured memory
is allocated on the initial owner node.

Once the VM is running, it is live-migrated to another available cluster node.
During the migration, the script can monitor RDMA activity remotely on the participating nodes
and measure the duration and average throughput of the migration.

The script is intended to test the behavior of large live migrations, including transfer time,
RDMA utilization, and potential bottlenecks in the migration path.

A suitable Cluster Shared Volume (CSV) with sufficient free space is selected automatically
to host the VM configuration and runtime files.

By default, the VM name is "BigVM" and the startup memory size is 128 GB.

.PARAMETER ClusterName
Name of the failover cluster on which the VM should be created.

.PARAMETER VMName
Name of the virtual machine to create.
Default: BigVM

.PARAMETER MemoryGB
Amount of static startup memory in GB.
Default: 128

.PARAMETER Cleanup
If specified, the script will remove the created VM and clustered role.

.PARAMETER Log
Path to a log file where all operations and outputs will be recorded.

.PARAMETER MigrationTimeoutMinutes
Maximum duration in minutes to wait for the live migration to complete. Minimum 1, maximum 120; default 15.

.EXAMPLE
.\BigVM_Test.ps1 -ClusterName CLUSTER01 -Cleanup -Log C:\Logs\BigVM_Test.log

Creates a VM named BigVM with 128 GB static memory on cluster CLUSTER01 and starts it.
Then, it removes the created VM and clustered role and logs all operations to C:\Logs\BigVM_Test.log.

.EXAMPLE
.\BigVM_Test.ps1 -ClusterName CLUSTER01 -MemoryGB 256

Creates a VM named BigVM with 256 GB static memory on cluster CLUSTER01 and starts it.

.EXAMPLE
.\BigVM_Test.ps1 -ClusterName CLUSTER01 -VMName BigVM01 -MemoryGB 192

Creates a VM named BigVM01 with 192 GB static memory on cluster CLUSTER01 and starts it.

.EXAMPLE
.\BigVM_Test.ps1 -ClusterName CLUSTER01 -VMName BigVM01 -MemoryGB 192 -MigrationTimeoutMinutes 20

Same as above but enforces a 20-minute migration timeout.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ClusterName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VMName = 'BigVM',

    [Parameter()]
    [ValidateRange(1, 4096)]
    [int]$MemoryGB = 128,

    [Parameter()]
    [ValidateRange(1,1024)]
    [int]$CsvFreeSpaceBufferGB = 10,

    [Parameter()]
    [ValidateRange(1,120)]
    [int]$MigrationTimeoutMinutes = 15,

    [switch]$Cleanup,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
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

# Section: Helper function: Get-RDMALiveMigrationStats
function Get-RDMALiveMigrationStats {    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ComputerName
    )

    $counterPaths = @(
    '\RDMA Activity(*)\RDMA Outbound Bytes/sec',
    '\RDMA Activity(*)\RDMA Inbound Bytes/sec',
    '\RDMA Activity(*)\RDMA Active Connections'
    )

    $results = foreach ($computer in $ComputerName) {
        try {
            Invoke-Command -ComputerName $computer -ScriptBlock {
                param($Paths)

                $samples = Get-Counter -Counter $Paths -ErrorAction Stop

                foreach ($sample in $samples.CounterSamples) {
                    [PSCustomObject]@{
                        ComputerName  = $env:COMPUTERNAME
                        CounterPath   = $sample.Path
                        InstanceName  = $sample.InstanceName
                        ValueBytesSec = [double]$sample.CookedValue
                        ValueMBsec    = [math]::Round(($sample.CookedValue / 1MB), 2)
                        Timestamp     = Get-Date
                    }
                }
            } -ArgumentList (, $counterPaths) -ErrorAction Stop
        }
        catch {
            [PSCustomObject]@{
                ComputerName  = $computer
                CounterPath   = 'N/A'
                InstanceName  = 'N/A'
                ValueBytesSec = 0
                ValueMBsec    = 0
                Timestamp     = Get-Date
                Error         = $_.Exception.Message
            }
        }
    }

    return $results
}
# Main execution flow
try {
    # Section: Check required modules and cmdlets
    Write-Verbose "Checking if Failover Clustering cmdlets are available."
    if (-not (Get-Command -Name Get-ClusterNode -ErrorAction SilentlyContinue)) {
        throw "The cmdlet 'Get-ClusterNode' was not found. Please install the Failover Clustering management tools or feature."
    }

    Write-Verbose "Checking if Hyper-V cmdlets are available."
    if (-not (Get-Command -Name New-VM -ErrorAction SilentlyContinue)) {
        throw "The cmdlet 'New-VM' was not found. Please install the Hyper-V PowerShell module."
    }

    # Section: Locate cluster nodes and determine target
    Write-Verbose "Querying cluster nodes for cluster '$ClusterName'."
    $ClusterNodes = Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop |
        Where-Object { $_.State -eq 'Up' }

    if (-not $ClusterNodes) {
        throw "No available cluster nodes in cluster '$ClusterName' were found."
    }

    $TargetNode = $ClusterNodes[0].Name
    Write-Verbose "Using cluster node '$TargetNode'."

    # Section: Choose Cluster Shared Volume (CSV) for VM storage
    Write-Verbose "Querying Cluster Shared Volumes."

    $RequiredFreeSpaceGB = $MemoryGB + $CsvFreeSpaceBufferGB

    $CsvCandidates = Get-ClusterSharedVolume -Cluster $ClusterName -ErrorAction Stop | ForEach-Object {
        $CsvPath = $_.SharedVolumeInfo.FriendlyVolumeName
        $Partition = $_.SharedVolumeInfo.Partition

        if (-not $CsvPath -or -not $Partition) {
            return
        }

        [PSCustomObject]@{
            Name        = $_.Name
            Path        = $CsvPath
            FreeSpaceGB = [math]::Round(($Partition.FreeSpace / 1GB), 2)
        }
    }

    $Csv = $CsvCandidates |
        Where-Object { $_.FreeSpaceGB -ge $RequiredFreeSpaceGB } |
        Sort-Object FreeSpaceGB -Descending |
        Select-Object -First 1

    if (-not $Csv) {
        throw "No CSV with at least $RequiredFreeSpaceGB GB free space was found on cluster '$ClusterName'."
    }

    $CsvPath = $Csv.Path

    Write-Verbose "Selected CSV '$($Csv.Name)' with $($Csv.FreeSpaceGB) GB free space."

    $VmPath = Join-Path -Path $CsvPath -ChildPath $VMName

    # Section: Create VM with specified memory
    $MemoryBytes = $MemoryGB * 1GB

    Write-Verbose "Checking whether VM '$VMName' already exists on node '$TargetNode'."
    $ExistingVM = Invoke-Command -ComputerName $TargetNode -ScriptBlock {
        param($Name)
        Get-VM -Name $Name -ErrorAction SilentlyContinue
    } -ArgumentList $VMName

    if ($ExistingVM) {
        throw "A VM named '$VMName' already exists."
    }

    Write-Host "Creating VM '$VMName' on node '$TargetNode' with $MemoryGB GB static memory..." -ForegroundColor Yellow

    Invoke-Command -ComputerName $TargetNode -ScriptBlock {
        param($Name, $Path, $Memory)

        if (-not (Test-Path -Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }

        New-VM -Name $Name -Path $Path -Generation 2 -NoVHD -MemoryStartupBytes $Memory | Out-Null
        Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes $Memory | Out-Null
    } -ArgumentList $VMName, $VmPath, $MemoryBytes -ErrorAction Stop

    Write-Host "Adding VM '$VMName' as clustered role..." -ForegroundColor Yellow
    Add-ClusterVirtualMachineRole -VMName $VMName -Cluster $ClusterName -ErrorAction Stop | Out-Null

        Write-Host "Starting VM '$VMName'..." -ForegroundColor Yellow
    Start-ClusterGroup -Cluster $ClusterName -Name $VMName -ErrorAction Stop | Out-Null

    Start-Sleep -Seconds 5
    # Section: Live migrate the VM
    $ClusterGroup = Get-ClusterGroup -Cluster $ClusterName -Name $VMName -ErrorAction Stop
    $CurrentOwner = $ClusterGroup.OwnerNode.Name

    Write-Verbose "Current owner node after start is '$CurrentOwner'."

    $DestinationNode = $ClusterNodes |
        Where-Object { $_.Name -ne $CurrentOwner } |
        Select-Object -First 1 -ExpandProperty Name

    if (-not $DestinationNode) {
        throw "Could not determine a destination node for live migration."
    }

    Write-Host "Live migrating VM '$VMName' from '$CurrentOwner' to '$DestinationNode'..." -ForegroundColor Yellow

    $MigrationStart = Get-Date
    $MigrationTimeout = [TimeSpan]::FromMinutes($MigrationTimeoutMinutes)
    $MonitorNodes = @($CurrentOwner, $DestinationNode) | Select-Object -Unique

    Move-ClusterVirtualMachineRole -Cluster $ClusterName -Name $VMName -Node $DestinationNode -MigrationType Live -Wait 0 -ErrorAction Stop | Out-Null
    # Section: Monitor migration progress and RDMA stats
    do {
        Start-Sleep -Seconds 2

        $ClusterGroup = Get-ClusterGroup -Cluster $ClusterName -Name $VMName -ErrorAction Stop
        $OwnerNode = $ClusterGroup.OwnerNode.Name
        $State = $ClusterGroup.State

        $RdmaStats = Get-RDMALiveMigrationStats -ComputerName $MonitorNodes

        $NodeSummary = foreach ($NodeName in $MonitorNodes) {
        $NodeCounters = $RdmaStats | Where-Object { $_.ComputerName -eq $NodeName }

        $RdmaOutbound = ($NodeCounters | Where-Object { $_.CounterPath -like '*RDMA Activity(*)\RDMA Outbound Bytes/sec' } | Measure-Object -Property ValueMBsec -Sum).Sum
        $RdmaInbound  = ($NodeCounters | Where-Object { $_.CounterPath -like '*RDMA Activity(*)\RDMA Inbound Bytes/sec' }  | Measure-Object -Property ValueMBsec -Sum).Sum
        $RdmaConn     = ($NodeCounters | Where-Object { $_.CounterPath -like '*RDMA Activity(*)\RDMA Active Connections' } | Measure-Object -Property ValueBytesSec -Sum).Sum
        
        "{0}: RDMA Outbound={1} MB/s, RDMA Inbound={2} MB/s, Active Connections={3}" -f `
        $NodeName, `
        [math]::Round($(if ($null -eq $RdmaOutbound) { 0 } else { $RdmaOutbound }), 2), `
        [math]::Round($(if ($null -eq $RdmaInbound)  { 0 } else { $RdmaInbound }), 2), `
        [math]::Round($(if ($null -eq $RdmaConn)     { 0 } else { $RdmaConn }), 0)
        }

        Write-Host "Live migrating... Current owner: $OwnerNode | Target: $DestinationNode | State: $State"
        $NodeSummary | ForEach-Object { Write-Host "  $_" }

        if ($State -in 'Failed', 'PartialOnline', 'Offline') {
            Write-Warning "Migration state changed to '$State', aborting monitoring loop."
            break
        }

    }
    until (($OwnerNode -eq $DestinationNode -and $State -eq 'Online') -or ((Get-Date) - $MigrationStart -gt $MigrationTimeout))

    if ($OwnerNode -ne $DestinationNode -or $State -ne 'Online') {
        Write-Warning "Live migration did not complete within $MigrationTimeoutMinutes minutes. Last state: $State on node $OwnerNode."
        try {
            Move-ClusterVirtualMachineRole -Cluster $ClusterName -Name $VMName -Cancel -ErrorAction Stop | Out-Null
            Write-Warning "Attempted to cancel the live migration for VM '$VMName' due to timeout."
        }
        catch {
            Write-Warning "Failed to cancel live migration via Move-ClusterVirtualMachineRole -Cancel: $($_.Exception.Message)"
        }

        throw "Live migration timed out after $MigrationTimeoutMinutes minutes and was aborted. Last state: $State on node $OwnerNode."
    }

    $MigrationEnd = Get-Date
    $MigrationDuration = $MigrationEnd - $MigrationStart

    Write-Host "VM '$VMName' was created, started, and successfully live migrated to '$DestinationNode'." -ForegroundColor Green
    Write-Host ("Migration time: {0:hh\:mm\:ss}" -f $MigrationDuration) -ForegroundColor Green

    # Section: Conditional cleanup of VM and role resources
    if ($Cleanup) {
        Write-Host "Cleanup requested. Removing VM '$VMName' and all associated files..." -ForegroundColor Yellow

        Stop-ClusterGroup -Cluster $ClusterName -Name $VMName -ErrorAction SilentlyContinue | Out-Null

        Remove-ClusterGroup -Cluster $ClusterName -Name $VMName -RemoveResources -Force -ErrorAction Stop | Out-Null

        Invoke-Command -ComputerName $DestinationNode -ScriptBlock {
            param($Name, $Path)

            $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
            if ($vm) {
                Remove-VM -Name $Name -Force
            }

            if (Test-Path $Path) {
                Remove-Item -Path $Path -Recurse -Force
            }
        } -ArgumentList $VMName, $VmPath -ErrorAction Stop

        Write-Host "Cleanup completed." -ForegroundColor Green
    }
}
catch {
    if ($Log) { Stop-Transcript | Out-Null }
    Write-Error $_.Exception.Message
}
if ($Log) { Stop-Transcript | Out-Null }