#Requires -Version 7.0
<#
.SYNOPSIS
    Fixes student admin RBAC permissions by reassigning roles at subscription scope

.DESCRIPTION
    This script corrects the role assignment scope issue where student admins were assigned
    custom roles to non-existent resource groups. It reassigns the roles at subscription scope,
    allowing students to create and manage their own resource groups.
    
    This script should be run if SubscriptionConfigure.ps1 was executed before the fix was applied.

.PARAMETER TenantId
    Optional Azure AD tenant ID to target

.PARAMETER SubscriptionId
    Optional subscription ID

.PARAMETER StudentCount
    Number of student accounts to fix (default: 30)

.PARAMETER Force
    Forces clearing of all cached Azure credentials before authentication.
    Use this if you're being redirected to the wrong tenant.

.EXAMPLE
    .\Fix-StudentPermissions.ps1
    Interactive mode with default 30 students

.EXAMPLE
    .\Fix-StudentPermissions.ps1 -Force
    Clear cached credentials and authenticate with fresh login

.EXAMPLE
    .\Fix-StudentPermissions.ps1 -StudentCount 40
    Fix permissions for 40 students

.EXAMPLE
    .\Fix-StudentPermissions.ps1 -TenantId "xxx" -SubscriptionId "yyy" -StudentCount 20
    Fix permissions for specific tenant/subscription with 20 students
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 40)]
    [int]$StudentCount = 30,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Fix Student Admin RBAC Permissions" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Clear cached credentials if Force is specified
if ($Force) {
    Write-Host "`nClearing cached Azure credentials..." -ForegroundColor Yellow
    try {
        Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
        Clear-AzContext -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host "✓ Credentials cleared" -ForegroundColor Green
    }
    catch {
        Write-Host "⚠ Note: Some credentials may still be cached" -ForegroundColor Yellow
    }
}

# Authenticate to Azure
Write-Host "`nConnecting to Azure..." -ForegroundColor Cyan
try {
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context -or $Force) {
        Connect-AzAccount | Out-Null
        $context = Get-AzContext
    }
    Write-Host "✓ Connected as: $($context.Account.Id)" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to connect to Azure" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# Select tenant
if ($TenantId) {
    Write-Host "`nAuthenticating to specified tenant..." -ForegroundColor Cyan
    try {
        Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null
        Write-Host "✓ Connected to tenant: $TenantId" -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: Failed to connect to tenant $TenantId" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
}
else {
    # Show available tenants
    Write-Host "`nRetrieving available tenants..." -ForegroundColor Cyan
    $tenants = @(Get-AzTenant)
    
    if ($tenants.Count -eq 0) {
        Write-Host "ERROR: No accessible tenants found" -ForegroundColor Red
        exit 1
    }
    elseif ($tenants.Count -eq 1) {
        Write-Host "✓ Using tenant: $($tenants[0].Name) ($($tenants[0].Id))" -ForegroundColor Green
        Connect-AzAccount -TenantId $tenants[0].Id -ErrorAction Stop | Out-Null
    }
    else {
        Write-Host "`nAvailable Tenants:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $tenants.Count; $i++) {
            Write-Host "  [$($i + 1)] $($tenants[$i].Name) ($($tenants[$i].Id))" -ForegroundColor White
        }
        do {
            $selection = Read-Host "`nSelect tenant (1-$($tenants.Count))"
            $index = [int]$selection - 1
        } while ($index -lt 0 -or $index -ge $tenants.Count)
        
        Write-Host "Authenticating to tenant..." -ForegroundColor Cyan
        Connect-AzAccount -TenantId $tenants[$index].Id -ErrorAction Stop | Out-Null
        Write-Host "✓ Connected to: $($tenants[$index].Name)" -ForegroundColor Green
    }
}

# Get subscription context
if (-not $SubscriptionId) {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
    
    if ($subscriptions.Count -eq 0) {
        Write-Host "ERROR: No enabled subscriptions found" -ForegroundColor Red
        exit 1
    }
    elseif ($subscriptions.Count -eq 1) {
        $SubscriptionId = $subscriptions[0].Id
        Write-Host "✓ Using subscription: $($subscriptions[0].Name)" -ForegroundColor Green
    }
    else {
        Write-Host "`nAvailable Subscriptions:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            Write-Host "  [$($i + 1)] $($subscriptions[$i].Name)" -ForegroundColor White
        }
        do {
            $selection = Read-Host "`nSelect subscription (1-$($subscriptions.Count))"
            $index = [int]$selection - 1
        } while ($index -lt 0 -or $index -ge $subscriptions.Count)
        
        $SubscriptionId = $subscriptions[$index].Id
        Write-Host "✓ Selected: $($subscriptions[$index].Name)" -ForegroundColor Green
    }
}

# Set context
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
$subscriptionScope = "/subscriptions/$SubscriptionId"

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Fixing Role Assignments" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Subscription: $SubscriptionId" -ForegroundColor White
Write-Host "Student Count: $StudentCount" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor Cyan

# Define roles to fix
$rolesToFix = @(
    "Windows 365 Custom Image Builder",
    "Windows 365 Spoke Network Deployer"
)

$fixedCount = 0
$skippedCount = 0
$errorCount = 0

foreach ($roleName in $rolesToFix) {
    Write-Host "`nProcessing role: $roleName" -ForegroundColor Cyan
    
    # Check if role exists
    $role = Get-AzRoleDefinition -Name $roleName -ErrorAction SilentlyContinue
    if (-not $role) {
        Write-Host "  ⚠ Role not found, skipping" -ForegroundColor Yellow
        continue
    }
    
    for ($i = 1; $i -le $StudentCount; $i++) {
        $studentAdminUPN = "admin$i@bighatgrouptraining.ca"
        
        # Check if already assigned at subscription scope
        $existingAssignment = Get-AzRoleAssignment `
            -SignInName $studentAdminUPN `
            -RoleDefinitionName $roleName `
            -Scope $subscriptionScope `
            -ErrorAction SilentlyContinue
        
        if ($existingAssignment) {
            Write-Host "  ✓ Already assigned: $studentAdminUPN" -ForegroundColor Gray
            $skippedCount++
            continue
        }
        
        # Assign role at subscription scope
        try {
            New-AzRoleAssignment `
                -SignInName $studentAdminUPN `
                -RoleDefinitionName $roleName `
                -Scope $subscriptionScope `
                -ErrorAction Stop | Out-Null
            
            Write-Host "  ✓ Fixed: $studentAdminUPN" -ForegroundColor Green
            $fixedCount++
        }
        catch {
            Write-Host "  ✗ ERROR: $studentAdminUPN - $($_.Exception.Message)" -ForegroundColor Red
            $errorCount++
        }
    }
}

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Fixed:   $fixedCount assignments" -ForegroundColor Green
Write-Host "Skipped: $skippedCount (already correct)" -ForegroundColor Yellow
Write-Host "Errors:  $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Gray" })
Write-Host "==========================================" -ForegroundColor Cyan

if ($errorCount -eq 0 -and $fixedCount -gt 0) {
    Write-Host "`n✓ All permissions have been fixed!" -ForegroundColor Green
    Write-Host "Student admins can now deploy their infrastructure." -ForegroundColor Green
}
elseif ($skippedCount -gt 0 -and $fixedCount -eq 0) {
    Write-Host "`n✓ All permissions are already correct!" -ForegroundColor Green
}
elseif ($errorCount -gt 0) {
    Write-Host "`n⚠ Some errors occurred. Review the output above." -ForegroundColor Yellow
}

Write-Host ""
