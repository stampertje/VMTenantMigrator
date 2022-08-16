[CmdletBinding()]
param (
    # location for migrator VM
    [Parameter(Mandatory=$true)]
    [string]
    $location = "westeurope",

    # domain name or guid for target tenant
    [Parameter(Mandatory=$true)]
    [string]
    $TargetTenant = "fdpo.onmicrosoft.com",

    # guid of the target subscription. If not specified will search. end script if > 1 found.
    [Parameter()]
    [string]
    $targetsubscription,

    # name of rg for migrator vm
    [Parameter()]
    [string]
    $rgname = "migrator",

    # Name of the migrator vm
    [Parameter()]
    [string]
    $migvmname = "migratorvm"
    
)


# Connect target tenant and select subscription
Login-AzAccount -Tenant $TargetTenant

If (-not($targetsubscription))
{
  $targetsubscription = Get-azsubscription -TenantId $TargetTenant
  if ($targetsubscription.count -gt 1){Write-Error -Message "More than 1 subscription. quiting." -ErrorAction Stop}
  Select-AzSubscription -SubscriptionId $targetsubscription.id
} else {
  Select-AzSubscription -SubscriptionId $targetsubscription
}

New-AzResourceGroup -Name $rgname -Location $location

# Create Migrator VM
New-AzVm `
    -ResourceGroupName $rgname `
    -Name $migvmname `
    -Location $location `
    -size "Standard_D2_v5" `
    -VirtualNetworkName 'migvnet' `
    -SubnetName 'migsubnet' `
    -SecurityGroupName 'mignsg' `
    -PublicIpAddressName 'migpip' `
    -OpenPorts 3389

# Create Storage account
$saname = "mig" + (new-guid).ToString().replace("-","").substring(0,16)
New-AzStorageAccount -ResourceGroupName $rgname `
  -Name $saname `
  -Location $location `
  -SkuName Standard_RAGRS `
  -Kind StorageV2

Write-host "Storage account created: " $saname -ForegroundColor Green