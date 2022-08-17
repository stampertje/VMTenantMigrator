#Requires -module Az.Compute, Az.Accounts, Az.Storage, Az.Resources
# Stole code from here https://www.whatsupgold.com/blog/how-to-rename-an-azure-vm-using-powershell-a-step-by-step-guide

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
    [Parameter(Mandatory=$false)]
    [string]
    $TargetStorageAccountName,

    # Connectionstring for target storage account
    [Parameter(Mandatory=$false)]
    [string]
    $ConnectionString,

    # If name is specified only single VM will be migrated. Expecting the VMName
    [Parameter()]
    [string]
    $MigrateSingleVM,

    # Defines if automation credentials should be used or 
    [Parameter()]
    [boolean]
    $InAutomationAccount=$false
)

if (!(test-path $tempdir)){mkdir $tempdir}

if ((get-azcontext).subscription.id -ne $SourceSubscription)
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
      $response = Read-Host -message "Continue as " (get-azcontext).account " Y/N"
      If ($response -ieq "n")
      {
        Login-AzAccount -Tenant $SourceTenant
      }
    }
  }

  Select-AzSubscription -SubscriptionId $SourceSubscription
}

#connect to storage account
#$storageContext = New-AzStorageContext -StorageAccountName $TargetStorageAccountName -SasToken $TargetStorageAccountSAS
if($connectionstring){$storageContext = New-AzStorageContext -ConnectionString $ConnectionString}
if($UseCurrentAccount){$StorageContext = New-AzStorageContext -StorageAccountName $TargetStorageAccountName -UseConnectedAccount}
$ContainerName = "vmbackup"
New-AzStorageContainer -Name $ContainerName -Context $storageContext -Permission Blob -ErrorAction SilentlyContinue

if ($MigrateSingleVM)
{
  $VMtoMigrate = Get-AzVm -name $MigrateSingleVM
} else {
  $VMtoMigrate = Get-AzVm
}

Foreach ($vm in $VMtoMigrate)
{
  $vmname = $vm.Name
  Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vmName | Export-Clixml $tempdir\$vmname.xml -Depth 5

  # Get disk config
  $vmosdisk = $vmname + '_disks' # Name of the XML file
  Get-AzDisk -ResourceGroupName $vm.ResourceGroupName | Where-Object {$_.name -like "*$vmname*"} | Export-Clixml $tempdir\$vmosdisk.xml -Depth 5

  # Get NIC Config
  $vmnic = $vmname + '_nic' # Name of the XML file
  $vmnicName = $vm.networkprofile.NetworkInterfaces.id.split("/")[$vm.networkprofile.NetworkInterfaces.id.split("/").length-1]
  Get-AzNetworkInterface -ResourceGroupName $vm.ResourceGroupName -Name $vmnicName | Export-Clixml $tempdir\$vmnic.xml -Depth 5

  $fileArray = $vmname,$vmosdisk,$vmnic
  Foreach ($file in $fileArray)
  {
    # copy xml to storage account
    Set-AzStorageBlobContent `
      -Context $storageContext `
      -Container $ContainerName `
      -File $tempdir\$file.xml `
      -Blob $file.xml `
      -force
  }

  # shutdown vm if running
  $vmstatus = $vm.status
  if($vmstatus -ieq "Running")
  {
    Stop-AzVM -name $vm.name -ResourceGroupName $vm.ResourceGroupName -Force
  }

  # clone disk to storage account
  $osdisk = get-azdisk -ResourceGroupName $vm.ResourceGroupName -name $vm.StorageProfile.osdisk.name
  $sas = Grant-AzDiskAccess -ResourceGroupName $vm.ResourceGroupName -DiskName $osdisk.name -Access Read -DurationInSecond (60*60*24)
  Start-AzStorageBlobCopy -AbsoluteUri $sas.AccessSAS -DestinationContainer $ContainerName -DestinationBlob $osdisk.name -DestinationContext $storageContext
  
  $datadisks = get-azdisk -ResourceGroupName $vm.ResourceGroupName -name $vm.StorageProfile.$datadisks
  Foreach ($disk in $datadisks)
  {
    $sas = Grant-AzDiskAccess -ResourceGroupName $vm.ResourceGroupName -DiskName $disk.name -Access Read -DurationInSecond (60*60*24)
    Start-AzStorageBlobCopy -AbsoluteUri $sas.AccessSAS -DestinationContainer $ContainerName -DestinationBlob $disk.name -DestinationContext $storageContext
  }

  If ($vmstatus -ieq "Running")
  {
    Start-AzVm -Name $vm.name -ResourceGroupName $vm.ResourceGroupName
  }
}

