#Requires -Version 5.1
<#
.SYNOPSIS
    Checks and displays Azure subscription quota usage and limits.

.DESCRIPTION
    This read-only script retrieves and displays current quota usage across multiple 
    Azure resource types including compute, network, and storage resources.
    
    Provides comprehensive visibility into:
    - Virtual Machine quotas (VMs, vCPUs, cores)
    - Network quotas (VNets, Public IPs, NSGs, Subnets)
    - Storage account quotas
    - Resource group quotas
    
    Helps identify quota bottlenecks before deployments and monitors usage trends.

.PARAMETER Region
    Azure region to check quotas for. Default: southcentralus

.PARAMETER ExportCsv
    Export quota data to CSV file

.PARAMETER ExportJson
    Export quota data to JSON file

.PARAMETER OutputPath
    Custom output path for exported files. Default: MyDocuments

.PARAMETER ShowAllRegions
    Check quotas across all Azure regions (slower)

.PARAMETER Detailed
    Show detailed quota breakdown including all VM families

.EXAMPLE
    .\Get-SubscriptionQuotas.ps1
    View quota dashboard for default region (southcentralus)

.EXAMPLE
    .\Get-SubscriptionQuotas.ps1 -Region "eastus" -Detailed
    View detailed quota information for East US region

.EXAMPLE
    .\Get-SubscriptionQuotas.ps1 -ExportCsv -OutputPath "C:\Reports"
    Export quota data to CSV in custom location

.EXAMPLE
    .\Get-SubscriptionQuotas.ps1 -ShowAllRegions -ExportJson
    Check quotas across all regions and export to JSON

.NOTES
    - Requires Az.Compute, Az.Network, and Az.Storage modules
    - Requires Reader role or higher on subscription
    - Read-only operation - makes no changes
    - Safe to run frequently for monitoring
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Region = "southcentralus",
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportCsv,
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportJson,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ([Environment]::GetFolderPath("MyDocuments")),
    
    [Parameter(Mandatory = $false)]
    [switch]$ShowAllRegions,
    
    [Parameter(Mandatory = $false)]
    [switch]$Detailed
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Initialize
$timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
$logPath = Join-Path -Path $OutputPath -ChildPath "QuotaCheck-$timestamp.log"
$quotaData = @()

# ============================================================================
# Helper Functions
# ============================================================================

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
    
    Add-Content -Path $logPath -Value $logMessage -ErrorAction SilentlyContinue
}

function Test-Prerequisites {
    Write-LogMessage "Checking prerequisites..." -Level Info
    
    $required = @('Az.Compute', 'Az.Network', 'Az.Storage', 'Az.Resources')
    $missing = @()
    
    foreach ($module in $required) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            $missing += $module
        }
    }
    
    if ($missing.Count -gt 0) {
        Write-LogMessage "Missing required modules: $($missing -join ', ')" -Level Error
        Write-LogMessage "Install with: Install-Module -Name $($missing -join ',') -Repository PSGallery -Force" -Level Info
        return $false
    }
    
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Write-LogMessage "Not connected to Azure. Run Connect-AzAccount first." -Level Error
        return $false
    }
    
    Write-LogMessage "✓ Prerequisites met" -Level Success
    return $true
}

function Get-UsageColor {
    param([double]$UsagePercent)
    
    if ($UsagePercent -ge 90) { return "Red" }
    elseif ($UsagePercent -ge 80) { return "DarkYellow" }
    elseif ($UsagePercent -ge 60) { return "Yellow" }
    else { return "Green" }
}

function Get-UsageIndicator {
    param([double]$UsagePercent)
    
    if ($UsagePercent -ge 90) { return "🔴" }
    elseif ($UsagePercent -ge 80) { return "🟠" }
    elseif ($UsagePercent -ge 60) { return "🟡" }
    else { return "🟢" }
}

function Format-QuotaBar {
    param(
        [int]$Current,
        [int]$Limit,
        [int]$BarWidth = 20
    )
    
    if ($Limit -eq 0) { return "[$('─' * $BarWidth)]" }
    
    $usagePercent = ($Current / $Limit) * 100
    $filled = [math]::Floor(($Current / $Limit) * $BarWidth)
    $empty = $BarWidth - $filled
    
    $bar = "[$('█' * $filled)$('─' * $empty)]"
    return $bar
}

# ============================================================================
# Quota Retrieval Functions
# ============================================================================

function Get-ComputeQuotas {
    param([string]$Location)
    
    Write-LogMessage "Retrieving compute quotas for $Location..." -Level Info
    
    try {
        $vmUsage = Get-AzVMUsage -Location $Location
        $computeQuotas = @()
        
        foreach ($usage in $vmUsage) {
            if ($usage.Limit -eq -1) { continue }  # Skip unlimited quotas
            
            $usagePercent = if ($usage.Limit -gt 0) { 
                [math]::Round(($usage.CurrentValue / $usage.Limit) * 100, 2) 
            } else { 0 }
            
            $quota = [PSCustomObject]@{
                Category = "Compute"
                ResourceType = $usage.Name.LocalizedValue
                Current = $usage.CurrentValue
                Limit = $usage.Limit
                Available = $usage.Limit - $usage.CurrentValue
                UsagePercent = $usagePercent
                Status = if ($usagePercent -ge 90) { "Critical" } 
                        elseif ($usagePercent -ge 80) { "Warning" }
                        elseif ($usagePercent -ge 60) { "Moderate" }
                        else { "Good" }
                Region = $Location
                Unit = $usage.Unit
            }
            
            $computeQuotas += $quota
        }
        
        return $computeQuotas
    }
    catch {
        Write-LogMessage "Failed to retrieve compute quotas: $($_.Exception.Message)" -Level Error
        return @()
    }
}

function Get-NetworkQuotas {
    param([string]$Location)
    
    Write-LogMessage "Retrieving network quotas for $Location..." -Level Info
    
    try {
        $networkUsage = Get-AzNetworkUsage -Location $Location
        $networkQuotas = @()
        
        foreach ($usage in $networkUsage) {
            if ($usage.Limit -eq -1) { continue }
            
            $usagePercent = if ($usage.Limit -gt 0) { 
                [math]::Round(($usage.CurrentValue / $usage.Limit) * 100, 2) 
            } else { 0 }
            
            $quota = [PSCustomObject]@{
                Category = "Network"
                ResourceType = $usage.ResourceType
                Current = $usage.CurrentValue
                Limit = $usage.Limit
                Available = $usage.Limit - $usage.CurrentValue
                UsagePercent = $usagePercent
                Status = if ($usagePercent -ge 90) { "Critical" } 
                        elseif ($usagePercent -ge 80) { "Warning" }
                        elseif ($usagePercent -ge 60) { "Moderate" }
                        else { "Good" }
                Region = $Location
                Unit = "Count"
            }
            
            $networkQuotas += $quota
        }
        
        return $networkQuotas
    }
    catch {
        Write-LogMessage "Failed to retrieve network quotas: $($_.Exception.Message)" -Level Error
        return @()
    }
}

function Get-StorageQuotas {
    param([string]$Location)
    
    Write-LogMessage "Retrieving storage quotas for $Location..." -Level Info
    
    try {
        $storageUsage = Get-AzStorageUsage -Location $Location
        $storageQuotas = @()
        
        foreach ($usage in $storageUsage) {
            if ($usage.Limit -eq -1) { continue }
            
            $usagePercent = if ($usage.Limit -gt 0) { 
                [math]::Round(($usage.CurrentValue / $usage.Limit) * 100, 2) 
            } else { 0 }
            
            $quota = [PSCustomObject]@{
                Category = "Storage"
                ResourceType = $usage.Name.LocalizedValue
                Current = $usage.CurrentValue
                Limit = $usage.Limit
                Available = $usage.Limit - $usage.CurrentValue
                UsagePercent = $usagePercent
                Status = if ($usagePercent -ge 90) { "Critical" } 
                        elseif ($usagePercent -ge 80) { "Warning" }
                        elseif ($usagePercent -ge 60) { "Moderate" }
                        else { "Good" }
                Region = $Location
                Unit = $usage.Unit
            }
            
            $storageQuotas += $quota
        }
        
        return $storageQuotas
    }
    catch {
        Write-LogMessage "Failed to retrieve storage quotas: $($_.Exception.Message)" -Level Error
        return @()
    }
}

function Get-SubscriptionLevelQuotas {
    Write-LogMessage "Retrieving subscription-level quotas..." -Level Info
    
    try {
        $subQuotas = @()
        $context = Get-AzContext
        
        # Resource Groups
        $rgs = Get-AzResourceGroup
        $rgLimit = 980  # Azure default
        $rgUsagePercent = [math]::Round(($rgs.Count / $rgLimit) * 100, 2)
        
        $subQuotas += [PSCustomObject]@{
            Category = "Subscription"
            ResourceType = "Resource Groups"
            Current = $rgs.Count
            Limit = $rgLimit
            Available = $rgLimit - $rgs.Count
            UsagePercent = $rgUsagePercent
            Status = if ($rgUsagePercent -ge 90) { "Critical" } 
                    elseif ($rgUsagePercent -ge 80) { "Warning" }
                    elseif ($rgUsagePercent -ge 60) { "Moderate" }
                    else { "Good" }
            Region = "Subscription-Wide"
            Unit = "Count"
        }
        
        return $subQuotas
    }
    catch {
        Write-LogMessage "Failed to retrieve subscription quotas: $($_.Exception.Message)" -Level Error
        return @()
    }
}

# ============================================================================
# Display Functions
# ============================================================================

function Show-QuotaSummary {
    param(
        [array]$AllQuotas,
        [string]$Location
    )
    
    Write-Host "`n╔════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║           AZURE SUBSCRIPTION QUOTA REPORT                          ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    
    $context = Get-AzContext
    Write-Host "`n📋 Subscription: " -NoNewline -ForegroundColor White
    Write-Host $context.Subscription.Name -ForegroundColor Yellow
    Write-Host "🆔 Subscription ID: " -NoNewline -ForegroundColor White
    Write-Host $context.Subscription.Id -ForegroundColor Gray
    Write-Host "📍 Region: " -NoNewline -ForegroundColor White
    Write-Host $Location -ForegroundColor Yellow
    Write-Host "🕐 Timestamp: " -NoNewline -ForegroundColor White
    Write-Host (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -ForegroundColor Gray
    
    # Key metrics
    $criticalCount = ($AllQuotas | Where-Object { $_.Status -eq "Critical" }).Count
    $warningCount = ($AllQuotas | Where-Object { $_.Status -eq "Warning" }).Count
    $moderateCount = ($AllQuotas | Where-Object { $_.Status -eq "Moderate" }).Count
    $goodCount = ($AllQuotas | Where-Object { $_.Status -eq "Good" }).Count
    
    Write-Host "`n📊 Status Summary:" -ForegroundColor White
    Write-Host "   🔴 Critical (≥90%): " -NoNewline
    Write-Host $criticalCount -ForegroundColor $(if ($criticalCount -gt 0) { "Red" } else { "Gray" })
    Write-Host "   🟠 Warning (80-89%): " -NoNewline
    Write-Host $warningCount -ForegroundColor $(if ($warningCount -gt 0) { "DarkYellow" } else { "Gray" })
    Write-Host "   🟡 Moderate (60-79%): " -NoNewline
    Write-Host $moderateCount -ForegroundColor $(if ($moderateCount -gt 0) { "Yellow" } else { "Gray" })
    Write-Host "   🟢 Good (<60%): " -NoNewline
    Write-Host $goodCount -ForegroundColor Green
    
    # Category breakdown
    $categories = $AllQuotas | Group-Object -Property Category
    
    foreach ($category in $categories) {
        Write-Host "`n═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        
        switch ($category.Name) {
            "Compute" { 
                Write-Host "💻 COMPUTE RESOURCES" -ForegroundColor Cyan 
                $importantTypes = @("Virtual Machines", "Total Regional vCPUs", "Standard DSv3 Family vCPUs")
            }
            "Network" { 
                Write-Host "🌐 NETWORK RESOURCES" -ForegroundColor Cyan 
                $importantTypes = @("VirtualNetworks", "PublicIPAddresses", "NetworkSecurityGroups", "NetworkInterfaces")
            }
            "Storage" { 
                Write-Host "💾 STORAGE RESOURCES" -ForegroundColor Cyan 
                $importantTypes = @("Storage Accounts")
            }
            "Subscription" { 
                Write-Host "📦 SUBSCRIPTION RESOURCES" -ForegroundColor Cyan 
                $importantTypes = @("Resource Groups")
            }
        }
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        
        $quotas = if ($Detailed) { 
            $category.Group | Sort-Object -Property UsagePercent -Descending 
        } else {
            $category.Group | Where-Object { $importantTypes -contains $_.ResourceType } | Sort-Object -Property UsagePercent -Descending
        }
        
        foreach ($quota in $quotas) {
            $indicator = Get-UsageIndicator -UsagePercent $quota.UsagePercent
            $color = Get-UsageColor -UsagePercent $quota.UsagePercent
            $bar = Format-QuotaBar -Current $quota.Current -Limit $quota.Limit
            
            Write-Host "`n$indicator " -NoNewline
            Write-Host "$($quota.ResourceType)" -ForegroundColor White
            Write-Host "   Usage: " -NoNewline -ForegroundColor Gray
            Write-Host "$($quota.Current) / $($quota.Limit)" -NoNewline -ForegroundColor White
            Write-Host " ($($quota.UsagePercent)%)" -ForegroundColor $color
            Write-Host "   $bar" -ForegroundColor $color
            Write-Host "   Available: " -NoNewline -ForegroundColor Gray
            Write-Host "$($quota.Available) $($quota.Unit)" -ForegroundColor White
        }
    }
    
    Write-Host "`n═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
}

function Show-QuotaRecommendations {
    param([array]$AllQuotas)
    
    $critical = $AllQuotas | Where-Object { $_.Status -eq "Critical" }
    $warning = $AllQuotas | Where-Object { $_.Status -eq "Warning" }
    
    if ($critical.Count -gt 0 -or $warning.Count -gt 0) {
        Write-Host "`n⚠️  RECOMMENDATIONS" -ForegroundColor Yellow
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        
        if ($critical.Count -gt 0) {
            Write-Host "`n🔴 CRITICAL ACTIONS REQUIRED:" -ForegroundColor Red
            foreach ($quota in $critical) {
                Write-Host "   • $($quota.ResourceType): " -NoNewline -ForegroundColor White
                Write-Host "$($quota.Current)/$($quota.Limit) ($($quota.UsagePercent)%)" -ForegroundColor Red
                Write-Host "     → Request quota increase immediately" -ForegroundColor Yellow
            }
        }
        
        if ($warning.Count -gt 0) {
            Write-Host "`n🟠 WARNING - PLAN QUOTA INCREASES:" -ForegroundColor DarkYellow
            foreach ($quota in $warning) {
                Write-Host "   • $($quota.ResourceType): " -NoNewline -ForegroundColor White
                Write-Host "$($quota.Current)/$($quota.Limit) ($($quota.UsagePercent)%)" -ForegroundColor DarkYellow
                Write-Host "     → Consider requesting increase soon" -ForegroundColor Yellow
            }
        }
        
        Write-Host "`n💡 To request quota increases:" -ForegroundColor Cyan
        Write-Host "   1. Azure Portal → Help + support → New support request" -ForegroundColor Gray
        Write-Host "   2. Issue type: Service and subscription limits (quotas)" -ForegroundColor Gray
        Write-Host "   3. Select quota type and specify new limits" -ForegroundColor Gray
        Write-Host "   Or run: " -NoNewline -ForegroundColor Gray
        Write-Host ".\Set-SubscriptionQuotas.ps1 -Region $($AllQuotas[0].Region)" -ForegroundColor White
    }
    else {
        Write-Host "`n✅ All quotas are healthy!" -ForegroundColor Green
        Write-Host "   No immediate action required." -ForegroundColor Gray
    }
}

# ============================================================================
# Export Functions
# ============================================================================

function Export-QuotaData {
    param(
        [array]$AllQuotas,
        [string]$Format,
        [string]$OutputPath
    )
    
    $filename = "AzureQuotas-$timestamp.$Format"
    $filepath = Join-Path -Path $OutputPath -ChildPath $filename
    
    try {
        switch ($Format) {
            "csv" {
                $AllQuotas | Export-Csv -Path $filepath -NoTypeInformation
                Write-LogMessage "✓ Exported to CSV: $filepath" -Level Success
            }
            "json" {
                $AllQuotas | ConvertTo-Json -Depth 5 | Out-File -FilePath $filepath
                Write-LogMessage "✓ Exported to JSON: $filepath" -Level Success
            }
        }
        
        return $filepath
    }
    catch {
        Write-LogMessage "Failed to export data: $($_.Exception.Message)" -Level Error
        return $null
    }
}

# ============================================================================
# Main Execution
# ============================================================================

try {
    Write-Host "`n🚀 Starting Azure Quota Check..." -ForegroundColor Cyan
    Write-LogMessage "Log file: $logPath" -Level Info
    
    # Prerequisites
    if (-not (Test-Prerequisites)) {
        exit 1
    }
    
    # Determine regions to check
    $regionsToCheck = if ($ShowAllRegions) {
        Write-LogMessage "Retrieving all Azure regions..." -Level Info
        (Get-AzLocation | Where-Object { $_.RegionType -eq "Physical" }).Location
    } else {
        @($Region)
    }
    
    # Collect quota data
    foreach ($loc in $regionsToCheck) {
        Write-Host "`n📍 Checking region: $loc" -ForegroundColor Yellow
        
        $computeQuotas = Get-ComputeQuotas -Location $loc
        $networkQuotas = Get-NetworkQuotas -Location $loc
        $storageQuotas = Get-StorageQuotas -Location $loc
        
        $quotaData += $computeQuotas
        $quotaData += $networkQuotas
        $quotaData += $storageQuotas
    }
    
    # Add subscription-level quotas once
    $quotaData += Get-SubscriptionLevelQuotas
    
    # Display results
    if ($quotaData.Count -gt 0) {
        Show-QuotaSummary -AllQuotas $quotaData -Location $Region
        Show-QuotaRecommendations -AllQuotas $quotaData
        
        # Export if requested
        if ($ExportCsv) {
            Export-QuotaData -AllQuotas $quotaData -Format "csv" -OutputPath $OutputPath | Out-Null
        }
        
        if ($ExportJson) {
            Export-QuotaData -AllQuotas $quotaData -Format "json" -OutputPath $OutputPath | Out-Null
        }
    }
    else {
        Write-LogMessage "No quota data retrieved" -Level Warning
    }
    
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host "✅ Quota check complete!" -ForegroundColor Green
    Write-LogMessage "Quota check completed successfully" -Level Success
    
}
catch {
    Write-Host "`n" -NoNewline
    Write-LogMessage "═══════════════════════════════════════════════════════════════════" -Level Error
    Write-LogMessage "❌ QUOTA CHECK FAILED" -Level Error
    Write-LogMessage "Error: $($_.Exception.Message)" -Level Error
    Write-LogMessage "Stack: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
