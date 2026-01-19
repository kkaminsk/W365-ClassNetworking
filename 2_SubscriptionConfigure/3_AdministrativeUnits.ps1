#Requires -Version 7.0
<#
.SYNOPSIS
    Creates Administrative Units and assigns scoped Intune Administrator roles to student admin accounts.

.DESCRIPTION
    This script creates Administrative Units (ST1, ST2, ST3, etc.) in Microsoft Entra ID and:
    - Adds student admin accounts (admin1@, admin2@, etc.) to their respective AUs
    - Adds student user accounts (W365Student1@, W365Student2@, etc.) to their respective AUs
    - Assigns Intune Administrator role scoped to each AU (admin only)
    This enables delegated administration where each student admin can only manage users and resources
    within their assigned administrative unit.

.PARAMETER TenantId
    Azure AD tenant ID (optional - will prompt if not provided)

.PARAMETER StudentCount
    Number of student administrative units to create (default: 30)
    Creates ST1 through ST{StudentCount}

.PARAMETER Domain
    Domain for student admin accounts (default: bighatgrouptraining.ca)

.EXAMPLE
    .\3_AdministrativeUnits.ps1
    Interactive mode: Creates 30 administrative units (ST1-ST30) with scoped Intune Admin roles

.EXAMPLE
    .\3_AdministrativeUnits.ps1 -StudentCount 10
    Creates 10 administrative units (ST1-ST10) with scoped roles

.EXAMPLE
    .\3_AdministrativeUnits.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -StudentCount 25
    Automated mode: Creates 25 administrative units for specific tenant

.NOTES
    Requires:
    - PowerShell 7.0 or newer
    - Microsoft.Graph.Identity.DirectoryManagement module
    - Microsoft.Graph.Authentication module
    - Global Administrator or Privileged Role Administrator permissions
    
    Created: 2025-11-09
    Author: OpenSpec automation
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$StudentCount = 30,
    
    [Parameter(Mandatory = $false)]
    [string]$Domain = "bighatgrouptraining.ca"
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Logging Setup
# ============================================================================

$timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
$documentsPath = [Environment]::GetFolderPath("MyDocuments")
$logFile = Join-Path $documentsPath "AdministrativeUnits-$timestamp.log"

function Write-LogMessage {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Info"    { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
    }
    
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console
    Write-Host $logEntry -ForegroundColor $color
    
    # Write to log file
    $logEntry | Out-File -FilePath $script:logFile -Append -Encoding UTF8
}

# ============================================================================
# Main Script
# ============================================================================

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Administrative Units Setup" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Log file: $logFile" -ForegroundColor Gray
Write-Host "Creating $StudentCount administrative units`n" -ForegroundColor Gray

Write-LogMessage "Script started" -Level Info
Write-LogMessage "Parameters: StudentCount=$StudentCount, Domain=$Domain" -Level Info

# Step 1: Verify required modules
Write-Host "[1/4] Verifying required PowerShell modules..." -ForegroundColor Yellow

$requiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Identity.DirectoryManagement"
)

foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Write-LogMessage "ERROR: Required module not found: $moduleName" -Level Error
        Write-Host "`n  Please install missing modules with:" -ForegroundColor Red
        Write-Host "  Install-Module $moduleName -Scope CurrentUser`n" -ForegroundColor Yellow
        exit 1
    }
    Import-Module $moduleName -ErrorAction Stop
    Write-LogMessage "Module loaded: $moduleName" -Level Info
}

Write-Host "  ✓ All required modules are installed`n" -ForegroundColor Green

# Step 2: Connect to Microsoft Graph
Write-Host "[2/4] Connecting to Microsoft Graph..." -ForegroundColor Yellow
Write-Host "`n  ⚠️  Microsoft Graph Authentication Required" -ForegroundColor Yellow
Write-Host "  Scopes needed: AdministrativeUnit.ReadWrite.All, RoleManagement.ReadWrite.Directory`n" -ForegroundColor Gray

try {
    $connectParams = @{
        Scopes = @(
            "AdministrativeUnit.ReadWrite.All",
            "RoleManagement.ReadWrite.Directory",
            "Directory.Read.All"
        )
        NoWelcome = $true
    }
    
    if ($TenantId) {
        $connectParams.TenantId = $TenantId
    }
    
    Connect-MgGraph @connectParams -ErrorAction Stop | Out-Null
    $context = Get-MgContext
    Write-LogMessage "Connected to Microsoft Graph successfully" -Level Success
    Write-LogMessage "Tenant ID: $($context.TenantId)" -Level Info
    Write-Host "  ✓ Graph authentication complete`n" -ForegroundColor Green
}
catch {
    Write-LogMessage "ERROR: Failed to connect to Microsoft Graph" -Level Error
    Write-LogMessage $_.Exception.Message -Level Error
    exit 1
}

# Step 3: Get Groups Administrator role template
Write-Host "[3/4] Configuring User Administrator role..." -ForegroundColor Yellow

try {
    Write-LogMessage "Getting User Administrator role template..." -Level Info
    # Get all templates and filter locally (API doesn't support filter parameter)
    $allTemplates = Get-MgDirectoryRoleTemplate -All -ErrorAction Stop
    $userAdminRoleTemplate = $allTemplates | Where-Object { $_.DisplayName -eq 'User Administrator' }
    
    if (-not $userAdminRoleTemplate) {
        Write-LogMessage "ERROR: User Administrator role template not found" -Level Error
        exit 1
    }
    
    Write-LogMessage "Found User Administrator role template: $($userAdminRoleTemplate.Id)" -Level Success
    
    # Check if role is activated (get all and filter locally)
    $allRoles = Get-MgDirectoryRole -All -ErrorAction SilentlyContinue
    $userAdminRole = $allRoles | Where-Object { $_.RoleTemplateId -eq $userAdminRoleTemplate.Id }
    
    if (-not $userAdminRole) {
        Write-LogMessage "Activating User Administrator role..." -Level Info
        $userAdminRole = New-MgDirectoryRole -RoleTemplateId $userAdminRoleTemplate.Id -ErrorAction Stop
        Write-LogMessage "User Administrator role activated" -Level Success
    }
    else {
        Write-LogMessage "User Administrator role already activated" -Level Info
    }
    
    Write-Host "  ✓ User Administrator role ready`n" -ForegroundColor Green
}
catch {
    Write-LogMessage "ERROR: Failed to configure Groups Administrator role" -Level Error
    Write-LogMessage $_.Exception.Message -Level Error
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    exit 1
}

# Step 4: Create Administrative Units and assign roles
Write-Host "[4/4] Creating administrative units and assigning scoped roles..." -ForegroundColor Yellow
Write-LogMessage "Creating $StudentCount administrative units (AU-Student1-AU-Student$StudentCount)" -Level Info

$successCount = 0
$results = @()

for ($i = 1; $i -le $StudentCount; $i++) {
    $auName = "AU-Student$i"
    $adminUPN = "admin$i@$Domain"
    
    Write-Host "`n  Processing $auName..." -ForegroundColor Cyan
    Write-LogMessage "Processing administrative unit: $auName for $adminUPN" -Level Info
    
    try {
        # Check if AU already exists
        # Get all AUs and filter locally to avoid potential API filter issues
        $allAUs = Get-MgDirectoryAdministrativeUnit -All -ErrorAction SilentlyContinue
        $existingAU = $allAUs | Where-Object { $_.DisplayName -eq $auName }
        
        if ($existingAU) {
            Write-LogMessage "Administrative unit already exists: $auName" -Level Info
            $au = $existingAU
        }
        else {
            # Create Administrative Unit
            Write-LogMessage "Creating administrative unit: $auName" -Level Info
            $auParams = @{
                DisplayName = $auName
                Description = "Pod isolation AU for Student $i (admin + user + group)"
                Visibility = "HiddenMembership"
            }
            
            $au = New-MgDirectoryAdministrativeUnit -BodyParameter $auParams -ErrorAction Stop
            Write-LogMessage "Created administrative unit: $auName (ID: $($au.Id))" -Level Success
            Write-Host "    ✓ Created AU: $auName" -ForegroundColor Green
        }
        
        # Get admin user (AU-scoped roles can only be assigned to users, not groups)
        Write-LogMessage "Looking up admin user: $adminUPN" -Level Info
        $adminUser = Get-MgUser -Filter "userPrincipalName eq '$adminUPN'" -ErrorAction SilentlyContinue
        
        if (-not $adminUser) {
            Write-LogMessage "WARNING: Admin user not found: $adminUPN - Skipping" -Level Warning
            Write-Host "    ⚠️  Admin user not found: $adminUPN" -ForegroundColor Yellow
            continue
        }
        
        Write-LogMessage "Found admin user: $adminUPN (ID: $($adminUser.Id))" -Level Info
        
        # Add corresponding student user to AU
        $studentUPN = "W365Student$i@$Domain"
        Write-LogMessage "Looking up student user: $studentUPN" -Level Info
        $studentUser = Get-MgUser -Filter "userPrincipalName eq '$studentUPN'" -ErrorAction SilentlyContinue
        
        if ($studentUser) {
            Write-LogMessage "Found student user: $studentUPN (ID: $($studentUser.Id))" -Level Info
            
            # Check if student is already a member
            $existingStudentMember = Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id -ErrorAction SilentlyContinue | 
                Where-Object { $_.Id -eq $studentUser.Id }
            
            if (-not $existingStudentMember) {
                # Add student to AU
                $studentMemberRef = @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($studentUser.Id)"
                }
                New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId $au.Id -BodyParameter $studentMemberRef -ErrorAction Stop | Out-Null
                Write-LogMessage "Added student user to administrative unit: $studentUPN" -Level Success
                Write-Host "    ✓ Added student member: $studentUPN" -ForegroundColor Green
            }
            else {
                Write-LogMessage "Student user already member of administrative unit: $studentUPN" -Level Info
                Write-Host "    • Student already member: $studentUPN" -ForegroundColor Gray
            }
        }
        else {
            Write-LogMessage "WARNING: Student user not found: $studentUPN - Skipping student addition" -Level Warning
            Write-Host "    ⚠️  Student not found: $studentUPN" -ForegroundColor Yellow
        }
        
        # Add SG-Student{N}-Users group to AU
        $usersGroupName = "SG-Student$i-Users"
        Write-LogMessage "Looking up users group: $usersGroupName" -Level Info
        $usersGroup = Get-MgGroup -Filter "displayName eq '$usersGroupName'" -ErrorAction SilentlyContinue
        
        if ($usersGroup) {
            Write-LogMessage "Found users group: $usersGroupName (ID: $($usersGroup.Id))" -Level Info
            
            # Check if users group is already a member
            $existingUsersGroupMember = Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $au.Id -ErrorAction SilentlyContinue | 
                Where-Object { $_.Id -eq $usersGroup.Id }
            
            if (-not $existingUsersGroupMember) {
                # Add users group to AU
                $usersGroupMemberRef = @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($usersGroup.Id)"
                }
                New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId $au.Id -BodyParameter $usersGroupMemberRef -ErrorAction Stop | Out-Null
                Write-LogMessage "Added users group to administrative unit: $usersGroupName" -Level Success
                Write-Host "    ✓ Added users group: $usersGroupName" -ForegroundColor Green
            }
            else {
                Write-LogMessage "Users group already member of administrative unit: $usersGroupName" -Level Info
                Write-Host "    • Users group already member: $usersGroupName" -ForegroundColor Gray
            }
        }
        else {
            Write-LogMessage "WARNING: Users group not found: $usersGroupName - Skipping group addition" -Level Warning
            Write-Host "    ⚠️  Users group not found: $usersGroupName" -ForegroundColor Yellow
        }
        
        # Assign scoped User Administrator role to admin user (AU-scoped roles require direct user assignment)
        Write-LogMessage "Assigning scoped User Administrator role to admin user..." -Level Info
        
        # Check if scoped role assignment already exists for the user
        $existingScopedRole = Get-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $au.Id -ErrorAction SilentlyContinue |
            Where-Object { $_.RoleMemberInfo.Id -eq $adminUser.Id -and $_.RoleId -eq $userAdminRole.Id }
        
        if (-not $existingScopedRole) {
            $scopedRoleParams = @{
                RoleId = $userAdminRole.Id
                RoleMemberInfo = @{
                    Id = $adminUser.Id
                }
            }
            
            New-MgDirectoryAdministrativeUnitScopedRoleMember -AdministrativeUnitId $au.Id -BodyParameter $scopedRoleParams -ErrorAction Stop | Out-Null
            Write-LogMessage "Assigned scoped User Administrator role to $adminUPN in $auName" -Level Success
            Write-Host "    ✓ Assigned scoped role: User Administrator to user" -ForegroundColor Green
        }
        else {
            Write-LogMessage "Scoped role already assigned to user: $adminUPN in $auName" -Level Info
            Write-Host "    • Role already assigned to user" -ForegroundColor Gray
        }
        
        $successCount++
        $results += [PSCustomObject]@{
            AdministrativeUnit = $auName
            AdminUPN = $adminUPN
            StudentUPN = $studentUPN
            Status = "Success"
        }
    }
    catch {
        Write-LogMessage "ERROR: Failed to process $auName : $($_.Exception.Message)" -Level Error
        Write-Host "    ✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
        $results += [PSCustomObject]@{
            AdministrativeUnit = $auName
            AdminUPN = $adminUPN
            StudentUPN = "W365Student$i@$Domain"
            Status = "Failed: $($_.Exception.Message)"
        }
    }
}

# Disconnect from Graph
Write-LogMessage "Disconnecting from Microsoft Graph..." -Level Info
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

# Display summary
Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Administrative Units Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Total AUs:           $StudentCount" -ForegroundColor White
Write-Host "  Successful:          $successCount" -ForegroundColor Green
Write-Host "  Failed:              $($StudentCount - $successCount)" -ForegroundColor $(if ($successCount -eq $StudentCount) { "Green" } else { "Yellow" })
Write-Host "==========================================" -ForegroundColor Cyan

if ($successCount -eq $StudentCount) {
    Write-Host "`n✓ All administrative units configured successfully!" -ForegroundColor Green
}
else {
    Write-Host "`n⚠️  Some administrative units failed - check log for details" -ForegroundColor Yellow
}

Write-Host "`n📋 Configuration Details:" -ForegroundColor Cyan
Write-Host "  • Each student has dedicated AU (AU-Student1, AU-Student2, etc.)" -ForegroundColor White
Write-Host "  • AU members: W365Student{N}@ user + SG-Student{N}-Users group" -ForegroundColor White
Write-Host "  • User Administrator role scoped to AU and assigned to admin{N}@ user" -ForegroundColor White
Write-Host "  • Enables: password reset and group membership management" -ForegroundColor White
Write-Host "  • Hidden membership enabled for privacy" -ForegroundColor White
Write-Host "  • NOTE: Intune management is handled by custom role (see 4_IntuneCustomRole.ps1)" -ForegroundColor Yellow

Write-Host "`n📄 Files created:" -ForegroundColor Cyan
Write-Host "  Log: $logFile" -ForegroundColor White

Write-LogMessage "Script execution completed successfully" -Level Success
Write-LogMessage "Administrative units created: $successCount/$StudentCount" -Level Info
Write-LogMessage "Log file: $logFile" -Level Info

Write-Host ""
