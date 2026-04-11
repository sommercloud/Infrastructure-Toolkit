#Config
$Proxy = "http://192.0.2.254:8080"
$Domain = "testdomain.local"
$Nodes = "Nodename01,Nodename02,Nodename03"
$Clustername = "Cluster01"
$MgmtNet = '192.0.2.*'

Set-WinInetProxy -ProxySettingsPerUser 0 -ProxyServer $Proxy -ProxyBypass "localhost,127.0.0.1,169.254.*,$MgmtNet,*.$Domain,$Nodes,$Clustername"

Set-winhttpproxy -proxyserver $Proxy -BypassList "localhost,127.0.0.1,169.254.*,$MgmtNet,*.$Domain,$Nodes,$Clustername"

[Environment]::SetEnvironmentVariable("HTTPS_PROXY", $Proxy, "Machine")
$env:HTTPS_PROXY = [System.Environment]::GetEnvironmentVariable("HTTPS_PROXY", "Machine")
[Environment]::SetEnvironmentVariable("HTTP_PROXY", $Proxy, "Machine")
$env:HTTP_PROXY = [System.Environment]::GetEnvironmentVariable("HTTP_PROXY", "Machine")
$no_proxy = "localhost,127.0.0.1,.svc,kubernetes.default.svc,.svc.cluster.local,192.168.1.0/24,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.$Domain,$Nodes,$Clustername,169.254.0.0/16"
[Environment]::SetEnvironmentVariable("NO_PROXY", $no_proxy, "Machine")
$env:NO_PROXY = [System.Environment]::GetEnvironmentVariable("NO_PROXY", "Machine")

<#
=====================
Show Proxy Settings
=====================

#View WinInetproxy
Get-WinhttpProxy -Advanced

#View winhttpproxy
Get-WinhttpProxy -Default

#View Environment
echo "https :" $env:https_proxy "http :" $env:http_proxy "bypasslist " $env:no_proxy

#>

<# 
=====================
Reset Proxy Settings
=====================

#Reset WinInetproxy
Set-WinInetProxy

#Reset winhttpproxy
Reset-WinhttpProxy -Direct

#Reset Environment
[Environment]::SetEnvironmentVariable("HTTPS_PROXY", $null, "Machine")
$env:HTTPS_PROXY = [System.Environment]::GetEnvironmentVariable("HTTPS_PROXY", "Machine")
[Environment]::SetEnvironmentVariable("HTTP_PROXY", $null, "Machine")
$env:HTTP_PROXY = [System.Environment]::GetEnvironmentVariable("HTTP_PROXY", "Machine")
#>