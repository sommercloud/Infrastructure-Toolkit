# Set Parameters
$ComputerName = "Server01"
$Credential = Get-Credential
$SourcePath = "C:\source\file.txt"
$DestinationPath = "C:\destination\file.txt"

#Copy file to remote server
$session = New-PSSession -ComputerName $ComputerName -Credential $Credential

Copy-Item -Path $SourcePath -Destination $DestinationPath -ToSession $session