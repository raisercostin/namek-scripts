# from https://community.spiceworks.com/scripts/show/4484-disable-random-hardware-address-option-in-windows-10
#
# Disable Random Hardware Address Option in Windows 10 by adding the hardware address to registry.
# After script is run please reboot for setting to take effect
#
#
Write-Output "Disable Random Hardware Address Option in Windows 10"
#Get wireless adapters
$NetAdapter = Get-NetAdapter | Where-Object { $_.MediaType -match 'Native 802.11' }
#Check if there are more than One Wireless adapter
if ($NetAdapter[1]) { 
  Write-Output "More than One Wireless Adapter detected. Can't Continue." 
}
#Check if there are no wireless adapters
elseif ( !($NetAdapter)) { 
  Write-Output "No Wireless Adapter detected. Can't Continue" 
}
else { 
  #Remove - from MAC Address
  $MAC = $NetAdapter.MacAddress.Replace('-', $null)
  #Find Wireless Adapter Registry Key
  $i = 0
  $Found = $false 
  while (!$found) { 
    $Regkey = 'HKLM:SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}\' + "$i".PadLeft(4, '0')
    if (((Get-ItemProperty -Path $Regkey).NetCfgInstanceId) -match $NetAdapter.InstanceID) { 
      $Found = $true
      Set-ItemProperty -Path $Regkey -Name NetworkAddress -Value $MAC 
      Write-Output "Please reboot for setting to take effect" 
    } 
    else {
      $i++ 
    }
  }
}