# comma-separated list of cluster names, e.g. "clustername1,clustername2"
$cluster = "clustername1","clustername2"
$partitioncount = 6
# install the GPU-P driver when a node reports no partitionable GPU
$installDriverIfMissing = $false   #possible values: $true, $false
$nvidiadriver = "C:\ClusterStorage\Infrastructure_1\NVIDIA\Azure_Local\Display.Driver\nvgridswhci.inf"

$clusters = $cluster -split "," | ForEach-Object { $_.Trim() }
$nodes = foreach ($c in $clusters) { (Get-ClusterNode -Cluster $c).Name }

$results = foreach ($node in $nodes) {
    Invoke-Command -ComputerName $node -ScriptBlock {
        $gpus = Get-VMHostPartitionableGpu

        if (-not $gpus) {
            if ($using:installDriverIfMissing) {
                pnputil /add-driver $using:nvidiadriver /install /force
                $gpus = Get-VMHostPartitionableGpu
            }
            else {
                [PSCustomObject]@{ Name = "n/a"; PartitionCount = "No partitionable GPU found" }
            }
        }

        if ($gpus) {
            $gpus | ForEach-Object {
                Set-VMHostPartitionableGpu -Name $_.Name -PartitionCount $using:partitioncount
            }
            Get-VMHostPartitionableGpu | Select-Object Name, PartitionCount
        }
    }
}

$results | Select-Object @{N = 'NodeName'; E = { $_.PSComputerName } }, Name, PartitionCount | Format-Table -AutoSize