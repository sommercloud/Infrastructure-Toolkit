# Creates a local admin user on remote servers and adds it to the local Administrators group.

# List of target servers
$Servers = @("Server1", "Server2", "Server3")

# User details
$Username = "<Username>"  # Set your desired username here
$FullName = "<FullName>" # Set the full name for the user here
$Description = "<Description>" # Set a description for the user here
$Password = "<Password>"  # Set your own secure password here

# Run remote command on all servers
foreach ($Server in $Servers) {
    Write-Host "Processing server: $Server"
    Invoke-Command -ComputerName $Server -ScriptBlock {
        $ExistingUser = Get-LocalUser -Name $using:Username -ErrorAction SilentlyContinue
        if ($ExistingUser) {
            Write-Host "User '$using:Username' already exists on $env:COMPUTERNAME"
        }
        else {
            $SecurePass = ConvertTo-SecureString $using:Password -AsPlainText -Force

            New-LocalUser -Name $using:Username -Password $SecurePass -FullName $using:FullName -Description $using:Description | Out-Null

            Add-LocalGroupMember -Group "Administrators" -Member $using:Username

            Write-Host "User '$using:Username' was created on $env:COMPUTERNAME and added to the Administrators group."
        }
    }
}