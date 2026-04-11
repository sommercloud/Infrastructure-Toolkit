<#
.SYNOPSIS
Displays installed RAM modules and empty RAM slots on a computer.

.DESCRIPTION
The script queries physical memory modules and the total number of memory slots
through WMI. If no computer name is provided, the local computer is used.

.PARAMETER ComputerName
Name of the target computer for the WMI query. Optional.
Default is the local computer ($env:COMPUTERNAME).

.EXAMPLE
.\Show_RAM_Modules.ps1
Shows RAM information for the local computer.

.EXAMPLE
.\Show_RAM_Modules.ps1 -ComputerName Server01
Shows RAM information for computer Server01.

.NOTES
    Author       : Peter Sommer (Sommercloud)
    Prerequisites: WMI access on the target system
#>

[Cmdletbinding()]
Param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ComputerName = $env:COMPUTERNAME
)

$PhysicalMemory = Get-WmiObject -class "win32_physicalmemory" -namespace "root\CIMV2" -ComputerName $ComputerName

Write-Host "Computer: " -ForegroundColor Green -NoNewline
Write-Host $ComputerName

$ComputerSystem = Get-WmiObject -Class "Win32_ComputerSystem" -Namespace "root\CIMV2" -ComputerName $ComputerName
$VmPlatforms = @("virtual machine", "vmware", "virtualbox", "kvm", "xen")
$IsVirtualMachine = $VmPlatforms | Where-Object {
    $ComputerSystem.Model -match $_ -or $ComputerSystem.Manufacturer -match $_
}
if ($IsVirtualMachine) {
    Write-Host "WARNING: This computer is a virtual machine ($($ComputerSystem.Manufacturer) - $($ComputerSystem.Model)). RAM slot information may not be accurate." -ForegroundColor Yellow
}

Write-Host "Memory Modules:" -ForegroundColor Green
$PhysicalMemory | Format-Table Tag,BankLabel,@{n="Capacity(GB)";e={$_.Capacity/1GB}},Manufacturer,PartNumber,Speed -AutoSize
 
Write-Host "Total Memory:" -ForegroundColor Green
Write-Host "$((($PhysicalMemory).Capacity | Measure-Object -Sum).Sum/1GB)GB"
 
$TotalSlots = ((Get-WmiObject -Class "win32_PhysicalMemoryArray" -namespace "root\CIMV2" -ComputerName $ComputerName).MemoryDevices | Measure-Object -Sum).Sum
Write-Host "`nTotal Memory Slots:" -ForegroundColor Green
Write-Host $TotalSlots
 
$UsedSlots = (($PhysicalMemory) | Measure-Object).Count 
Write-Host "`nUsed Memory Slots:" -ForegroundColor Green
Write-Host $UsedSlots
 
If($UsedSlots -eq $TotalSlots)
{
    Write-Host "All memory slots are filled up, none is empty!" -ForegroundColor Yellow
}
else
{
    $EmptySlots = $TotalSlots - $UsedSlots
    Write-Host "Empty Memory Slots:" -ForegroundColor Green
    Write-Host $EmptySlots
}