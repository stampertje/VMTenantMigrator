#Requires -module Az.Compute, Az.Accounts, Az.Storage

[CmdletBinding()]
param (
    # Temporary dir on local computer
    [Parameter(Mandatory=$true)]
    [string]
    $tempdir,

    # can be either GUID or name.onmicrosoft.com
    [Parameter(Mandatory=$true)]
    [string]
    $SourceTenant,

    # Expecting GUID
    [Parameter(Mandatory=$true)]
    [string]
    $SourceSubscription,

    # The name of the target storage account
    [Parameter(Mandatory=$true)]
    [string]
    $TargetStorageAccountName,

    # SAS key for target storage account
    [Parameter(Mandatory=$true)]
    [string]
    $TargetStorageAccountSAS,

    # If name is specified only single VM will be migrated. Expecting the VMName
    [Parameter()]
    [string]
    $MigrateSingleVM,

    # Defines if automation credentials should be used or 
    [Parameter()]
    $InAutomationAccount
)

if (!(test-path $tempdir)){mkdir $tempdir}

If ($InAutomationAccount)
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
  
  Login-AzAccount -Tenant $SourceTenant

}


Select-AzSubscription -SubscriptionId $SourceSubscription

#connect to storage account
$storageContext = New-AzureStorageContext -StorageAccountName $TargetStorageAccountName -SasToken $TargetStorageAccountSAS
$ContainerName = "vmbackup"
New-AzStorageContainer -Name $ContainerName -Context $storageContext -Permission Blob 

if ($MigrateSingleVM)
{
  $VMtoMigrate = Get-AzResource $MigrateSingleVM | Where-Object {$_.ResourceType -like "Microsoft.Compute/virtualMachines"}
} else {
  $VMtoMigrate = Get-AzVm
}

Foreach ($vm in $VMtoMigrate)
{
  $vmname = $vm.Name
  Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vmName | Export-Clixml C:\temp\$vmname.xml -Depth 5
  # copy xml to storage account

  Set-AzStorageBlobContent `
    -Context $storageContext `
    -Container $ContainerName `
    -File $tempdir\$vmname.xml `
    -Blob $vmname.xml `
    -force

  # shutdown vm if running
  Stop-VM $vm -Force

  # clone disk to storage account
  $osdisk = get-azdisk -ResourceGroupName $vm.ResourceGroupName -name $vm.StorageProfile.osdisk.name
  $sas = Grant-AzDiskAccess -ResourceGroupName $vm.ResourceGroupName -DiskName $osdisk.name -Access Read -DurationInSecond (60*60*24)
  Start-AzStorageBlobCopy -AbsoluteUri $sas.AccessSAS -DestinationContainer $ContainerName -DestinationBlob $osdisk.name -DestinationContext $storageContext
  
  $osdisk = get-azdisk -ResourceGroupName $vm.ResourceGroupName -name $vm.StorageProfile.$datadisks
  Foreach ($disk in $datadisks)
  {
    $sas = Grant-AzDiskAccess -ResourceGroupName $vm.ResourceGroupName -DiskName $disk.name -Access Read -DurationInSecond (60*60*24)
    Start-AzStorageBlobCopy -AbsoluteUri $sas.AccessSAS -DestinationContainer $ContainerName -DestinationBlob $disk.name -DestinationContext $storageContext
  }

}

