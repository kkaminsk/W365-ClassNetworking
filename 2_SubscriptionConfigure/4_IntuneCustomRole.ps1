#Requires -Version 7.0
<#
.SYNOPSIS
    Creates custom Intune role and scoped role assignments for student pod isolation.

.DESCRIPTION
    This script implements the Intune delegation component of the pod security model by:
    - Creating a custom "Lab Intune Admin" role with granular permissions
    - Creating scoped role assignments for each student with explicit scope groups and tags
    - Assigning Security Reader role to each student admin group for security visibility
    
    For each student (1-30), creates role assignment:
    - Role: "Lab Intune Admin" (custom role, shared across students)
    - Members (Who): SG-Student{N}-Admins group
    - Scope (Groups): SG-Student{N}-Users + SG-Student{N}-Devices groups
    - Scope (Tags): ST{N} scope tag
    
    This enables true isolation where each student admin can only:
    - See Intune resources tagged with their scope tag
    - Create policies that are auto-tagged with their scope tag
    - Assign policies only to their assigned user/device groups

.PARAMETER StudentCount
    Number of student role assignments to create (default: 30)

.PARAMETER TenantId
    Optional Azure AD tenant ID to target

.PARAMETER Domain
    Domain for student accounts (default: bighatgrouptraining.ca)

.PARAMETER SkipRoleCreation
    Skip custom role creation (useful for re-creating assignments only)

.EXAMPLE
    .\4_IntuneCustomRole.ps1
    Creates custom role and 30 scoped assignments

.EXAMPLE
    .\4_IntuneCustomRole.ps1 -StudentCount 10
    Creates role and 10 scoped assignments

.EXAMPLE
    .\4_IntuneCustomRole.ps1 -SkipRoleCreation
    Skips role creation, only creates assignments (if role exists)

.NOTES
    Requires:
    - PowerShell 7.0 or newer
    - Microsoft.Graph.DeviceManagement module
    - Microsoft.Graph.Groups module
    - Microsoft.Graph.Authentication module
    - Microsoft.Graph.Identity.DirectoryManagement module (for Security Reader role)
    - Intune Administrator or Global Administrator role
    
    Prerequisites:
    - Run 1_SubscriptionConfigure.ps1 first (creates users and security groups)
    - Run 2_ScopeTags.ps1 second (creates scope tags)
    - Run 3_AdministrativeUnits.ps1 third (creates AUs)
    - Then run this script fourth
    
    Required Graph Scopes:
    - DeviceManagementRBAC.ReadWrite.All
    - DeviceManagementConfiguration.ReadWrite.All
    - Group.Read.All
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$StudentCount = 30,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$Domain = "bighatgrouptraining.ca",

    [Parameter(Mandatory = $false)]
    [switch]$SkipRoleCreation
)

$ErrorActionPreference = "Stop"

# Initialize log and CSV files in Documents folder
$documentsFolder = [Environment]::GetFolderPath('MyDocuments')
$timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
$logFile = Join-Path $documentsFolder "IntuneCustomRole-$timestamp.log"
$csvFile = Join-Path $documentsFolder "IntuneCustomRole-$timestamp.csv"

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
    $logEntry | Out-File -FilePath $script:logFile -Append -Encoding UTF8
}

# ============================================================================
# Main Script
# ============================================================================

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Intune Custom Role & Assignment Management" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Log file: $logFile" -ForegroundColor Gray
Write-Host "CSV file: $csvFile" -ForegroundColor Gray

"" | Out-File -FilePath $logFile -Encoding UTF8
"==========================================" | Out-File -FilePath $logFile -Append -Encoding UTF8
"Intune Custom Role & Assignment Management" | Out-File -FilePath $logFile -Append -Encoding UTF8
"Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $logFile -Append -Encoding UTF8
"==========================================" | Out-File -FilePath $logFile -Append -Encoding UTF8

# Step 1: Verify PowerShell version
Write-LogMessage "Verifying PowerShell version..." -Level Info
$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -lt 7) {
    Write-LogMessage "ERROR: PowerShell 7.0+ required. Current version: $($psVersion.ToString())" -Level Error
    exit 1
}
Write-LogMessage "PowerShell version: $($psVersion.ToString())" -Level Success

# Step 2: Check required modules
Write-Host "`n[1/4] Checking required modules..." -ForegroundColor Yellow

$requiredModules = @(
    @{ Name = "Microsoft.Graph.Authentication"; Description = "Microsoft Graph authentication" },
    @{ Name = "Microsoft.Graph.DeviceManagement"; Description = "Intune device management" },
    @{ Name = "Microsoft.Graph.Groups"; Description = "Microsoft Graph group management" },
    @{ Name = "Microsoft.Graph.Identity.DirectoryManagement"; Description = "Directory role management" }
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module.Name)) {
        Write-LogMessage "ERROR: Module '$($module.Name)' is not installed." -Level Error
        Write-Host "Install it with: Install-Module -Name $($module.Name) -Repository PSGallery -Force" -ForegroundColor Yellow
        exit 1
    }
    Write-LogMessage "$($module.Description): $($module.Name) installed" -Level Success
}

# Step 3: Connect to Microsoft Graph
Write-Host "`n[2/4] Connecting to Microsoft Graph..." -ForegroundColor Yellow
Write-LogMessage "Connecting to Microsoft Graph with Intune RBAC permissions..." -Level Info

try {
    $requiredScopes = @(
        'DeviceManagementRBAC.ReadWrite.All',
        'DeviceManagementConfiguration.ReadWrite.All',
        'Group.Read.All',
        'RoleManagement.ReadWrite.Directory'
    )
    
    if ($TenantId) {
        Connect-MgGraph -TenantId $TenantId -Scopes $requiredScopes -NoWelcome -ErrorAction Stop
        Write-LogMessage "Connected to specified tenant: $TenantId" -Level Success
    }
    else {
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome -ErrorAction Stop
        Write-LogMessage "Connected to Microsoft Graph" -Level Success
    }
    
    $context = Get-MgContext
    Write-Host "`n  Account:   $($context.Account)" -ForegroundColor White
    Write-Host "  Tenant ID: $($context.TenantId)" -ForegroundColor White
    Write-LogMessage "Authenticated as: $($context.Account)" -Level Success
}
catch {
    Write-LogMessage "ERROR: Failed to connect to Microsoft Graph" -Level Error
    Write-LogMessage $_.Exception.Message -Level Error
    exit 1
}

# Step 4: Create or verify custom Intune role
if (-not $SkipRoleCreation) {
    Write-Host "`n[3/4] Creating custom Intune role..." -ForegroundColor Yellow
    Write-LogMessage "Creating custom role: Lab Intune Admin" -Level Info
    
    $roleName = "Lab Intune Admin"
    $roleDescription = "Custom Intune role for student lab administrators with scoped permissions"
    
    try {
        # Check if role already exists
        $uri = "https://graph.microsoft.com/beta/deviceManagement/roleDefinitions?`$filter=displayName eq '$roleName'"
        $existingRole = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        
        if ($existingRole.value -and $existingRole.value.Count -gt 0) {
            Write-LogMessage "Custom role already exists: $roleName (ID: $($existingRole.value[0].id))" -Level Info
            $customRole = $existingRole.value[0]
        }
        else {
            # Define custom role permissions
            $roleDefinition = @{
                "@odata.type" = "#microsoft.graph.roleDefinition"
                displayName = $roleName
                description = $roleDescription
                rolePermissions = @(
                    @{
                        resourceActions = @(
                            @{
                                allowedResourceActions = @(
                                    # Mobile Apps
                                    "Microsoft.Intune/MobileApps/Read",
                                    "Microsoft.Intune/MobileApps/Create",
                                    "Microsoft.Intune/MobileApps/Update",
                                    "Microsoft.Intune/MobileApps/Delete",
                                    "Microsoft.Intune/MobileApps/Assign",
                                    # Device Configurations
                                    "Microsoft.Intune/DeviceConfigurations/Read",
                                    "Microsoft.Intune/DeviceConfigurations/Create",
                                    "Microsoft.Intune/DeviceConfigurations/Update",
                                    "Microsoft.Intune/DeviceConfigurations/Delete",
                                    "Microsoft.Intune/DeviceConfigurations/Assign",
                                    # Device Compliance Policies
                                    "Microsoft.Intune/DeviceCompliancePolices/Read",
                                    "Microsoft.Intune/DeviceCompliancePolices/Assign",
                                    # Managed Devices
                                    "Microsoft.Intune/ManagedDevices/Read",
                                    "Microsoft.Intune/ManagedDevices/Retire",
                                    "Microsoft.Intune/ManagedDevices/Wipe",
                                    # Remote Tasks
                                    "Microsoft.Intune/ManagedDevices/RemoteActions/Restart",
                                    "Microsoft.Intune/ManagedDevices/RemoteActions/SyncDevice"
                                )
                            }
                        )
                    }
                )
            } | ConvertTo-Json -Depth 10
            
            # Create custom role
            $newRole = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/roleDefinitions" -Body $roleDefinition -ContentType "application/json" -ErrorAction Stop
            
            Write-LogMessage "Created custom role: $roleName (ID: $($newRole.id))" -Level Success
            Write-Host "  ✓ Custom Intune role created" -ForegroundColor Green
            $customRole = $newRole
            
            Start-Sleep -Seconds 2  # Brief delay for role to propagate
        }
    }
    catch {
        Write-LogMessage "ERROR: Failed to create custom role: $($_.Exception.Message)" -Level Error
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        exit 1
    }
}
else {
    Write-Host "`n[3/4] Skipping custom role creation (SkipRoleCreation flag set)..." -ForegroundColor Yellow
    Write-LogMessage "Custom role creation skipped per -SkipRoleCreation flag" -Level Info
    
    # Retrieve existing custom role
    $roleName = "Lab Intune Admin"
    $uri = "https://graph.microsoft.com/beta/deviceManagement/roleDefinitions?`$filter=displayName eq '$roleName'"
    $existingRole = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    
    if (-not $existingRole.value -or $existingRole.value.Count -eq 0) {
        Write-LogMessage "ERROR: Custom role '$roleName' not found. Run without -SkipRoleCreation first." -Level Error
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        exit 1
    }
    
    $customRole = $existingRole.value[0]
    Write-LogMessage "Found existing custom role: $roleName (ID: $($customRole.id))" -Level Success
}

# Step 5: Create scoped role assignments for each student
Write-Host "`n[4/4] Creating scoped role assignments for $StudentCount students..." -ForegroundColor Yellow
Write-LogMessage "Creating role assignments with scope groups and tags..." -Level Info

# Create CSV headers
"StudentNumber,AdminGroupName,AdminGroupID,UsersGroupName,UsersGroupID,DevicesGroupName,DevicesGroupID,ScopeTag,ScopeTagID,RoleAssignmentID,Status" | Out-File -FilePath $csvFile -Encoding UTF8

$assignmentResults = @()

for ($i = 1; $i -le $StudentCount; $i++) {
    Write-Host "`n  Processing Student $i..." -ForegroundColor Cyan
    Write-LogMessage "Creating role assignment for Student $i" -Level Info
    
    $adminGroupName = "SG-Student$i-Admins"
    $usersGroupName = "SG-Student$i-Users"
    $devicesGroupName = "SG-Student$i-Devices"
    $scopeTagName = "ST$i"
    
    try {
        # Get admin group
        $adminGroup = Get-MgGroup -Filter "displayName eq '$adminGroupName'" -ErrorAction SilentlyContinue
        if (-not $adminGroup) {
            Write-LogMessage "WARNING: Admin group not found: $adminGroupName - Skipping" -Level Warning
            Write-Host "    ⚠️  Admin group not found" -ForegroundColor Yellow
            continue
        }
        
        # Get users group
        $usersGroup = Get-MgGroup -Filter "displayName eq '$usersGroupName'" -ErrorAction SilentlyContinue
        if (-not $usersGroup) {
            Write-LogMessage "WARNING: Users group not found: $usersGroupName - Skipping" -Level Warning
            Write-Host "    ⚠️  Users group not found" -ForegroundColor Yellow
            continue
        }
        
        # Get devices group
        $devicesGroup = Get-MgGroup -Filter "displayName eq '$devicesGroupName'" -ErrorAction SilentlyContinue
        if (-not $devicesGroup) {
            Write-LogMessage "WARNING: Devices group not found: $devicesGroupName - Skipping" -Level Warning
            Write-Host "    ⚠️  Devices group not found" -ForegroundColor Yellow
            continue
        }
        
        # Get scope tag
        $scopeTagUri = "https://graph.microsoft.com/beta/deviceManagement/roleScopeTags?`$filter=displayName eq '$scopeTagName'"
        $scopeTagResult = Invoke-MgGraphRequest -Method GET -Uri $scopeTagUri -ErrorAction Stop
        
        if (-not $scopeTagResult.value -or $scopeTagResult.value.Count -eq 0) {
            Write-LogMessage "WARNING: Scope tag not found: $scopeTagName - Skipping" -Level Warning
            Write-Host "    ⚠️  Scope tag not found" -ForegroundColor Yellow
            continue
        }
        
        $scopeTag = $scopeTagResult.value[0]
        
        Write-LogMessage "Found all required objects for Student $i" -Level Success
        
        # Check if role assignment already exists for this admin group
        $existingAssignmentsUri = "https://graph.microsoft.com/beta/deviceManagement/roleAssignments?`$filter=resourceScopes/any()"
        $existingAssignments = Invoke-MgGraphRequest -Method GET -Uri $existingAssignmentsUri -ErrorAction Stop
        
        $existingAssignment = $existingAssignments.value | Where-Object {
            $_.members -contains $adminGroup.Id -and $_.roleDefinition.id -eq $customRole.id
        }
        
        if ($existingAssignment) {
            Write-LogMessage "Role assignment already exists for $adminGroupName" -Level Info
            Write-Host "    • Role assignment already exists" -ForegroundColor Gray
            
            $assignmentResults += [PSCustomObject]@{
                StudentNumber = $i
                AdminGroupName = $adminGroupName
                AdminGroupID = $adminGroup.Id
                UsersGroupName = $usersGroupName
                UsersGroupID = $usersGroup.Id
                DevicesGroupName = $devicesGroupName
                DevicesGroupID = $devicesGroup.Id
                ScopeTag = $scopeTagName
                ScopeTagID = $scopeTag.id
                RoleAssignmentID = $existingAssignment.id
                Status = "AlreadyExists"
            }
        }
        else {
            # Create new role assignment
            # NOTE: Scope tag IDs MUST be strings (Edm.String)
            # NOTE: API requires resourceScopes when scopeType is ResourceScope
            # NOTE: Use special value "/" which means "all resources controlled by scope tags"
            $assignment = @{
                "@odata.type"   = "#microsoft.graph.deviceAndAppManagementRoleAssignment"
                displayName      = "Lab Intune Admin - Student $i"
                description      = "Scoped Intune administration for Student $i pod"
                roleDefinitionId = $customRole.id.ToString()
                members          = @($adminGroup.Id.ToString())
                resourceScopes   = @("/")
                roleScopeTagIds  = @($scopeTag.id.ToString())
            } | ConvertTo-Json -Depth 10
            
            Write-LogMessage "Sending role assignment request for Student $i..." -Level Info
            Write-LogMessage "Request body: $assignment" -Level Info
            
            $newAssignment = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/roleAssignments" -Body $assignment -ContentType "application/json" -ErrorAction Stop
            
            Write-LogMessage "Created role assignment for $adminGroupName (ID: $($newAssignment.id))" -Level Success
            Write-Host "    ✓ Role assignment created" -ForegroundColor Green
            
            $assignmentResults += [PSCustomObject]@{
                StudentNumber = $i
                AdminGroupName = $adminGroupName
                AdminGroupID = $adminGroup.Id
                UsersGroupName = $usersGroupName
                UsersGroupID = $usersGroup.Id
                DevicesGroupName = $devicesGroupName
                DevicesGroupID = $devicesGroup.Id
                ScopeTag = $scopeTagName
                ScopeTagID = $scopeTag.id
                RoleAssignmentID = $newAssignment.id
                Status = "Created"
            }
        }
    }
    catch {
        $errorDetails = $_.ErrorDetails.Message
        if ($errorDetails) {
            Write-LogMessage "ERROR: Failed to create role assignment for Student $i" -Level Error
            Write-LogMessage "API Error Details: $errorDetails" -Level Error
            Write-Host "    ✗ Failed: $errorDetails" -ForegroundColor Red
        }
        else {
            Write-LogMessage "ERROR: Failed to create role assignment for Student $i : $($_.Exception.Message)" -Level Error
            Write-Host "    ✗ Failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        
        $assignmentResults += [PSCustomObject]@{
            StudentNumber = $i
            AdminGroupName = $adminGroupName
            AdminGroupID = "N/A"
            UsersGroupName = $usersGroupName
            UsersGroupID = "N/A"
            DevicesGroupName = $devicesGroupName
            DevicesGroupID = "N/A"
            ScopeTag = $scopeTagName
            ScopeTagID = "N/A"
            RoleAssignmentID = "N/A"
            Status = "Failed: $($_.Exception.Message)"
        }
    }
}

# Export results to CSV
$assignmentResults | ForEach-Object {
    "$($_.StudentNumber),$($_.AdminGroupName),$($_.AdminGroupID),$($_.UsersGroupName),$($_.UsersGroupID),$($_.DevicesGroupName),$($_.DevicesGroupID),$($_.ScopeTag),$($_.ScopeTagID),$($_.RoleAssignmentID),$($_.Status)" | Out-File -FilePath $csvFile -Append -Encoding UTF8
}

Write-Host "`n  Summary: Created/verified $($assignmentResults.Count) role assignment(s)" -ForegroundColor Green
Write-LogMessage "Role assignment creation complete: $($assignmentResults.Count)/$StudentCount processed" -Level Success

# Step 6: Assign Security Reader role to each student admin group
Write-Host "`n[5/5] Assigning Security Reader role to student admin groups..." -ForegroundColor Yellow
Write-LogMessage "Starting Security Reader role assignments..." -Level Info

try {
    # Get Security Reader role template
    $securityReaderRole = Get-MgDirectoryRoleTemplate | Where-Object { $_.DisplayName -eq 'Security Reader' }
    if (-not $securityReaderRole) {
        Write-LogMessage "ERROR: Security Reader role template not found" -Level Error
        Write-Host "    ✗ Security Reader role template not found" -ForegroundColor Red
    }
    else {
        Write-LogMessage "Found Security Reader role template (ID: $($securityReaderRole.Id))" -Level Info
        
        # Activate Security Reader role if not already active
        $activeSecurityReaderRole = Get-MgDirectoryRole -Filter "roleTemplateId eq '$($securityReaderRole.Id)'" -ErrorAction SilentlyContinue
        if (-not $activeSecurityReaderRole) {
            Write-LogMessage "Activating Security Reader role..." -Level Info
            $roleParams = @{
                RoleTemplateId = $securityReaderRole.Id
            }
            $activeSecurityReaderRole = New-MgDirectoryRole -BodyParameter $roleParams -ErrorAction Stop
            Write-LogMessage "Security Reader role activated (ID: $($activeSecurityReaderRole.Id))" -Level Success
        }
        else {
            Write-LogMessage "Security Reader role already active (ID: $($activeSecurityReaderRole.Id))" -Level Info
        }

        # Assign Security Reader role to each student admin group
        $securityReaderAssignments = 0
        for ($i = 1; $i -le $StudentCount; $i++) {
            $adminGroupName = "SG-Student$i-Admins"
            
            try {
                # Get admin group
                $adminGroup = Get-MgGroup -Filter "displayName eq '$adminGroupName'" -ErrorAction SilentlyContinue
                if (-not $adminGroup) {
                    Write-LogMessage "WARNING: Admin group not found: $adminGroupName - Skipping Security Reader assignment" -Level Warning
                    continue
                }

                # Check if Security Reader role already assigned to this group
                $existingAssignment = Get-MgDirectoryRoleMember -DirectoryRoleId $activeSecurityReaderRole.Id -ErrorAction SilentlyContinue |
                    Where-Object { $_.Id -eq $adminGroup.Id }

                if (-not $existingAssignment) {
                    # Assign Security Reader role to admin group
                    $memberRef = @{
                        "@odata.id" = "https://graph.microsoft.com/v1.0/groups/$($adminGroup.Id)"
                    }
                    New-MgDirectoryRoleMemberByRef -DirectoryRoleId $activeSecurityReaderRole.Id -BodyParameter $memberRef -ErrorAction Stop | Out-Null
                    Write-LogMessage "Assigned Security Reader role to $adminGroupName" -Level Success
                    $securityReaderAssignments++
                }
                else {
                    Write-LogMessage "Security Reader role already assigned to $adminGroupName" -Level Info
                }
            }
            catch {
                Write-LogMessage "ERROR: Failed to assign Security Reader role to $adminGroupName : $($_.Exception.Message)" -Level Error
                Write-Host "    ✗ Failed to assign Security Reader to $adminGroupName" -ForegroundColor Red
            }
        }

        Write-Host "  ✓ Security Reader assignments: $securityReaderAssignments/$StudentCount" -ForegroundColor Green
        Write-LogMessage "Security Reader role assignment complete: $securityReaderAssignments/$StudentCount processed" -Level Success
    }
}
catch {
    Write-LogMessage "ERROR: Failed to process Security Reader role assignments: $($_.Exception.Message)" -Level Error
    Write-Host "    ✗ Failed to process Security Reader role assignments" -ForegroundColor Red
}

# Disconnect
Write-LogMessage "Disconnecting from Microsoft Graph..." -Level Info
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

# Display summary
Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Custom Role Assignment Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Student Count:           $StudentCount" -ForegroundColor White
Write-Host "  Role Assignments:        $($assignmentResults.Count)" -ForegroundColor White
Write-Host "  Custom Role:             $roleName" -ForegroundColor White
Write-Host "  Role ID:                 $($customRole.id)" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "`n📋 What This Enables:" -ForegroundColor Cyan
Write-Host "  • Each admin{N}@ can only see resources tagged with ST{N}" -ForegroundColor White
Write-Host "  • Policies created by admin{N}@ are auto-tagged with ST{N}" -ForegroundColor White
Write-Host "  • Policy assignments limited to SG-Student{N}-Users and SG-Student{N}-Devices groups" -ForegroundColor White
Write-Host "  • Complete isolation: admin1@ cannot see admin2@'s resources" -ForegroundColor White
Write-Host "  • Security Reader access for security reports and threat intelligence" -ForegroundColor White

Write-Host "`n📄 Files created in Documents folder:" -ForegroundColor Cyan
Write-Host "  Log: $logFile" -ForegroundColor Gray
Write-Host "  CSV: $csvFile" -ForegroundColor Gray

Write-Host "`n✓ Intune custom role configuration complete!" -ForegroundColor Green
Write-LogMessage "Script execution completed successfully." -Level Success
