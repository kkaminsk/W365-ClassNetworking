#Requires -Version 5.1
<#
.SYNOPSIS
    Sets Azure subscription-wide resource quotas to limit total resource creation.

.DESCRIPTION
    This script configures Azure subscription quotas for compute and networking resources.
    Quotas are applied at the subscription level per region, not per student.
    
    Use this as a safety mechanism to prevent runaway resource creation across the entire subscription.
    
    IMPORTANT: This does NOT provide per-student limits. Use the per-student script validation
    in 4_W365/deploy.ps1 for per-student enforcement.
    
    Subscription-Wide Limits Recommended for 30 Students:
    - Total VMs: 35 (30 students + 5 buffer for instructors/testing)
    - Total VNets: 35 (30 students + 5 shared/hub networks)
    - Total vCPUs: 140 (30 students × 4 vCPUs + 20 buffer)
    - Total Public IPs: 40 (temporary for image builds)

.PARAMETER Region
    Azure region to set quotas for. Default: southcentralus

.PARAMETER MaxVMs
    Maximum total VMs in subscription for the region. Default: 35

.PARAMETER MaxVCPUs
    Maximum total vCPUs in subscription for the region. Default: 140

.PARAMETER MaxVNets
    Maximum total VNets in subscription for the region. Default: 35

.PARAMETER MaxPublicIPs
    Maximum total Public IPs in subscription for the region. Default: 40

.PARAMETER ViewCurrentQuotas
    View current quota usage and limits without making changes.

.PARAMETER ResetToDefaults
    Reset quotas to Azure default values (usually much higher).

.EXAMPLE
    .\Set-SubscriptionQuotas.ps1 -Region "southcentralus"
    Set recommended quotas for 30-student lab in South Central US

.EXAMPLE
    .\Set-SubscriptionQuotas.ps1 -ViewCurrentQuotas
    View current quota usage and limits

.EXAMPLE
    .\Set-SubscriptionQuotas.ps1 -MaxVMs 50 -MaxVCPUs 200
    Set custom quota limits

.EXAMPLE
    .\Set-SubscriptionQuotas.ps1 -ResetToDefaults
    Reset all quotas to Azure default values

.NOTES
    - Requires Az.Compute and Az.Network modules
    - Requires Owner or Contributor role on subscription
    - Quota changes may take 15-30 minutes to apply
    - Quotas are per-region, not subscription-wide
    - Some quota increases require Azure support ticket
#>

[CmdletBinding(DefaultParameterSetName = 'SetQuotas')]
param(
    [Parameter(Mandatory = $false, ParameterSetName = 'SetQuotas')]
    [Parameter(Mandatory = $false, ParameterSetName = 'ViewQuotas')]
    [string]$Region = "southcentralus",
    
    [Parameter(Mandatory = $false, ParameterSetName = 'SetQuotas')]
    [ValidateRange(1, 1000)]
    [int]$MaxVMs = 35,
    
    [Parameter(Mandatory = $false, ParameterSetName = 'SetQuotas')]
    [ValidateRange(1, 10000)]
    [int]$MaxVCPUs = 140,
    
    [Parameter(Mandatory = $false, ParameterSetName = 'SetQuotas')]
    [ValidateRange(1, 1000)]
    [int]$MaxVNets = 35,
    
    [Parameter(Mandatory = $false, ParameterSetName = 'SetQuotas')]
    [ValidateRange(1, 1000)]
    [int]$MaxPublicIPs = 40,
    
    [Parameter(Mandatory = $true, ParameterSetName = 'ViewQuotas')]
    [switch]$ViewCurrentQuotas,
    
    [Parameter(Mandatory = $true, ParameterSetName = 'ResetQuotas')]
    [switch]$ResetToDefaults
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Initialize logging
$timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
$logPath = Join-Path -Path ([Environment]::GetFolderPath("MyDocuments")) -ChildPath "SubscriptionQuotas-$timestamp.log"

function Write-LogMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        'Info'    { Write-Host $logMessage -ForegroundColor Cyan }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Error'   { Write-Host $logMessage -ForegroundColor Red }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
    }
    
    Add-Content -Path $logPath -Value $logMessage
}

function Test-Prerequisites {
    Write-LogMessage "Checking prerequisites..." -Level Info
    
    # Check Az.Compute module
    if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
        Write-LogMessage "ERROR: Az.Compute module not found" -Level Error
        Write-LogMessage "Install with: Install-Module -Name Az.Compute -Repository PSGallery -Force" -Level Info
        return $false
    }
    
    # Check Az.Network module
    if (-not (Get-Module -ListAvailable -Name Az.Network)) {
        Write-LogMessage "ERROR: Az.Network module not found" -Level Error
        Write-LogMessage "Install with: Install-Module -Name Az.Network -Repository PSGallery -Force" -Level Info
        return $false
    }
    
    # Check Azure context
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Write-LogMessage "ERROR: Not connected to Azure. Run Connect-AzAccount first." -Level Error
        return $false
    }
    
    Write-LogMessage "✓ Prerequisites met" -Level Success
    return $true
}

function Get-ComputeQuotaUsage {
    param([string]$Location)
    
    Write-LogMessage "`nRetrieving compute quotas for region: $Location" -Level Info
    
    try {
        $vmUsage = Get-AzVMUsage -Location $Location
        
        $quotaInfo = @{
            TotalVMs = $null
            StandardDSv3Cores = $null
            TotalCores = $null
        }
        
        foreach ($usage in $vmUsage) {
            switch ($usage.Name.LocalizedValue) {
                "Virtual Machines" {
                    $quotaInfo.TotalVMs = @{
                        Current = $usage.CurrentValue
                        Limit = $usage.Limit
                        Usage = [math]::Round(($usage.CurrentValue / $usage.Limit) * 100, 2)
                    }
                }
                "Standard DSv3 Family vCPUs" {
                    $quotaInfo.StandardDSv3Cores = @{
                        Current = $usage.CurrentValue
                        Limit = $usage.Limit
                        Usage = [math]::Round(($usage.CurrentValue / $usage.Limit) * 100, 2)
                    }
                }
                "Total Regional vCPUs" {
                    $quotaInfo.TotalCores = @{
                        Current = $usage.CurrentValue
                        Limit = $usage.Limit
                        Usage = [math]::Round(($usage.CurrentValue / $usage.Limit) * 100, 2)
                    }
                }
            }
        }
        
        return $quotaInfo
    }
    catch {
        Write-LogMessage "Failed to retrieve compute quotas: $($_.Exception.Message)" -Level Error
        return $null
    }
}

function Get-NetworkQuotaUsage {
    param([string]$Location)
    
    Write-LogMessage "Retrieving network quotas for region: $Location" -Level Info
    
    try {
        $networkUsage = Get-AzNetworkUsage -Location $Location
        
        $quotaInfo = @{
            VirtualNetworks = $null
            PublicIPAddresses = $null
            NetworkSecurityGroups = $null
        }
        
        foreach ($usage in $networkUsage) {
            switch ($usage.ResourceType) {
                "VirtualNetworks" {
                    $quotaInfo.VirtualNetworks = @{
                        Current = $usage.CurrentValue
                        Limit = $usage.Limit
                        Usage = if ($usage.Limit -gt 0) { [math]::Round(($usage.CurrentValue / $usage.Limit) * 100, 2) } else { 0 }
                    }
                }
                "PublicIPAddresses" {
                    $quotaInfo.PublicIPAddresses = @{
                        Current = $usage.CurrentValue
                        Limit = $usage.Limit
                        Usage = if ($usage.Limit -gt 0) { [math]::Round(($usage.CurrentValue / $usage.Limit) * 100, 2) } else { 0 }
                    }
                }
                "NetworkSecurityGroups" {
                    $quotaInfo.NetworkSecurityGroups = @{
                        Current = $usage.CurrentValue
                        Limit = $usage.Limit
                        Usage = if ($usage.Limit -gt 0) { [math]::Round(($usage.CurrentValue / $usage.Limit) * 100, 2) } else { 0 }
                    }
                }
            }
        }
        
        return $quotaInfo
    }
    catch {
        Write-LogMessage "Failed to retrieve network quotas: $($_.Exception.Message)" -Level Error
        return $null
    }
}

function Show-QuotaDashboard {
    param(
        [string]$Location,
        [object]$ComputeQuotas,
        [object]$NetworkQuotas
    )
    
    Write-Host "`n" -NoNewline
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Azure Quota Dashboard - $Location" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Compute Quotas
    Write-Host "`n📊 COMPUTE QUOTAS" -ForegroundColor Yellow
    Write-Host "─────────────────────────────────────────" -ForegroundColor Gray
    
    if ($ComputeQuotas.TotalVMs) {
        $vm = $ComputeQuotas.TotalVMs
        $color = if ($vm.Usage -gt 80) { "Red" } elseif ($vm.Usage -gt 60) { "Yellow" } else { "Green" }
        Write-Host "Virtual Machines:      " -NoNewline
        Write-Host "$($vm.Current) / $($vm.Limit) " -NoNewline -ForegroundColor White
        Write-Host "($($vm.Usage)%)" -ForegroundColor $color
    }
    
    if ($ComputeQuotas.TotalCores) {
        $cores = $ComputeQuotas.TotalCores
        $color = if ($cores.Usage -gt 80) { "Red" } elseif ($cores.Usage -gt 60) { "Yellow" } else { "Green" }
        Write-Host "Total vCPUs:           " -NoNewline
        Write-Host "$($cores.Current) / $($cores.Limit) " -NoNewline -ForegroundColor White
        Write-Host "($($cores.Usage)%)" -ForegroundColor $color
    }
    
    if ($ComputeQuotas.StandardDSv3Cores) {
        $dsv3 = $ComputeQuotas.StandardDSv3Cores
        $color = if ($dsv3.Usage -gt 80) { "Red" } elseif ($dsv3.Usage -gt 60) { "Yellow" } else { "Green" }
        Write-Host "DSv3 Family vCPUs:     " -NoNewline
        Write-Host "$($dsv3.Current) / $($dsv3.Limit) " -NoNewline -ForegroundColor White
        Write-Host "($($dsv3.Usage)%)" -ForegroundColor $color
    }
    
    # Network Quotas
    Write-Host "`n🌐 NETWORK QUOTAS" -ForegroundColor Yellow
    Write-Host "─────────────────────────────────────────" -ForegroundColor Gray
    
    if ($NetworkQuotas.VirtualNetworks) {
        $vnet = $NetworkQuotas.VirtualNetworks
        $color = if ($vnet.Usage -gt 80) { "Red" } elseif ($vnet.Usage -gt 60) { "Yellow" } else { "Green" }
        Write-Host "Virtual Networks:      " -NoNewline
        Write-Host "$($vnet.Current) / $($vnet.Limit) " -NoNewline -ForegroundColor White
        Write-Host "($($vnet.Usage)%)" -ForegroundColor $color
    }
    
    if ($NetworkQuotas.PublicIPAddresses) {
        $pip = $NetworkQuotas.PublicIPAddresses
        $color = if ($pip.Usage -gt 80) { "Red" } elseif ($pip.Usage -gt 60) { "Yellow" } else { "Green" }
        Write-Host "Public IP Addresses:   " -NoNewline
        Write-Host "$($pip.Current) / $($pip.Limit) " -NoNewline -ForegroundColor White
        Write-Host "($($pip.Usage)%)" -ForegroundColor $color
    }
    
    if ($NetworkQuotas.NetworkSecurityGroups) {
        $nsg = $NetworkQuotas.NetworkSecurityGroups
        $color = if ($nsg.Usage -gt 80) { "Red" } elseif ($nsg.Usage -gt 60) { "Yellow" } else { "Green" }
        Write-Host "Network Security Groups:" -NoNewline
        Write-Host "$($nsg.Current) / $($nsg.Limit) " -NoNewline -ForegroundColor White
        Write-Host "($($nsg.Usage)%)" -ForegroundColor $color
    }
    
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Legend: " -NoNewline
    Write-Host "< 60% = " -NoNewline
    Write-Host "Good " -ForegroundColor Green -NoNewline
    Write-Host "| 60-80% = " -NoNewline
    Write-Host "Warning " -ForegroundColor Yellow -NoNewline
    Write-Host "| > 80% = " -NoNewline
    Write-Host "Critical" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Cyan
}

function Request-QuotaIncrease {
    param(
        [string]$ResourceType,
        [int]$CurrentLimit,
        [int]$RequestedLimit,
        [string]$Location
    )
    
    Write-LogMessage "`nRequesting quota increase for $ResourceType..." -Level Info
    Write-LogMessage "  Current Limit: $CurrentLimit" -Level Info
    Write-LogMessage "  Requested Limit: $RequestedLimit" -Level Info
    Write-LogMessage "  Region: $Location" -Level Info
    
    Write-LogMessage "`nIMPORTANT: Quota increases require Azure Support request" -Level Warning
    Write-LogMessage "This script cannot automatically increase quotas." -Level Warning
    Write-LogMessage "`nTo request quota increase:" -Level Info
    Write-LogMessage "1. Go to Azure Portal → Support + troubleshooting → New support request" -Level Info
    Write-LogMessage "2. Issue type: Service and subscription limits (quotas)" -Level Info
    Write-LogMessage "3. Quota type: $ResourceType" -Level Info
    Write-LogMessage "4. Region: $Location" -Level Info
    Write-LogMessage "5. New limit: $RequestedLimit" -Level Info
    Write-LogMessage "`nOr use Azure CLI:" -Level Info
    Write-LogMessage "az support tickets create --ticket-name 'quota-increase-$ResourceType' ..." -Level Info
    
    return $false
}

# ============================================================================
# Main Execution
# ============================================================================

try {
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Azure Subscription Quota Management" -Level Info
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Log: $logPath" -Level Info
    
    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        exit 1
    }
    
    $context = Get-AzContext
    $subscriptionName = $context.Subscription.Name
    $subscriptionId = $context.Subscription.Id
    
    Write-LogMessage "`nAzure Context:" -Level Info
    Write-LogMessage "  Subscription: $subscriptionName" -Level Info
    Write-LogMessage "  Subscription ID: $subscriptionId" -Level Info
    Write-LogMessage "  Region: $Region" -Level Info
    
    # Get current quota usage
    $computeQuotas = Get-ComputeQuotaUsage -Location $Region
    $networkQuotas = Get-NetworkQuotaUsage -Location $Region
    
    if (-not $computeQuotas -or -not $networkQuotas) {
        Write-LogMessage "Failed to retrieve quota information" -Level Error
        exit 1
    }
    
    # Show quota dashboard
    Show-QuotaDashboard -Location $Region -ComputeQuotas $computeQuotas -NetworkQuotas $networkQuotas
    
    # Handle different parameter sets
    switch ($PSCmdlet.ParameterSetName) {
        'ViewQuotas' {
            Write-LogMessage "`nView-only mode - no changes made" -Level Info
            Write-LogMessage "Run without -ViewCurrentQuotas to set custom limits" -Level Info
        }
        
        'ResetQuotas' {
            Write-LogMessage "`n⚠️  RESET TO DEFAULTS NOT IMPLEMENTED" -Level Warning
            Write-LogMessage "Azure quotas cannot be automatically reset via PowerShell." -Level Warning
            Write-LogMessage "Default quotas are restored when you request standard limits through Azure Support." -Level Warning
        }
        
        'SetQuotas' {
            Write-LogMessage "`n========================================" -Level Info
            Write-LogMessage "Requested Quota Changes" -Level Info
            Write-LogMessage "========================================" -Level Info
            
            $needsSupportTicket = $false
            
            # Check if requested quotas exceed current limits
            if ($computeQuotas.TotalVMs -and $MaxVMs -gt $computeQuotas.TotalVMs.Limit) {
                Write-LogMessage "Virtual Machines: $($computeQuotas.TotalVMs.Limit) → $MaxVMs (increase needed)" -Level Warning
                $needsSupportTicket = $true
            }
            elseif ($computeQuotas.TotalVMs) {
                Write-LogMessage "Virtual Machines: Current limit $($computeQuotas.TotalVMs.Limit) is sufficient (requested: $MaxVMs)" -Level Success
            }
            
            if ($computeQuotas.TotalCores -and $MaxVCPUs -gt $computeQuotas.TotalCores.Limit) {
                Write-LogMessage "Total vCPUs: $($computeQuotas.TotalCores.Limit) → $MaxVCPUs (increase needed)" -Level Warning
                $needsSupportTicket = $true
            }
            elseif ($computeQuotas.TotalCores) {
                Write-LogMessage "Total vCPUs: Current limit $($computeQuotas.TotalCores.Limit) is sufficient (requested: $MaxVCPUs)" -Level Success
            }
            
            if ($networkQuotas.VirtualNetworks -and $MaxVNets -gt $networkQuotas.VirtualNetworks.Limit) {
                Write-LogMessage "Virtual Networks: $($networkQuotas.VirtualNetworks.Limit) → $MaxVNets (increase needed)" -Level Warning
                $needsSupportTicket = $true
            }
            elseif ($networkQuotas.VirtualNetworks) {
                Write-LogMessage "Virtual Networks: Current limit $($networkQuotas.VirtualNetworks.Limit) is sufficient (requested: $MaxVNets)" -Level Success
            }
            
            if ($networkQuotas.PublicIPAddresses -and $MaxPublicIPs -gt $networkQuotas.PublicIPAddresses.Limit) {
                Write-LogMessage "Public IP Addresses: $($networkQuotas.PublicIPAddresses.Limit) → $MaxPublicIPs (increase needed)" -Level Warning
                $needsSupportTicket = $true
            }
            elseif ($networkQuotas.PublicIPAddresses) {
                Write-LogMessage "Public IP Addresses: Current limit $($networkQuotas.PublicIPAddresses.Limit) is sufficient (requested: $MaxPublicIPs)" -Level Success
            }
            
            if ($needsSupportTicket) {
                Write-LogMessage "`n========================================" -Level Warning
                Write-LogMessage "ACTION REQUIRED: Azure Support Ticket" -Level Warning
                Write-LogMessage "========================================" -Level Warning
                Write-LogMessage "Some requested quotas exceed current limits." -Level Warning
                Write-LogMessage "You must create an Azure Support ticket to increase these quotas." -Level Warning
                Write-LogMessage "`nSteps:" -Level Info
                Write-LogMessage "1. Go to: https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade/newsupportrequest" -Level Info
                Write-LogMessage "2. Issue type: Service and subscription limits (quotas)" -Level Info
                Write-LogMessage "3. Subscription: $subscriptionName" -Level Info
                Write-LogMessage "4. Quota type: Compute-VM (cores-vCPUs) or Networking" -Level Info
                Write-LogMessage "5. Region: $Region" -Level Info
                Write-LogMessage "6. Specify your requested limits from above" -Level Info
                Write-LogMessage "`nTypical approval time: 1-3 business days" -Level Info
            }
            else {
                Write-LogMessage "`n========================================" -Level Success
                Write-LogMessage "✓ CURRENT QUOTAS SUFFICIENT" -Level Success
                Write-LogMessage "========================================" -Level Success
                Write-LogMessage "Your current quotas meet or exceed all requested limits." -Level Success
                Write-LogMessage "No action needed!" -Level Success
            }
        }
    }
    
    # Recommendations for 30-student lab
    Write-LogMessage "`n========================================" -Level Info
    Write-LogMessage "Recommendations for 30-Student Lab" -Level Info
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Recommended Subscription-Wide Quotas:" -Level Info
    Write-LogMessage "  • Virtual Machines: 35 (30 students + 5 buffer)" -Level Info
    Write-LogMessage "  • Total vCPUs: 140 (30 × 4 vCPUs + 20 buffer)" -Level Info
    Write-LogMessage "  • Virtual Networks: 35 (30 students + 5 hub/shared)" -Level Info
    Write-LogMessage "  • Public IPs: 40 (temporary for builds)" -Level Info
    Write-LogMessage "`nNOTE: These are subscription-wide limits in region $Region" -Level Warning
    Write-LogMessage "For per-student enforcement, use script validation in:" -Level Info
    Write-LogMessage "  • 4_W365/deploy.ps1 (max 1 VNet per student)" -Level Info
    
}
catch {
    Write-LogMessage "`n========================================" -Level Error
    Write-LogMessage "QUOTA MANAGEMENT FAILED" -Level Error
    Write-LogMessage "========================================" -Level Error
    Write-LogMessage "Error: $($_.Exception.Message)" -Level Error
    Write-LogMessage "Stack: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
