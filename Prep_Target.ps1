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
    $migvmname
    
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

New-AzResourceGroup -Name $rgname -Location $location

If ($migvmname)
{
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
}

# Create Storage account
$saname = "mig" + (new-guid).ToString().replace("-","").substring(0,16)
New-AzStorageAccount -ResourceGroupName $rgname `
  -Name $saname `
  -Location $location `
  -SkuName Standard_RAGRS `
  -Kind StorageV2

Write-host "Storage account created: " $saname -ForegroundColor Green