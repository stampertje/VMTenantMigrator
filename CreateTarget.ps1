#Requires -module Az.Compute, Az.Accounts, Az.Storage, Az.Resources, Az.Network

[CmdletBinding()]
param (
    # can be either GUID or name.onmicrosoft.com
    [Parameter(Mandatory=$true)]
    [string]
    $TargetTenant,

    # Expecting GUID
    [Parameter(Mandatory=$true)]
    [string]
    $TargetSubscription,

    # The name of the target storage account
    [Parameter(Mandatory=$false)]
    [string]
    $SourceStorageAccountName,

    # Connectionstring for target storage account
    [Parameter(Mandatory=$false)]
    [string]
    $ConnectionString,

    # If name is specified only single VM will be migrated. Expecting the VMName
    [Parameter()]
    [string]
    $MigrateVM,

    # Defines if automation credentials should be used or 
    [Parameter()]
    [boolean]
    $InAutomationAccount=$false,

    # Creates vnet. Specify the name of the vnet to create.
    [Parameter()]
    [string]
    $CreateVNet
)

if ((get-azcontext).subscription.id -ne $TargetSubscription)
{
  If ($InAutomationAccount -eq $true)
  {

    $connectionName = "AzureRunAsConnection";
  
    try
    {
        # Get the connection "AzureRunAsConnection "
        $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName        
    
        "Logging in to Azure..."
        Add-AzAccount `
            -ServicePrincipal `
            -TenantId $servicePrincipalConnection.TenantId `
            -ApplicationId $servicePrincipalConnection.ApplicationId `
            -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
    }
    catch {
    
        if (!$servicePrincipalConnection)
        {
            $ErrorMessage = "Connection $connectionName not found."
            throw $ErrorMessage
        } else{
            Write-Error -Message $_.Exception
            throw $_.Exception
        }
    }

  } else {
    
    If ($NULL -eq (get-azcontext))
    {
      Login-AzAccount -Tenant $SourceTenant
    } Else {
      $response = Read-Host "Continue as " (get-azcontext).account " Y/N"
      If ($response -ieq "n")
      {
        Login-AzAccount -Tenant $SourceTenant
      }
    }

  }

  Select-AzSubscription -SubscriptionId $TargetSubscription
}

if($connectionstring){
  write-host "Using connectionstring to connect to storage account" -ForegroundColor Green
  $storageContext = New-AzStorageContext -ConnectionString $ConnectionString
}

if($UseCurrentAccount)
{
  write-host "Using current user to connect to storage account" -ForegroundColor Green
  $StorageContext = New-AzStorageContext -StorageAccountName $TargetStorageAccountName -UseConnectedAccount
}

$ContainerName = "vmbackup"

If ($CreateVNet)
{
  # Create virtual network
  Try{

    $file = $CreateVNet + ".xml"
    Get-AzStorageBlobContent `
      -Container $ContainerName `
      -Blob $file `
      -Context $storageContext `
      -Destination $env:TEMP -Force

    $vnetconfig = Import-Clixml $env:temp\$file

  } catch {
    'Could not read storage blob' | Write-Error -ErrorAction Stop
    throw
  }

  if (-not(Get-AzResourceGroup -name $vnetconfig.ResourceGroupName -ErrorAction SilentlyContinue))
  {
    $newrg = New-AzResourceGroup -Name $vnetconfig.ResourceGroupName -Location $vnetconfig.location
  } else {
    $newrg = Get-AzResourceGroup -name $vnetconfig.ResourceGroupName
  }

  If (-not(Get-AzVirtualNetwork -Name $vnetconfig.Name -ResourceGroupName $vnetconfig.ResourceGroupName -ErrorAction SilentlyContinue))
  {
      Write-host "Creating vnet" -ForegroundColor Green
      
      $vnet = New-AzVirtualNetwork -Name $vnetconfig.Name -Location $newrg.Location `
        -ResourceGroupName $newrg.ResourceGroupName `
        -AddressPrefix $vnetconfig.addressspace.AddressPrefixes  # will prolly not work with multiple

      Foreach ($subnet in $vnetconfig.Subnets)
      {
        Add-AzVirtualNetworkSubnetConfig `
          -Name $subnet.name `
          -AddressPrefix $subnet.AddressPrefix `
          -VirtualNetwork $vnet
      }

      if($NULL -ne $vnetconfig.DhcpOptions.DnsServers)
      {
        Foreach ($ip in $vnetconfig.DhcpOptions.DnsServers)
        {
          $vnet.DhcpOptions.DnsServers += $ip
        }
      }

      $vnet | Set-AzVirtualNetwork

  } else {
    
    Write-Error -message "vnet already exists" -ErrorAction Stop
  
  }
}

if ($MigrateVM)
{
  # Build vm config from old tenant
  $vmdisk = $MigrateVM + '_disks' # Name of the XML file
  $vmnic = $MigrateVM + '_nic' # Name of the XML file
  
  $files = $MigrateVM,$vmdisk,$vmnic

  Try{
    Foreach ($file in $files)
    {
      $file = $file + ".xml"
      Get-AzStorageBlobContent `
        -Container $ContainerName `
        -Blob $file `
        -Context $storageContext `
        -Destination $env:TEMP -Force
    }

    $vmconfig = Import-Clixml $env:temp\$MigrateVM.xml
    $diskConfig = Import-Clixml $env:temp\$vmdisk.xml
    $nicconfig = Import-Clixml $env:temp\$vmnic.xml

  } catch {
    'Failed reading config files' | Write-Error -ErrorAction Stop
    throw
  }

  # Create Resource Group
  if (-not(Get-AzResourceGroup -name $vmconfig.ResourceGroupName -ErrorAction SilentlyContinue))
  {
    $newrg = New-AzResourceGroup -Name $vmconfig.ResourceGroupName -Location $vmconfig.location
  } else {
    $newrg = Get-AzResourceGroup -name $vmconfig.ResourceGroupName
  }

$storageAccountID = (Get-AzResource -name $storagecontext.StorageAccountName | `
  Where-object {$_.ResourceType -eq "Microsoft.Storage/storageAccounts"}).ResourceID

  Foreach($disk in $diskConfig)
  {
    $storageType = $disk.sku.name

    $blobname = $disk.name + ".vhd"
    
    $blobstate = get-AzStorageBlobCopyState -Blob $blobname -Context $storageContext -Container $ContainerName -WaitForComplete

    $sourceVHDURI = $StorageContext.blobendpoint + $ContainerName + '/' + $blobname
    $newdiskConfig = New-AzDiskConfig -AccountType $storageType `
      -Location $disk.location `
      -CreateOption Import `
      -StorageAccountId $storageAccountID `
      -SourceUri $sourceVHDURI `
      -DiskSizeGB $disk.DiskSizeGB `
      -OsType $disk.ostype.value `
      -HyperVGeneration $disk.HyperVGeneration

    $newdisk = New-AzDisk -Disk $newdiskConfig -ResourceGroupName $newrg.ResourceGroupName -DiskName $disk.name

    $datadisks = @()
    If ($disk.name -eq $vmconfig.storageprofile.osdisk.name)
    {
      $osdiskid = $newdisk.id
    } else {
      $datadisks += $newdisk
    }
  }

  # NOTE Assuming only one IP config
  # Check if the virtual network exists
  $vnetName = $nicconfig.ipconfigurations[0].subnet.id.split("/")[$nicconfig.ipconfigurations[0].subnet.id.split("/").count-3]
  $SubnetName = $nicconfig.ipconfigurations[0].subnet.id.split("/")[$nicconfig.ipconfigurations[0].subnet.id.split("/").count-1]
  $vmnicName = $vmconfig.networkprofile.NetworkInterfaces.id.split("/")[$vmconfig.networkprofile.NetworkInterfaces.id.split("/").length-1]

  # Create network interface
  $IPconfig = New-AzNetworkInterfaceIpConfig -Name "IPConfig1" `
    -PrivateIpAddressVersion IPv4 `
    -PrivateIpAddress $nicconfig.ipconfigurations[0].privateipaddress `
    -SubnetId ((Get-AzVirtualNetwork -name $vnetname).Subnets | Where-Object {$_.Name -eq $SubnetName}).id

  $nic = New-AzNetworkInterface -Name $vmnicName `
    -ResourceGroupName $newrg.ResourceGroupName `
    -Location $newrg.Location `
    -IpConfiguration $IPconfig

  # Build VM
  $newVM = New-AzVMConfig -VMName $MigrateVM -VMSize $vmconfig.HardwareProfile.VmSize -Tags $vmconfig.Tags
  $newVM = Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id

  Set-AzVMOSDisk -VM $newVM `
    -CreateOption Attach `
    -ManagedDiskId $osdiskid `
    -Name $vmconfig.StorageProfile.OsDisk.Name `
    -Windows

  Foreach ($ddisk in $datadisks)
  {
    Add-AzVMDataDisk -VM $newVM `
      -Name $ddisk.Name `
      -ManagedDiskId $ddisk.ManagedDisk.Id `
      -Caching $ddisk.Caching `
      -Lun $ddisk.Lun `
      -DiskSizeInGB $ddisk.DiskSizeGB `
      -CreateOption Attach
  }

  New-AzVM -VM $newVM -ResourceGroupName $newrg.ResourceGroupName -Location $newrg.Location

}