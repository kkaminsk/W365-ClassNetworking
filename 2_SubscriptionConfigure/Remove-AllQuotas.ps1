#Requires -Version 5.1
<#
.SYNOPSIS
    Removes ALL quota policy assignments from ALL resource groups (including students).

.DESCRIPTION
    This script removes Azure Policy quota assignments from ALL resource groups in the subscription,
    including both admin and student resource groups. Use with caution.
    
    WARNING: This will remove quota restrictions from student resource groups!

.PARAMETER ListOnly
    List all quota policy assignments without removing them.

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    .\Remove-AllQuotas.ps1 -ListOnly
    List all quota assignments across all resource groups

.EXAMPLE
    .\Remove-AllQuotas.ps1
    Remove all quota assignments (with confirmation)

.EXAMPLE
    .\Remove-AllQuotas.ps1 -Force
    Remove all quota assignments without confirmation

.NOTES
    - Requires Azure PowerShell module (Az.Resources, Az.PolicyInsights)
    - Requires Contributor + User Access Administrator roles
    - REMOVES quotas from student resource groups too!
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$ListOnly,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Initialize logging
$timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
$logPath = Join-Path -Path ([Environment]::GetFolderPath("MyDocuments")) -ChildPath "RemoveAllQuotas-$timestamp.log"

function Write-LogMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $logTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$logTimestamp] [$Level] $Message"
    
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
    
    # Check Az.Resources module
    if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
        Write-LogMessage "ERROR: Az.Resources module not found" -Level Error
        return $false
    }
    
    # Check Az.PolicyInsights module
    if (-not (Get-Module -ListAvailable -Name Az.PolicyInsights)) {
        Write-LogMessage "ERROR: Az.PolicyInsights module not found" -Level Error
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

function Remove-QuotaFromResourceGroup {
    param(
        [string]$ResourceGroupName,
        [bool]$ListOnlyMode
    )
    
    try {
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) {
            return 0
        }
        
        # Get all policy assignments for this resource group with 'quota' in the name
        $assignments = Get-AzPolicyAssignment -Scope $rg.ResourceId -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -match 'quota' }
        
        if ($assignments.Count -eq 0) {
            return 0
        }
        
        Write-LogMessage "  Resource Group: $ResourceGroupName" -Level Info
        Write-LogMessage "    Found $($assignments.Count) quota assignment(s)" -Level Warning
        
        if ($ListOnlyMode) {
            foreach ($assignment in $assignments) {
                Write-LogMessage "      - $($assignment.Name) ($($assignment.Properties.DisplayName))" -Level Info
            }
            return $assignments.Count
        }
        
        # Remove assignments
        $removedCount = 0
        foreach ($assignment in $assignments) {
            try {
                Remove-AzPolicyAssignment -Name $assignment.Name -Scope $rg.ResourceId -ErrorAction Stop | Out-Null
                Write-LogMessage "      ✓ Removed: $($assignment.Name)" -Level Success
                $removedCount++
            }
            catch {
                Write-LogMessage "      ✗ Failed to remove $($assignment.Name): $($_.Exception.Message)" -Level Error
            }
        }
        
        return $removedCount
    }
    catch {
        Write-LogMessage "  Error processing $ResourceGroupName : $($_.Exception.Message)" -Level Warning
        return 0
    }
}

# ============================================================================
# Main Execution
# ============================================================================

try {
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Remove ALL Quota Assignments" -Level Info
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Log: $logPath" -Level Info
    
    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        exit 1
    }
    
    $context = Get-AzContext
    Write-LogMessage "`nAzure Context:" -Level Info
    Write-LogMessage "  Subscription: $($context.Subscription.Name)" -Level Info
    Write-LogMessage "  Account: $($context.Account.Id)" -Level Info
    
    if ($ListOnly) {
        Write-LogMessage "`n⚠️  LIST MODE - No changes will be made" -Level Warning
    }
    else {
        Write-LogMessage "`n⚠️  WARNING: This will remove quota policies from ALL resource groups!" -Level Warning
        Write-LogMessage "⚠️  Including student resource groups (rg-st* pattern)" -Level Warning
        
        if (-not $Force) {
            Write-Host "`n" -NoNewline
            $confirmation = Read-Host "Type 'DELETE ALL QUOTAS' to confirm"
            if ($confirmation -ne 'DELETE ALL QUOTAS') {
                Write-LogMessage "Operation cancelled by user" -Level Info
                exit 0
            }
        }
    }
    
    # Get all resource groups
    Write-LogMessage "`nScanning all resource groups..." -Level Info
    $allResourceGroups = Get-AzResourceGroup
    Write-LogMessage "Found $($allResourceGroups.Count) resource groups" -Level Info
    
    Write-LogMessage "`nProcessing resource groups..." -Level Info
    $totalRemoved = 0
    $rgWithQuotas = 0
    
    foreach ($rg in $allResourceGroups) {
        $removed = Remove-QuotaFromResourceGroup -ResourceGroupName $rg.ResourceGroupName -ListOnlyMode $ListOnly
        if ($removed -gt 0) {
            $totalRemoved += $removed
            $rgWithQuotas++
        }
    }
    
    Write-LogMessage "`n========================================" -Level Success
    Write-LogMessage "Summary" -Level Success
    Write-LogMessage "========================================" -Level Success
    Write-LogMessage "Resource groups scanned: $($allResourceGroups.Count)" -Level Info
    Write-LogMessage "Resource groups with quotas: $rgWithQuotas" -Level Info
    
    if ($ListOnly) {
        Write-LogMessage "Total quota assignments found: $totalRemoved" -Level Info
    }
    else {
        Write-LogMessage "Total quota assignments removed: $totalRemoved" -Level Success
    }
    
}
catch {
    Write-LogMessage "`n========================================" -Level Error
    Write-LogMessage "OPERATION FAILED" -Level Error
    Write-LogMessage "========================================" -Level Error
    Write-LogMessage "Error: $($_.Exception.Message)" -Level Error
    Write-LogMessage "Stack: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
