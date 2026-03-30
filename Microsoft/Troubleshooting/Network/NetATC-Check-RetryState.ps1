<#
.SYNOPSIS
    Shows or resets the retry state for Network ATC Intents.

.DESCRIPTION
    Without parameters, displays the status of Network ATC Intents in a table.
    With -Remediate, resets the retry state for Intents that have ConfigurationStatus not 'Success' and RetryCount greater than 3.
    Optionally, specify a cluster to run the commands remotely on all cluster nodes.

.PARAMETER Remediate
    If specified, performs the reset operation instead of just showing the status.

.PARAMETER ClusterName
    Name of the failover cluster. If specified, commands are executed remotely on all cluster nodes.

.EXAMPLE
    .\NetATC-Check-RetryState.ps1
    Shows the current status of all Network ATC Intents on the local machine.

.EXAMPLE
    .\NetATC-Check-RetryState.ps1 -Remediate
    Resets the retry state for failed Intents with RetryCount > 3 on the local machine.

.EXAMPLE
    .\NetATC-Check-RetryState.ps1 -ClusterName HCI-CLUSTER01
    Shows the current status of all Network ATC Intents on all nodes of cluster HCI-CLUSTER01.

.EXAMPLE
    .\NetATC-Check-RetryState.ps1 -ClusterName HCI-CLUSTER01 -Remediate
    Resets the retry state for failed Intents with RetryCount > 3 on all nodes of cluster HCI-CLUSTER01.

.NOTES
    Author      : Peter Sommer (Sommercloud)
    Prerequisites: Administrative privileges, Network ATC module loaded, Failover Clustering tools if using -ClusterName.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Remediate,

    [Parameter()]
    [string]$ClusterName
)

$targets = @()
# Determine target nodes: either cluster nodes or local computer
if ($ClusterName) {
    Write-Verbose "Checking if Get-ClusterNode cmdlet is available."
    $clusterCommand = Get-Command -Name Get-ClusterNode -ErrorAction SilentlyContinue
    if (-not $clusterCommand) {
        throw "The cmdlet 'Get-ClusterNode' was not found. Please install Failover Clustering management tools."
    }

    Write-Verbose "Querying cluster nodes for cluster '$ClusterName'."
    $targets = (Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop).Name

    if (-not $targets -or $targets.Count -eq 0) {
        throw "No cluster nodes found in cluster '$ClusterName'."
    }
} else {
    $targets = $env:COMPUTERNAME
}

if ($Remediate) {
    # Retrieve Network ATC Intent status and identify failed intents that have exceeded retry threshold
    $status = Invoke-Command -ComputerName $targets[0] -ScriptBlock { Get-NetIntentStatus } -ErrorAction Stop
    $failedIntents = $status | Where-Object { $_.ConfigurationStatus -ne "Success" -and $_.RetryCount -gt 3 }

    # Group intents by host node to execute reset operations on each node locally
    $grouped = $failedIntents | Group-Object -Property Host
    foreach ($group in $grouped) {
        $node = $group.Name
        $intents = $group.Group
        Invoke-Command -ComputerName $node -ScriptBlock {
            param($intents)
            foreach ($intent in $intents) {
                Write-Host "Resetting RetryState for Intent '$($intent.IntentName)' on Host '$($intent.Host)'" -ForegroundColor Yellow
                Set-NetIntentRetryState -Name $intent.IntentName -NodeName $intent.Host
            }
        } -ArgumentList $intents -ErrorAction Stop
    }
} else {
    # Display current Network ATC Intent status without making changes
    $status = Invoke-Command -ComputerName $targets[0] -ScriptBlock { Get-NetIntentStatus } -ErrorAction Stop
    $status | Format-Table IntentName, Host, ConfigurationStatus, RetryCount

    # Alert user if remediation is needed
    $failedIntents = $status | Where-Object { $_.ConfigurationStatus -ne "Success" -and $_.RetryCount -gt 3 }
    if ($failedIntents) {
        Write-Host "Note: There are failed intents with RetryCount > 3. Use -Remediate to reset the retry state." -ForegroundColor Yellow
    }
}