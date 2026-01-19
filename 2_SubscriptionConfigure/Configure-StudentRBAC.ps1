<#
.SYNOPSIS
    Configures Azure RBAC for Windows 365 lab students in a single-subscription environment.

.DESCRIPTION
    This script automates the configuration of student lab environments by:
    - Creating resource groups for students (using New-StudentResourceGroups.ps1)
    - Assigning Contributor role to student accounts (W365Student{N}@domain.com) on their resource groups
    - Registering required Azure resource providers
    - Supporting single student or batch provisioning

    Each student receives:
    - Contributor role on rg-st{N}-customimage (custom image resources)
    - Contributor role on rg-st{N}-spoke (Windows 365 network resources)

    Students are isolated and cannot access other students' resource groups.

.PARAMETER StudentNumber
    The student number (1-30) to configure. Required unless -ConfigureAllStudents is specified.

.PARAMETER TotalStudents
    Total number of students for batch configuration. Default is 30. Only used with -ConfigureAllStudents.

.PARAMETER ConfigureAllStudents
    Switch to configure RBAC for all students (1 through TotalStudents) in batch mode.

.PARAMETER Location
    Azure region for resource group creation. Default is "southcentralus".

.PARAMETER SkipResourceGroupCreation
    Skip resource group creation (assumes RGs already exist). Useful for re-running RBAC assignment only.

.PARAMETER SkipResourceProviders
    Skip Azure resource provider registration.

.EXAMPLE
    .\Configure-StudentRBAC.ps1 -StudentNumber 5
    Configure Student 5: create RGs, assign W365Student5@domain.com Contributor role

.EXAMPLE
    .\Configure-StudentRBAC.ps1 -ConfigureAllStudents -TotalStudents 30
    Configure all 30 students with resource groups and RBAC

.EXAMPLE
    .\Configure-StudentRBAC.ps1 -StudentNumber 10 -SkipResourceGroupCreation
    Assign RBAC to Student 10 (assumes RGs already exist)

.NOTES
    File Name: Configure-StudentRBAC.ps1
    Author: OpenSpec Automation
    Requires: PowerShell 7.0+, Az.Accounts, Az.Resources modules
    Prerequisites:
    - Azure subscription context must be set
    - User must have Owner or User Access Administrator at subscription level
    - Student accounts must exist in Azure AD (W365Student1@domain.com, W365Student2@domain.com, etc.)
    - New-StudentResourceGroups.ps1 must be in the same directory
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 30)]
    [int]$StudentNumber,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 30)]
    [int]$TotalStudents = 30,

    [Parameter(Mandatory = $false)]
    [switch]$ConfigureAllStudents,

    [Parameter(Mandatory = $false)]
    [string]$Location = "southcentralus",

    [Parameter(Mandatory = $false)]
    [switch]$SkipResourceGroupCreation,

    [Parameter(Mandatory = $false)]
    [switch]$SkipResourceProviders
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$ScriptPath = $PSScriptRoot

# Initialize log file in Documents folder
$documentsFolder = [Environment]::GetFolderPath('MyDocuments')
$timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
$logFile = Join-Path $documentsFolder "Configure-StudentRBAC-$timestamp.log"

# ============================================================================
# Helper Functions
# ============================================================================

function Write-LogMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colorMap = @{
        "Info"    = "Cyan"
        "Success" = "Green"
        "Warning" = "Yellow"
        "Error"   = "Red"
    }
    
    $color = $colorMap[$Level]
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console
    Write-Host $logEntry -ForegroundColor $color
    
    # Write to log file
    $logEntry | Out-File -FilePath $logFile -Append -Encoding UTF8
}

function Register-AzureProviders {
    Write-Host "`n[Step] Registering Azure resource providers..." -ForegroundColor Yellow
    
    $providers = @(
        "Microsoft.Compute",
        "Microsoft.Storage",
        "Microsoft.Network",
        "Microsoft.ManagedIdentity",
        "Microsoft.Compute/galleries"
    )
    
    foreach ($provider in $providers) {
        try {
            $registration = Get-AzResourceProvider -ProviderNamespace $provider.Split('/')[0] -ErrorAction Stop
            $providerStatus = $registration | Where-Object { $_.ProviderNamespace -eq $provider.Split('/')[0] }
            
            if ($providerStatus.RegistrationState -ne "Registered") {
                Write-LogMessage "  Registering provider: $provider" -Level Info
                Register-AzResourceProvider -ProviderNamespace $provider.Split('/')[0] | Out-Null
                Write-LogMessage "  ✓ Registered: $provider" -Level Success
            }
            else {
                Write-LogMessage "  ✓ Already registered: $provider" -Level Info
            }
        }
        catch {
            Write-LogMessage "  ⚠ Failed to register provider $provider: $($_.Exception.Message)" -Level Warning
        }
    }
}

function Get-StudentUserPrincipalId {
    param(
        [Parameter(Mandatory = $true)]
        [int]$StudentNum,
        
        [Parameter(Mandatory = $true)]
        [string]$TenantDomain
    )
    
    $upn = "W365Student$StudentNum@$TenantDomain"
    
    try {
        # Try to get the user from Azure AD
        $user = Get-AzADUser -UserPrincipalName $upn -ErrorAction Stop
        
        if ($user) {
            Write-LogMessage "    Found user: $upn (Object ID: $($user.Id))" -Level Success
            return @{
                Success   = $true
                ObjectId  = $user.Id
                UPN       = $upn
            }
        }
    }
    catch {
        Write-LogMessage "    ⚠ User not found: $upn" -Level Warning
        Write-LogMessage "      Error: $($_.Exception.Message)" -Level Warning
        return @{
            Success   = $false
            ObjectId  = $null
            UPN       = $upn
            Error     = $_.Exception.Message
        }
    }
}

function Set-StudentRBAC {
    param(
        [Parameter(Mandatory = $true)]
        [int]$StudentNum,
        
        [Parameter(Mandatory = $true)]
        [string]$UserObjectId,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId
    )
    
    $customImageRg = "rg-st$StudentNum-customimage"
    $spokeRg = "rg-st$StudentNum-spoke"
    $contributorRoleId = "b24988ac-6180-42a0-ab88-20f7382dd24c"  # Built-in Contributor role
    
    $success = $true
    
    # Assign Contributor on Custom Image RG
    try {
        $scope = "/subscriptions/$SubscriptionId/resourceGroups/$customImageRg"
        
        # Check if assignment already exists
        $existing = Get-AzRoleAssignment -ObjectId $UserObjectId -RoleDefinitionId $contributorRoleId -Scope $scope -ErrorAction SilentlyContinue
        
        if ($existing) {
            Write-LogMessage "    ✓ RBAC already assigned: $customImageRg" -Level Info
        }
        else {
            New-AzRoleAssignment -ObjectId $UserObjectId -RoleDefinitionId $contributorRoleId -Scope $scope -ErrorAction Stop | Out-Null
            Write-LogMessage "    ✓ Assigned Contributor: $customImageRg" -Level Success
            Start-Sleep -Seconds 2  # Brief pause for propagation
        }
    }
    catch {
        Write-LogMessage "    ✗ Failed to assign role on $customImageRg : $($_.Exception.Message)" -Level Error
        $success = $false
    }
    
    # Assign Contributor on Spoke RG
    try {
        $scope = "/subscriptions/$SubscriptionId/resourceGroups/$spokeRg"
        
        # Check if assignment already exists
        $existing = Get-AzRoleAssignment -ObjectId $UserObjectId -RoleDefinitionId $contributorRoleId -Scope $scope -ErrorAction SilentlyContinue
        
        if ($existing) {
            Write-LogMessage "    ✓ RBAC already assigned: $spokeRg" -Level Info
        }
        else {
            New-AzRoleAssignment -ObjectId $UserObjectId -RoleDefinitionId $contributorRoleId -Scope $scope -ErrorAction Stop | Out-Null
            Write-LogMessage "    ✓ Assigned Contributor: $spokeRg" -Level Success
            Start-Sleep -Seconds 2  # Brief pause for propagation
        }
    }
    catch {
        Write-LogMessage "    ✗ Failed to assign role on $spokeRg : $($_.Exception.Message)" -Level Error
        $success = $false
    }
    
    return $success
}

# ============================================================================
# Main Script
# ============================================================================

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Student RBAC Configuration - Multi-Student Lab" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-LogMessage "Log file: $logFile" -Level Info

# Validate parameters
if (-not $ConfigureAllStudents -and -not $StudentNumber) {
    Write-LogMessage "ERROR: Either -StudentNumber or -ConfigureAllStudents must be specified" -Level Error
    Write-Host "`nUsage:" -ForegroundColor Yellow
    Write-Host "  Single student: .\Configure-StudentRBAC.ps1 -StudentNumber 5" -ForegroundColor White
    Write-Host "  All students:   .\Configure-StudentRBAC.ps1 -ConfigureAllStudents -TotalStudents 30" -ForegroundColor White
    exit 1
}

# Verify Azure context
Write-Host "`n[Step] Verifying Azure context..." -ForegroundColor Yellow
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        Write-LogMessage "ERROR: No Azure context found. Please run Connect-AzAccount first." -Level Error
        exit 1
    }
    
    $subscriptionId = $context.Subscription.Id
    $tenantDomain = $context.Tenant.Id  # We'll need to get the actual domain
    
    # Try to get tenant domain from context
    $tenantInfo = Get-AzTenant -TenantId $context.Tenant.Id -ErrorAction SilentlyContinue
    if ($tenantInfo.Domains) {
        $tenantDomain = ($tenantInfo.Domains | Where-Object { $_ -notlike "*.onmicrosoft.com" } | Select-Object -First 1)
        if (-not $tenantDomain) {
            $tenantDomain = ($tenantInfo.Domains | Select-Object -First 1)
        }
    }
    
    Write-LogMessage "  Subscription: $($context.Subscription.Name)" -Level Info
    Write-LogMessage "  Subscription ID: $subscriptionId" -Level Info
    Write-LogMessage "  Tenant Domain: $tenantDomain" -Level Info
    Write-LogMessage "  Location: $Location" -Level Info
}
catch {
    Write-LogMessage "ERROR: Failed to get Azure context: $($_.Exception.Message)" -Level Error
    exit 1
}

# Determine which students to configure
if ($ConfigureAllStudents) {
    $students = 1..$TotalStudents
    Write-LogMessage "Batch configuration for $TotalStudents students (ST1 through ST$TotalStudents)" -Level Info
}
else {
    $students = @($StudentNumber)
    Write-LogMessage "Single-student configuration for Student $StudentNumber (ST$StudentNumber)" -Level Info
}

# Register resource providers
if (-not $SkipResourceProviders) {
    Register-AzureProviders
}
else {
    Write-LogMessage "Skipping resource provider registration" -Level Info
}

# Create resource groups
if (-not $SkipResourceGroupCreation) {
    Write-Host "`n[Step] Creating resource groups..." -ForegroundColor Yellow
    
    $rgScript = Join-Path $ScriptPath "New-StudentResourceGroups.ps1"
    if (-not (Test-Path $rgScript)) {
        Write-LogMessage "ERROR: New-StudentResourceGroups.ps1 not found at: $rgScript" -Level Error
        exit 1
    }
    
    if ($ConfigureAllStudents) {
        & $rgScript -CreateAllStudents -TotalStudents $TotalStudents -Location $Location
    }
    else {
        & $rgScript -StudentNumber $StudentNumber -Location $Location
    }
    
    if ($LASTEXITCODE -ne 0) {
        Write-LogMessage "ERROR: Resource group creation failed" -Level Error
        exit 1
    }
}
else {
    Write-LogMessage "Skipping resource group creation (assuming RGs already exist)" -Level Info
}

# Configure RBAC for students
Write-Host "`n[Step] Configuring student RBAC assignments..." -ForegroundColor Yellow

$totalStudents = $students.Count
$currentStudent = 0
$successCount = 0
$failureCount = 0
$notFoundCount = 0

foreach ($studentNum in $students) {
    $currentStudent++
    $percentComplete = [int](($currentStudent / $totalStudents) * 100)
    Write-Progress -Activity "Configuring Student RBAC" -Status "Student $studentNum (ST$studentNum) - $currentStudent of $totalStudents" -PercentComplete $percentComplete
    
    Write-Host "`n  Student $studentNum (ST$studentNum):" -ForegroundColor Yellow
    
    # Get student user principal
    $userInfo = Get-StudentUserPrincipalId -StudentNum $studentNum -TenantDomain $tenantDomain
    
    if (-not $userInfo.Success) {
        Write-LogMessage "    ⚠ Skipping RBAC assignment - user not found" -Level Warning
        $notFoundCount++
        continue
    }
    
    # Assign RBAC
    if (Set-StudentRBAC -StudentNum $studentNum -UserObjectId $userInfo.ObjectId -SubscriptionId $subscriptionId) {
        $successCount++
    }
    else {
        $failureCount++
    }
}

Write-Progress -Activity "Configuring Student RBAC" -Completed

# Summary
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Configuration Summary" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Students Processed: $totalStudents" -ForegroundColor White
Write-Host "  RBAC Configured: $successCount" -ForegroundColor Green

if ($notFoundCount -gt 0) {
    Write-Host "  Users Not Found: $notFoundCount" -ForegroundColor Yellow
    Write-Host "`n  ⚠ Missing user accounts must be created before RBAC can be assigned." -ForegroundColor Yellow
    Write-Host "    Expected UPN format: W365Student{N}@$tenantDomain" -ForegroundColor Gray
}

if ($failureCount -gt 0) {
    Write-Host "  Failures: $failureCount" -ForegroundColor Red
}

Write-Host "`n  Log File: $logFile" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failureCount -gt 0 -or $notFoundCount -gt 0) {
    Write-LogMessage "Configuration completed with issues" -Level Warning
    exit 1
}
else {
    Write-LogMessage "Configuration completed successfully" -Level Success
    exit 0
}
