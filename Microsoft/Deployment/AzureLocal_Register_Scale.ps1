<#
.SYNOPSIS
Registers Azure Local nodes via Arc initialization at scale.

.DESCRIPTION
Connects to each node via PSRemoting and runs Invoke-AzStackHciArcInitialization
using a Service Principal. Use this script to onboard Azure Local nodes to Azure Arc.

.NOTES
    Author       : Peter Sommer (Sommercloud)
    Prerequisites: Az PowerShell module, PSRemoting enabled on all nodes
#>

# ===================== CUSTOMIZE =====================
$TrustedHosts  = "192.0.2.*"                        # IP range of the nodes (e.g. "192.168.1.*")

$SPAppID           = "<insert SPN App ID>"          # App ID of the Service Principal (Entra App Registration)
$SPNSecret         = "<insert SPN Secret>"          # Client Secret of the Service Principal
$SubscriptionID    = "<insert Subscription ID>"     # Azure Subscription ID
$tenant            = "<insert Tenant ID>"           # Azure Tenant ID (Entra Directory ID)
$ResourceGroupName = "<insert Resource Group Name>" # Target Resource Group in Azure

$Location = "westeurope"  # Azure Region
$Cloud    = "AzureCloud"  # AzureCloud | AzureChinaCloud | AzureUSGovernment

$targetsolutionversion = "12.2606.1003.205"  # Target Azure Local solution version

$Servers = "192.0.2.11","192.0.2.12","192.0.2.13"  # IP addresses of all nodes

# =================== DO NOT MODIFY ===================

Set-Item WSMan:\localhost\Client\TrustedHosts -Value $TrustedHosts -Force
$SecuredPassword = ConvertTo-SecureString $SPNSecret -AsPlainText -Force
$Credentials= New-Object System.Management.Automation.PSCredential ($SPAppID,$SecuredPassword)
$localCredentials = Get-Credential -Message "Enter local admin credentials for the nodes" -UserName "Administrator"

foreach ($server in $servers) {
    Invoke-Command -ComputerName $server -Credential $localCredentials -ScriptBlock {

        Connect-AzAccount -ServicePrincipal -Credential $using:Credentials -Tenant $using:tenant
        $ARMtoken = [System.Net.NetworkCredential]::new("", (Get-AzAccessToken).Token).Password
        $id = (Get-AzContext).Account.Id
        Invoke-AzStackHciArcInitialization -SubscriptionID $using:SubscriptionID -ResourceGroup $using:ResourceGroupName -TenantID $using:tenant -Cloud $using:Cloud -Region $using:Location -ArmAccessToken $ARMtoken -AccountID $id -TargetSolutionVersion $using:targetsolutionversion -Verbose
    }
}
