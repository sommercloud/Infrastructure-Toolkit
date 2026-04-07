# Quick Copy and Paste:
# Add-LocalGroupMember -Group Administrators -Member "domain\user"

# Add a local administrator to multiple servers remotely using PowerShell Remoting
$Username = "domain\user"
$Servers = "Server1","Server2"

Invoke-Command -ComputerName $Servers -ScriptBlock {
Add-LocalGroupMember -Group Administrators -Member $using:Username
}
