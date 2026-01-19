#Requires -Version 5.1
<#
.SYNOPSIS
    Removes quota policy assignments from admin/instructor resource groups.

.DESCRIPTION
    This script removes Azure Policy quota assignments from non-student resource groups.
    Student resource groups follow the pattern rg-st{N}-* and should keep their quotas.
    Admin/instructor resource groups (e.g., rg-w365-customimage, rg-hub-*, etc.) should 
    not have quota restrictions.
    
    The script can:
    - Remove quotas from specific resource groups
    - Remove quotas from all non-student resource groups
    - List current quota assignments

.PARAMETER ResourceGroupName
    Specific resource group name to remove quotas from.

.PARAMETER RemoveFromAllAdminRGs
    Remove quota policies from all non-student resource groups (excludes rg-st* pattern).

.PARAMETER ListOnly
    List all quota policy assignments without removing them.

.EXAMPLE
    .\Remove-AdminQuotas.ps1 -ResourceGroupName "rg-w365-customimage"
    Remove quota policies from a specific admin resource group

.EXAMPLE
    .\Remove-AdminQuotas.ps1 -RemoveFromAllAdminRGs
    Remove quota policies from all admin resource groups (excludes student RGs)

.EXAMPLE
    .\Remove-AdminQuotas.ps1 -ListOnly
    List all quota policy assignments across the subscription

.NOTES
    - Requires Azure PowerShell module (Az.Resources, Az.PolicyInsights)
    - Requires Contributor + User Access Administrator roles
    - Does NOT affect student resource groups (rg-st* pattern)
#>

[CmdletBinding(DefaultParameterSetName = 'SpecificRG')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'SpecificRG')]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true, ParameterSetName = 'AllAdminRGs')]
    [switch]$RemoveFromAllAdminRGs,
    
    [Parameter(Mandatory = $false)]
    [switch]$ListOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Initialize logging
$timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
$logPath = Join-Path -Path ([Environment]::GetFolderPath("MyDocuments")) -ChildPath "RemoveAdminQuotas-$timestamp.log"

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
        Write-LogMessage "Install with: Install-Module -Name Az.Resources -Repository PSGallery -Force" -Level Info
        return $false
    }
    
    # Check Az.PolicyInsights module
    if (-not (Get-Module -ListAvailable -Name Az.PolicyInsights)) {
        Write-LogMessage "ERROR: Az.PolicyInsights module not found" -Level Error
        Write-LogMessage "Install with: Install-Module -Name Az.PolicyInsights -Repository PSGallery -Force" -Level Info
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

function Get-QuotaAssignments {
    param([string]$ResourceGroupName)
    
    try {
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) {
            Write-LogMessage "  Resource group not found: $ResourceGroupName" -Level Warning
            return @()
        }
        
        # Get all policy assignments for this resource group
        $assignments = Get-AzPolicyAssignment -Scope $rg.ResourceId -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -match 'quota' }
        
        return $assignments
    }
    catch {
        Write-LogMessage "  Error checking assignments for $ResourceGroupName : $($_.Exception.Message)" -Level Warning
        return @()
    }
}

function Remove-QuotaFromResourceGroup {
    param([string]$ResourceGroupName)
    
    Write-LogMessage "Checking resource group: $ResourceGroupName" -Level Info
    
    $assignments = Get-QuotaAssignments -ResourceGroupName $ResourceGroupName
    
    if ($assignments.Count -eq 0) {
        Write-LogMessage "  No quota assignments found" -Level Info
        return $false
    }
    
    Write-LogMessage "  Found $($assignments.Count) quota assignment(s)" -Level Warning
    
    if ($ListOnly) {
        foreach ($assignment in $assignments) {
            Write-LogMessage "    - $($assignment.Name) ($($assignment.Properties.DisplayName))" -Level Info
        }
        return $true
    }
    
    # Remove assignments
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
    $removedCount = 0
    
    foreach ($assignment in $assignments) {
        try {
            Write-LogMessage "  Removing: $($assignment.Name)" -Level Info
            Remove-AzPolicyAssignment -Name $assignment.Name -Scope $rg.ResourceId -ErrorAction Stop | Out-Null
            Write-LogMessage "    ✓ Removed: $($assignment.Name)" -Level Success
            $removedCount++
        }
        catch {
            Write-LogMessage "    Failed to remove $($assignment.Name): $($_.Exception.Message)" -Level Error
        }
    }
    
    Write-LogMessage "  Removed $removedCount of $($assignments.Count) quota assignments" -Level Success
    return $true
}

function Test-IsStudentResourceGroup {
    param([string]$Name)
    
    # Student resource groups follow pattern: rg-st{N}-customimage or rg-st{N}-spoke
    return $Name -match '^rg-st\d+-'
}

# ============================================================================
# Main Execution
# ============================================================================

try {
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Remove Admin Quota Assignments" -Level Info
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
        Write-LogMessage "`nListing mode - no changes will be made" -Level Warning
    }
    
    if ($PSCmdlet.ParameterSetName -eq 'SpecificRG') {
        # Check if it's a student resource group
        if (Test-IsStudentResourceGroup -Name $ResourceGroupName) {
            Write-LogMessage "`nWARNING: '$ResourceGroupName' appears to be a student resource group" -Level Warning
            Write-LogMessage "Student resource groups should keep quota restrictions." -Level Warning
            
            $confirmation = Read-Host "Are you sure you want to remove quotas? (yes/no)"
            if ($confirmation -ne 'yes') {
                Write-LogMessage "Operation cancelled by user" -Level Info
                exit 0
            }
        }
        
        Write-LogMessage "`nProcessing resource group: $ResourceGroupName" -Level Info
        Remove-QuotaFromResourceGroup -ResourceGroupName $ResourceGroupName
    }
    else {
        # Get all resource groups
        Write-LogMessage "`nScanning all resource groups..." -Level Info
        $allResourceGroups = Get-AzResourceGroup
        
        # Filter to non-student resource groups
        $adminResourceGroups = $allResourceGroups | Where-Object { 
            -not (Test-IsStudentResourceGroup -Name $_.ResourceGroupName) 
        }
        
        Write-LogMessage "Found $($allResourceGroups.Count) total resource groups" -Level Info
        Write-LogMessage "Found $($adminResourceGroups.Count) admin/instructor resource groups" -Level Info
        Write-LogMessage "Skipping $(($allResourceGroups.Count - $adminResourceGroups.Count)) student resource groups (rg-st* pattern)" -Level Info
        
        if ($adminResourceGroups.Count -eq 0) {
            Write-LogMessage "No admin resource groups found" -Level Warning
            exit 0
        }
        
        Write-LogMessage "`nProcessing admin resource groups..." -Level Info
        $processedCount = 0
        
        foreach ($rg in $adminResourceGroups) {
            if (Remove-QuotaFromResourceGroup -ResourceGroupName $rg.ResourceGroupName) {
                $processedCount++
            }
        }
        
        Write-LogMessage "`nProcessed $processedCount resource groups with quota assignments" -Level Info
    }
    
    Write-LogMessage "`n========================================" -Level Success
    if ($ListOnly) {
        Write-LogMessage "Quota listing complete!" -Level Success
    }
    else {
        Write-LogMessage "Quota removal complete!" -Level Success
    }
    Write-LogMessage "========================================" -Level Success
    
}
catch {
    Write-LogMessage "`n========================================" -Level Error
    Write-LogMessage "OPERATION FAILED" -Level Error
    Write-LogMessage "========================================" -Level Error
    Write-LogMessage "Error: $($_.Exception.Message)" -Level Error
    Write-LogMessage "Stack: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
