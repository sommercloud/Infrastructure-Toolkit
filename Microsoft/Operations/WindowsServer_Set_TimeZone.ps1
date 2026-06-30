# Quick Copy and Paste:
# Set-TimeZone -ID "W. Europe Standard Time"

# Set the time zone on multiple servers remotely using PowerShell Remoting
$TimeZone = "W. Europe Standard Time"
$Servers = "Server1","Server2"

Invoke-Command -ComputerName $Servers -ScriptBlock {
Set-TimeZone -ID $using:TimeZone
}
