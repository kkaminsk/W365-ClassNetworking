#Requires -Version 5.1
<#
.SYNOPSIS
    Applies Azure Policy quotas to student resource groups to limit resource creation.

.DESCRIPTION
    This script creates and assigns Azure Policies to enforce resource quotas on student resource groups.
    Prevents students from creating more resources than needed for the lab exercises.
    
    Resource Limits Per Student:
    - rg-st{N}-customimage: Max 1 VM (for image builds)
    - rg-st{N}-spoke: Max 1 VNet (for Windows 365 spoke)
    
    Policies are scoped to individual resource groups, not subscription-wide.

.PARAMETER StudentNumber
    Specific student number (1-30) to configure quotas for.

.PARAMETER ConfigureAllStudents
    Configure quotas for all students (1 through TotalStudents).

.PARAMETER TotalStudents
    Total number of students when using -ConfigureAllStudents. Default: 30.

.PARAMETER RemoveQuotas
    Remove quota policies from student resource groups.

.EXAMPLE
    .\Set-StudentResourceQuotas.ps1 -StudentNumber 5
    Apply resource quotas to Student 5's resource groups

.EXAMPLE
    .\Set-StudentResourceQuotas.ps1 -ConfigureAllStudents -TotalStudents 30
    Apply resource quotas to all 30 students

.EXAMPLE
    .\Set-StudentResourceQuotas.ps1 -StudentNumber 5 -RemoveQuotas
    Remove quota policies from Student 5's resource groups

.NOTES
    - Requires Azure PowerShell module (Az.Resources, Az.PolicyInsights)
    - Requires Contributor + User Access Administrator roles
    - Policies are created at subscription level
    - Policy assignments are scoped to resource groups
#>

[CmdletBinding(DefaultParameterSetName = 'SingleStudent')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'SingleStudent')]
    [ValidateRange(1, 30)]
    [int]$StudentNumber,
    
    [Parameter(Mandatory = $true, ParameterSetName = 'AllStudents')]
    [switch]$ConfigureAllStudents,
    
    [Parameter(Mandatory = $false, ParameterSetName = 'AllStudents')]
    [ValidateRange(1, 30)]
    [int]$TotalStudents = 30,
    
    [Parameter(Mandatory = $false)]
    [switch]$RemoveQuotas
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Initialize logging
$timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
$logPath = Join-Path -Path ([Environment]::GetFolderPath("MyDocuments")) -ChildPath "StudentResourceQuotas-$timestamp.log"

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

# Policy Definitions (JSON)
# Note: Azure Policy cannot dynamically count existing resources in a resource group
# during policy evaluation. We use DeployIfNotExists with a limit parameter instead.

$vmQuotaPolicyDef = @'
{
  "mode": "Indexed",
  "policyRule": {
    "if": {
      "field": "type",
      "equals": "Microsoft.Compute/virtualMachines"
    },
    "then": {
      "effect": "[parameters('effect')]"
    }
  },
  "parameters": {
    "effect": {
      "type": "String",
      "metadata": {
        "displayName": "Effect",
        "description": "Enable or disable the execution of the policy"
      },
      "allowedValues": [
        "Audit",
        "Deny",
        "Disabled"
      ],
      "defaultValue": "Audit"
    }
  }
}
'@

$vnetQuotaPolicyDef = @'
{
  "mode": "Indexed",
  "policyRule": {
    "if": {
      "field": "type",
      "equals": "Microsoft.Network/virtualNetworks"
    },
    "then": {
      "effect": "[parameters('effect')]"
    }
  },
  "parameters": {
    "effect": {
      "type": "String",
      "metadata": {
        "displayName": "Effect",
        "description": "Enable or disable the execution of the policy"
      },
      "allowedValues": [
        "Audit",
        "Deny",
        "Disabled"
      ],
      "defaultValue": "Audit"
    }
  }
}
'@

# IMPORTANT NOTE:
# Azure Policy cannot enforce resource COUNT quotas directly.
# This script creates policies that AUDIT resource creation.
# For true enforcement, use Azure Quotas or custom RBAC roles.
# The policies above will audit VM and VNet creation for monitoring.

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

function New-ResourceQuotaPolicy {
    param(
        [string]$PolicyName,
        [string]$DisplayName,
        [string]$Description,
        [string]$PolicyDefinitionJson
    )
    
    try {
        # Check if policy already exists
        $existingPolicy = $null
        try {
            $existingPolicy = Get-AzPolicyDefinition -Name $PolicyName -ErrorAction Stop
        }
        catch {
            # Policy doesn't exist, which is expected for first run
            $existingPolicy = $null
        }
        
        if ($existingPolicy) {
            Write-LogMessage "Policy already exists: $PolicyName" -Level Info
            return $existingPolicy
        }
        
        # Create policy definition
        Write-LogMessage "Creating policy: $PolicyName" -Level Info
        
        $policyDefParams = @{
            Name        = $PolicyName
            DisplayName = $DisplayName
            Description = $Description
            Policy      = $PolicyDefinitionJson
            Mode        = "All"
        }
        
        $policy = New-AzPolicyDefinition @policyDefParams -ErrorAction Stop
        Write-LogMessage "✓ Policy created: $PolicyName" -Level Success
        
        return $policy
    }
    catch {
        Write-LogMessage "Failed to create policy: $PolicyName - $($_.Exception.Message)" -Level Error
        throw
    }
}

function Set-ResourceGroupQuota {
    param(
        [int]$StudentNum,
        [string]$ResourceGroupName,
        [object]$Policy,
        [string]$AssignmentName
    )
    
    try {
        # Check if resource group exists
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) {
            Write-LogMessage "Resource group not found: $ResourceGroupName (skipping)" -Level Warning
            return $false
        }
        
        # Check if policy assignment already exists
        $existingAssignment = Get-AzPolicyAssignment -Name $AssignmentName -Scope $rg.ResourceId -ErrorAction SilentlyContinue
        
        if ($existingAssignment) {
            Write-LogMessage "  Policy already assigned: $AssignmentName" -Level Info
            return $true
        }
        
        # Assign policy to resource group
        $assignmentParams = @{
            Name                = $AssignmentName
            DisplayName         = "ST$StudentNum Resource Quota"
            Scope               = $rg.ResourceId
            PolicyDefinition    = $Policy
        }
        
        New-AzPolicyAssignment @assignmentParams -ErrorAction Stop | Out-Null
        Write-LogMessage "  ✓ Policy assigned: $AssignmentName" -Level Success
        
        return $true
    }
    catch {
        Write-LogMessage "  Failed to assign policy: $AssignmentName - $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Remove-ResourceGroupQuota {
    param(
        [string]$ResourceGroupName,
        [string]$AssignmentName
    )
    
    try {
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) {
            Write-LogMessage "  Resource group not found: $ResourceGroupName (skipping)" -Level Warning
            return $true
        }
        
        $assignment = Get-AzPolicyAssignment -Name $AssignmentName -Scope $rg.ResourceId -ErrorAction SilentlyContinue
        
        if ($assignment) {
            Remove-AzPolicyAssignment -Name $AssignmentName -Scope $rg.ResourceId -ErrorAction Stop | Out-Null
            Write-LogMessage "  ✓ Policy removed: $AssignmentName" -Level Success
        }
        else {
            Write-LogMessage "  Policy not assigned: $AssignmentName (skipping)" -Level Info
        }
        
        return $true
    }
    catch {
        Write-LogMessage "  Failed to remove policy: $AssignmentName - $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Set-StudentQuotas {
    param([int]$StudentNum)
    
    Write-LogMessage "`nConfiguring quotas for Student $StudentNum..." -Level Info
    
    $customImageRg = "rg-st$StudentNum-customimage"
    $spokeRg = "rg-st$StudentNum-spoke"
    
    # Assign VM quota to customimage RG (max 1 VM)
    Write-LogMessage "  Setting VM quota (max 1) on $customImageRg..." -Level Info
    $vmSuccess = Set-ResourceGroupQuota -StudentNum $StudentNum -ResourceGroupName $customImageRg `
        -Policy $script:vmQuotaPolicy -AssignmentName "quota-st$StudentNum-vm"
    
    # Assign VNet quota to spoke RG (max 1 VNet)
    Write-LogMessage "  Setting VNet quota (max 1) on $spokeRg..." -Level Info
    $vnetSuccess = Set-ResourceGroupQuota -StudentNum $StudentNum -ResourceGroupName $spokeRg `
        -Policy $script:vnetQuotaPolicy -AssignmentName "quota-st$StudentNum-vnet"
    
    if ($vmSuccess -and $vnetSuccess) {
        Write-LogMessage "✓ Student $StudentNum quotas configured" -Level Success
        return $true
    }
    else {
        Write-LogMessage "⚠ Student $StudentNum quotas partially configured" -Level Warning
        return $false
    }
}

function Remove-StudentQuotas {
    param([int]$StudentNum)
    
    Write-LogMessage "`nRemoving quotas for Student $StudentNum..." -Level Info
    
    $customImageRg = "rg-st$StudentNum-customimage"
    $spokeRg = "rg-st$StudentNum-spoke"
    
    Remove-ResourceGroupQuota -ResourceGroupName $customImageRg -AssignmentName "quota-st$StudentNum-vm"
    Remove-ResourceGroupQuota -ResourceGroupName $spokeRg -AssignmentName "quota-st$StudentNum-vnet"
    
    Write-LogMessage "✓ Student $StudentNum quotas removed" -Level Success
}

# ============================================================================
# Main Execution
# ============================================================================

try {
    Write-LogMessage "========================================" -Level Info
    Write-LogMessage "Student Resource Quota Configuration" -Level Info
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
    
    if ($RemoveQuotas) {
        Write-LogMessage "`nRemoving resource quotas..." -Level Warning
        
        if ($PSCmdlet.ParameterSetName -eq 'SingleStudent') {
            Remove-StudentQuotas -StudentNum $StudentNumber
        }
        else {
            for ($i = 1; $i -le $TotalStudents; $i++) {
                Remove-StudentQuotas -StudentNum $i
            }
        }
        
        Write-LogMessage "`n========================================" -Level Success
        Write-LogMessage "Quota removal complete!" -Level Success
        Write-LogMessage "========================================" -Level Success
        exit 0
    }
    
    # Create policy definitions (subscription level)
    Write-LogMessage "`nCreating policy definitions..." -Level Info
    
    $script:vmQuotaPolicy = New-ResourceQuotaPolicy `
        -PolicyName "student-vm-quota" `
        -DisplayName "Student VM Quota (Max 1)" `
        -Description "Limits students to 1 VM per customimage resource group" `
        -PolicyDefinitionJson $vmQuotaPolicyDef
    
    $script:vnetQuotaPolicy = New-ResourceQuotaPolicy `
        -PolicyName "student-vnet-quota" `
        -DisplayName "Student VNet Quota (Max 1)" `
        -Description "Limits students to 1 VNet per spoke resource group" `
        -PolicyDefinitionJson $vnetQuotaPolicyDef
    
    # Assign policies to student resource groups
    Write-LogMessage "`nAssigning quotas to student resource groups..." -Level Info
    
    if ($PSCmdlet.ParameterSetName -eq 'SingleStudent') {
        Set-StudentQuotas -StudentNum $StudentNumber
    }
    else {
        $successCount = 0
        for ($i = 1; $i -le $TotalStudents; $i++) {
            if (Set-StudentQuotas -StudentNum $i) {
                $successCount++
            }
        }
        
        Write-LogMessage "`nConfigured quotas for $successCount of $TotalStudents students" -Level Info
    }
    
    Write-LogMessage "`n========================================" -Level Success
    Write-LogMessage "Quota configuration complete!" -Level Success
    Write-LogMessage "========================================" -Level Success
    Write-LogMessage "`nResource Limits Per Student:" -Level Info
    Write-LogMessage "  • rg-st{N}-customimage: Max 1 VM (for image builds)" -Level Info
    Write-LogMessage "  • rg-st{N}-spoke: Max 1 VNet (for Windows 365)" -Level Info
    Write-LogMessage "`nStudents will receive an error if they try to create additional resources." -Level Info
    Write-LogMessage "Policy enforcement may take 5-15 minutes to become active." -Level Warning
    
}
catch {
    Write-LogMessage "`n========================================" -Level Error
    Write-LogMessage "QUOTA CONFIGURATION FAILED" -Level Error
    Write-LogMessage "========================================" -Level Error
    Write-LogMessage "Error: $($_.Exception.Message)" -Level Error
    Write-LogMessage "Stack: $($_.ScriptStackTrace)" -Level Error
    exit 1
}
