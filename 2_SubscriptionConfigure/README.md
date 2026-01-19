# Subscription Bootstrap Automation

## Overview

The `SubscriptionConfigure.ps1` script automates the preparation of the TechMentor lab tenant by provisioning standardized administrator accounts and configuring Azure RBAC permissions required for both Custom Image and Windows 365 spoke network deployments.

**Default Behavior**: Creates **2 main admin accounts + 30 student administrator accounts + 30 student accounts** (configurable via `-StudentCount` parameter).

### Output Files

All files are saved to your **Documents folder** (e.g., `C:\Users\YourName\Documents\`):

- **Log file**: `SubscriptionConfigure-YYYY-MM-DD-HH-MM.log` - Complete execution log with timestamps
- **CSV file**: `SubscriptionConfigure.csv` - Administrator credentials (UPN, password, creation date)
  - Headers are created on first run
  - New entries are appended on subsequent runs
  - **Secure this file**: Contains plaintext passwords

## Purpose

This script eliminates manual setup by:

- **Creating standardized admin accounts**: 
  - Admin account: `admin@bighatgrouptraining.ca` with Intune Administrator role
  - Backdoor account: `bdoor@bighatgrouptraining.ca` with Global Administrator role
- **Assigning directory roles**: Enables Windows 365 management and emergency access
- **Configuring Azure RBAC**: Creates and assigns custom roles for Custom Image and W365 deployments
- **Registering resource providers**: Ensures required Azure providers are available
- **Tenant selection support**: Interactive tenant and subscription selection

**Note**: This script does NOT create resource groups. The deployment scripts (`Deploy-W365Custom Image.ps1` and `deploy.ps1`) create resource groups in their preferred locations, and the RBAC roles configured here include permissions to create and manage those resource groups.

## Pod Security Model Architecture

This solution implements a **"pod" isolation model** where each student admin operates in a completely isolated environment. Each pod is a self-contained security boundary with dedicated users, groups, permissions, and scope tags.

### The Pod Structure (Per Student)

For each of 30 students, the system creates a complete isolation pod:

```
┌─────────────────────────────────────────────────────────────────────┐
│ Pod for Student 1 (admin1@ manages W365Student1@)                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ✓ Users (2):                                                        │
│    • admin1@bighatgrouptraining.ca (administrator)                  │
│    • W365Student1@bighatgrouptraining.ca (managed user)             │
│                                                                       │
│  ✓ Security Groups (3):                                             │
│    • SG-Student1-Admins → Contains admin1@                          │
│    • SG-Student1-Users → Contains W365Student1@                     │
│    • SG-Student1-Devices → Contains Student 1's Cloud PCs           │
│                                                                       │
│  ✓ Administrative Unit: AU-Student1                                 │
│    Members: W365Student1@ + SG-Student1-Users group                 │
│    Role: Groups Administrator (scoped to AU)                         │
│    Assigned To: SG-Student1-Admins group                            │
│    Purpose: Password reset + group management                        │
│                                                                       │
│  ✓ Intune Scope Tag: ST1                                            │
│    Auto-tags all policies created by admin1@                        │
│                                                                       │
│  ✓ Custom Intune Role Assignment:                                   │
│    Role: "Lab Intune Admin" (custom, not built-in)                 │
│    Members: SG-Student1-Admins group                                │
│    Scope (Groups): SG-Student1-Users + SG-Student1-Devices         │
│    Scope (Tags): ST1                                                │
│    Purpose: Create/manage Intune policies for assigned scope only   │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

**Pods 2-30** have identical structure with different names (admin2@, SG-Student2-*, AU-Student2, ST2, etc.)

### Multi-Layer Isolation

The pod model provides isolation at **three levels**:

| Layer | Mechanism | What It Controls | Admin Capability |
|-------|-----------|------------------|------------------|
| **Entra ID** | Administrative Unit + Groups Admin role | User visibility, password reset, group management | admin1@ can only see W365Student1@ and manage SG-Student1-Users membership |
| **Intune** | Custom role + Scope (Groups) + Scope (Tags) | Policy visibility, policy assignments, device management | admin1@ can only create/see policies tagged ST1, only assign to SG-Student1-Users/Devices |
| **Azure** | Azure RBAC roles scoped to resource groups | Azure resource deployment | All admins share Azure RBAC for image building and networking |

### How Isolation Works

**When admin1@ logs into Intune portal:**

1. **Policy Visibility:** Only sees policies/apps tagged with `ST1` (their scope tag)
2. **Policy Creation:** New policies auto-tagged with `ST1` (inherited from role assignment)
3. **Policy Assignment:** Assignment picker only shows `SG-Student1-Users` and `SG-Student1-Devices` groups
4. **Device Visibility:** Only sees Cloud PCs belonging to W365Student1@ (via scope tag)
5. **Cannot See:** admin2@'s policies, W365Student2@'s devices, or any ST2-tagged resources

**When admin1@ accesses Entra ID admin center:**

1. **User Visibility:** Only sees W365Student1@ (via AU membership)
2. **Password Reset:** Can reset W365Student1@'s password (via Groups Admin role)
3. **Group Management:** Can add/remove members from SG-Student1-Users (via Groups Admin role)
4. **Cannot See:** W365Student2@, admin2@, or any users outside AU-Student1

### Why Not Built-In Intune Administrator Role?

The built-in "Intune Administrator" role is **global** and cannot be properly scoped:
- ❌ Cannot limit to specific groups
- ❌ Cannot limit to specific scope tags  
- ❌ Admins see everything in tenant

The custom "Lab Intune Admin" role:
- ✅ Can be scoped per-student via role assignments
- ✅ Supports explicit Scope (Groups) and Scope (Tags)
- ✅ True isolation: admin1@ cannot see admin2@'s work

### Security Group Naming Convention

| Group Pattern | Purpose | Members | Used In |
|---------------|---------|---------|---------|
| `SG-Student{N}-Admins` | Admin identity | admin{N}@ | AU role assignment, Intune role assignment |
| `SG-Student{N}-Users` | Managed users | W365Student{N}@ | AU membership, Intune policy scope |
| `SG-Student{N}-Devices` | Managed devices | Cloud PC objects | Intune policy scope |

### Four-Script Workflow

The pod model requires **4 scripts run in sequence**:

1. **1_SubscriptionConfigure.ps1** → Creates users, groups, Azure RBAC
2. **2_ScopeTags.ps1** → Creates scope tags (ST1-ST30)
3. **3_AdministrativeUnits.ps1** → Creates AUs with Groups Administrator role
4. **4_IntuneCustomRole.ps1** → Creates custom role + scoped assignments

Each script builds on the previous, creating a complete isolation pod for each student.

## Prerequisites

### Required Software
- **PowerShell 7.0+** (mandatory)
- **Azure PowerShell modules**:
  - `Az.Accounts`
  - `Az.Resources`
- **Microsoft Graph PowerShell modules**:
  - `Microsoft.Graph.Users`
  - `Microsoft.Graph.Identity.DirectoryManagement`
  - `Microsoft.Graph.Authentication`

Install missing modules:
```powershell
Install-Module -Name Az.Accounts, Az.Resources -Repository PSGallery -Force
Install-Module -Name Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Authentication -Repository PSGallery -Force
```

### Required Permissions
- **Azure**: Owner or User Access Administrator at subscription level
- **Entra ID**: Global Administrator or Privileged Role Administrator

### Required Files
- `../CustomImage/CustomImage-MinimumRole.json` - Custom role definition for image building
- `../W365/W365-MinimumRole.json` - Custom role definition for spoke network deployment

## Usage

### Interactive Mode (Recommended for First Run)

```powershell
cd SubscriptionConfigure
.\1_SubscriptionConfigure.ps1
```

**Default**: Creates **2 main admins + 30 student admins + 30 students**.

**Note**: During login, Azure may show its own subscription selector with MFA warnings. **Press ESC or Cancel** to dismiss it and let the script handle tenant selection instead.

The script will:
1. List all accessible tenants
2. Prompt for tenant selection
3. List subscriptions in the selected tenant
4. Prompt for subscription selection
5. Create 2 main admin accounts (admin@ and bdoor@)
6. Create 30 student admin accounts (admin1@ through admin30@)
7. Create 30 student accounts (W365Student1@ through W365Student30@)
8. Assign all permissions and RBAC roles

### Automated Mode (CI/CD or Batch Processing)

```powershell
.\SubscriptionConfigure.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

**Tip**: Using `-TenantId` skips the Azure subscription selector entirely and avoids MFA warnings for other tenants.

### Custom Admin UPNs

```powershell
.\SubscriptionConfigure.ps1 -AdminUPN "instructor@bighatgrouptraining.ca" -BdoorUPN "backup@bighatgrouptraining.ca"
```

Use this to create admin accounts with custom UPNs.

### Default: Create 30 Students (Automatic)

```powershell
.\1_SubscriptionConfigure.ps1
```

Creates (default):
- 2 main admin accounts (`admin@` and `bdoor@`)
- **30 student admin accounts** (`admin1@` through `admin30@`) with Intune Administrator role
- **30 student accounts** (`W365Student1@` through `W365Student30@`) as regular users
- All Azure RBAC roles assigned to all admin accounts

All credentials are saved to the CSV file in your Documents folder.

### Create Different Number of Students

```powershell
# Create only 10 students
.\1_SubscriptionConfigure.ps1 -StudentCount 10

# Create 40 students
.\1_SubscriptionConfigure.ps1 -StudentCount 40

# Skip student creation (only create 2 main admins)
.\1_SubscriptionConfigure.ps1 -StudentCount 0
```

### Re-run RBAC Setup Only

```powershell
.\SubscriptionConfigure.ps1 -SkipUserCreation
```

### Test User Creation Only

```powershell
.\SubscriptionConfigure.ps1 -SkipRoleAssignments
```

### Custom Resource Group Names

```powershell
.\SubscriptionConfigure.ps1 `
    -CustomImageResourceGroup "rg-custom-images" `
    -W365ResourceGroup "rg-w365-spoke"
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `TenantId` | string | - | Azure AD tenant ID (skips interactive picker) |
| `SubscriptionId` | string | - | Subscription ID (skips interactive picker) |
| `AdminUPN` | string | `admin@bighatgrouptraining.ca` | Admin account UPN |
| `BdoorUPN` | string | `bdoor@bighatgrouptraining.ca` | Backdoor admin account UPN |
| `CustomImageResourceGroup` | string | `rg-w365-customimage` | Resource group for Custom Image deployments |
| `W365ResourceGroup` | string | `rg-w365-spoke-prod` | Resource group for W365 spoke network |
| `StudentCount` | int | `30` | Number of student accounts to create (W365Student1, W365Student2, etc.) |
| `SkipUserCreation` | switch | - | Skip admin account creation (re-run RBAC only) |
| `SkipRoleAssignments` | switch | - | Skip RBAC configuration (test user creation only) |

## What the Script Does

### 1. Module Verification
- Checks for required PowerShell modules
- Validates PowerShell version (7.0+)

### 2. Azure Context Selection
- Lists accessible tenants (or uses `-TenantId`)
- Authenticates to selected tenant
- Enumerates and selects subscription
- Displays active context summary

### 3. Admin Account Provisioning
- **Connects to Microsoft Graph ONCE** for all user creations (efficient, no repeated auth prompts)
- Connects to Microsoft Graph with required scopes: `User.ReadWrite.All`, `Group.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`
- Creates two main admin accounts:
  - **Admin**: `admin@bighatgrouptraining.ca` (Intune Administrator via group)
  - **Backdoor**: `bdoor@bighatgrouptraining.ca` with Global Administrator role (direct assignment)
- **Default**: Creates 30 student administrator and 30 student accounts:
  - **Student Admins**: `admin1@bighatgrouptraining.ca` through `admin30@bighatgrouptraining.ca`
    - Display name: "Student Admin 1", "Student Admin 2", etc.
    - Role: Intune Administrator (per-student management)
  - **Students**: `W365Student1@bighatgrouptraining.ca` through `W365Student30@bighatgrouptraining.ca`
    - Display name: "W365 Student 1", "W365 Student 2", etc.
    - Role: Regular users (no directory roles)
  - All 62 accounts created using the same Graph connection
- Generates randomized temporary passwords (16 characters, mixed case + numbers + symbols)
- Requires password change at first sign-in
- All credentials are saved to CSV file
- **IMPORTANT**: Displays temporary passwords once—save immediately!

### 4. Per-Student Security Group Creation (Pod Model)
- **Creates 90 security groups** (3 per student for 30 students):
  - **SG-Student{N}-Admins**: Contains admin{N}@ user
    - Used for: AU role assignment, Intune role assignment
  - **SG-Student{N}-Users**: Contains W365Student{N}@ user
    - Used for: AU membership, Intune policy assignment scope
  - **SG-Student{N}-Devices**: Initially empty
    - Used for: Intune policy assignment scope (Cloud PCs added later)
- **Adds users to groups automatically**:
  - admin1@ → SG-Student1-Admins
  - W365Student1@ → SG-Student1-Users
  - Repeat for all 30 students
- **Waits 10 seconds** for group propagation before continuing

### 5. Legacy Global Security Group (DEPRECATED)
- Creates security group: **01_ClassAdminAccts** (kept for backwards compatibility)
- Adds all admin accounts to the group
- Assigns **Intune Administrator** role to the group
- **NOTE**: This global role is deprecated in favor of per-student custom Intune role
- Future versions may remove this entirely
- Disconnects from Graph after all operations complete

### 6. Azure RBAC Configuration
- Uses existing Azure connection (Graph disconnected after user creation)
- Registers resource providers: `Microsoft.Compute`, `Microsoft.Storage`, `Microsoft.Network`, `Microsoft.ManagedIdentity`
- Creates custom roles from JSON templates:
  - **Windows 365 Custom Image Builder** (scoped to subscription)
  - **Windows 365 Spoke Network Deployer** (scoped to subscription)
- Assigns roles to admin accounts at resource group scope:
  - Main admin account (`admin@`) gets both roles assigned at RG scope
  - All student admin accounts (`admin1@` through `admin30@`) get both roles assigned at RG scope
  - Role assignments may warn if RG doesn't exist yet (will activate when RG is created)
- **Note**: Custom role definitions are subscription-scoped to allow flexibility, but role assignments target specific resource group paths

### 7. Summary Output
- Displays configuration summary including pod structure
- Lists next steps: Run scripts 2-4 to complete pod isolation setup
- Shows file locations for logs and credentials

## Output Example

```
==========================================
Subscription Bootstrap Automation
==========================================
Log file: C:\...\SubscriptionConfigure\SubscriptionConfigure-2025-11-03-15-30.log
CSV file: C:\...\SubscriptionConfigure\SubscriptionConfigure.csv

...

==========================================
 Configuration Summary
==========================================
 Tenant:                BHG Training
 Subscription:          W365Lab
 Admin UPN:             admin@bighatgrouptraining.ca
 Admin Role:            Intune Administrator
 Backdoor UPN:          bdoor@bighatgrouptraining.ca
 Backdoor Role:         Global Administrator
 CustomImage RG:        rg-w365-customimage (created by deployment)
 W365 RG:               rg-w365-spoke-prod (created by deployment)
 RBAC Roles:            Configured for RG scopes
 Resource Providers:    Registered
==========================================

📋 Next Steps:
  1. Have both admin accounts sign in and change temporary passwords:
     - Admin:      admin@bighatgrouptraining.ca
     - Backdoor:   bdoor@bighatgrouptraining.ca
  2. Deploy Custom Image infrastructure:
     cd CustomImage
     .\Deploy-W365CustomImage.ps1 -TenantId <tenant-id>
  3. Deploy W365 spoke network:
     cd W365
     .\deploy.ps1 -TenantId <tenant-id>

📄 Files created in Documents folder:
  Log: C:\Users\YourName\Documents\SubscriptionConfigure-2025-11-03-15-30.log
  CSV: C:\Users\YourName\Documents\SubscriptionConfigure.csv
```

### CSV File Format

Location: `C:\Users\YourName\Documents\SubscriptionConfigure.csv`

```csv
UPN,Password,Role,CreatedDate
admin@bighatgrouptraining.ca,Xy9#mK2$pL8@qR4!,Intune Administrator,2025-11-08 16:30:45
bdoor@bighatgrouptraining.ca,Bd7!nF3&vH6#wQ9@,Global Administrator,2025-11-08 16:31:22
```

## Troubleshooting

### Azure Subscription Selector Appears

**Symptom**: During login, Azure shows a subscription selector with many MFA warnings.

**Cause**: Azure PowerShell tries to enumerate subscriptions across all accessible tenants.

**Solution**:
1. **Press ESC or click Cancel** to dismiss Azure's selector
2. Wait for the script's tenant list to appear
3. Select your tenant from the script's list

**Alternative**: Use `-TenantId` parameter to bypass this entirely:
```powershell
.\SubscriptionConfigure.ps1 -TenantId "5b504ec5-a5c0-4aee-97d9-5be638ef1f71"
```

### Domain Verification

The script automatically verifies that the UPN domain exists in the tenant:
- Default domain: `bighatgrouptraining.ca`
- If the domain is not verified, the script will fail with an error
- Check available verified domains in the error message

**Custom Domain**: If using a different domain, specify it explicitly:
```powershell
.\SubscriptionConfigure.ps1 -AdminUPN "admin@yourdomain.com" -BdoorUPN "bdoor@yourdomain.com"
```

### Error: "Module not installed"
**Cause**: Required PowerShell module is missing.

**Solution**: Install the module:
```powershell
Install-Module -Name <ModuleName> -Repository PSGallery -Force
```

### Error: "Failed to authenticate to tenant"
**Cause**: MFA is required for the tenant.

**Solution**: Pre-authenticate and specify tenant:
```powershell
Connect-AzAccount -TenantId <tenant-id>
.\SubscriptionConfigure.ps1 -TenantId <tenant-id>
```

### Error: "Could not load file or assembly 'Microsoft.Graph.Authentication'"
**Cause**: Version conflict between Azure PowerShell (Az) and Microsoft Graph PowerShell modules.

**How the script handles it**: 
- Disconnects from Azure before connecting to Microsoft Graph
- Reconnects to Azure after Graph operations complete
- This isolates the two SDKs to avoid version conflicts

**If error persists**:
1. Close PowerShell completely
2. Start a fresh PowerShell 7 session
3. Run the script without pre-connecting to Azure or Graph
4. Let the script manage all connections

### Error: "CustomImage-MinimumRole.json not found"
**Cause**: JSON role definition file is missing.

**Solution**: Ensure script is run from `SubscriptionConfigure/` directory and role files exist in sibling directories.

### Error: "Current user must have Owner or UAA role"
**Cause**: Insufficient permissions to create custom roles.

**Solution**: Have an Owner/User Access Administrator run the script, or use built-in roles (requires manual role assignment as fallback).

## Security Considerations

1. **CSV File Security**: The `SubscriptionConfigure.csv` file contains plaintext passwords.
   - Store in a secure location
   - Restrict file permissions (administrators only)
   - Delete after distributing passwords securely
   - Automatically excluded from Git via `.gitignore`

2. **Log File**: The log file contains operational details but NOT passwords.
   - Safe to archive for audit purposes
   - Contains tenant IDs, subscription IDs, and operation results

3. **Temporary Password**: The generated password is displayed once in console and saved to CSV.
   - Save immediately in a secure password manager
   - CSV provides backup if console output is missed

4. **Password Reset Required**: Admin must change password on first sign-in.

5. **Least Privilege**: Custom roles grant minimum permissions required for deployments.

6. **Resource Group Scope**: RBAC assignments are scoped to specific resource groups, not subscription-wide.

7. **Idempotent Execution**: Safe to re-run—existing users and role assignments are detected and preserved.

## Scope Tag Management (2_ScopeTags.ps1)

After creating student accounts with `1_SubscriptionConfigure.ps1 -StudentCount N`, use `2_ScopeTags.ps1` to create Intune scope tags for role-based access control.

### Purpose

Scope tags enable administrators to manage specific students' Cloud PCs by restricting visibility and management rights to only assigned resources. Each scope tag (ST1, ST2, ST3, etc.) corresponds to a W365Student account created by `1_SubscriptionConfigure.ps1`.

### Usage

#### Interactive Mode

```powershell
.\2_ScopeTags.ps1
```

Prompts for the number of scope tags to create (should match student count).

#### Automated Mode

```powershell
.\2_ScopeTags.ps1 -StudentCount 25 -AdminUPNs "admin@bighatgrouptraining.ca"
```

Creates 25 scope tags (ST1-ST25) and documents assignments.

#### Multiple Administrators

```powershell
.\2_ScopeTags.ps1 -StudentCount 20 -AdminUPNs "admin@bighatgrouptraining.ca","instructor@bighatgrouptraining.ca"
```

### Complete Workflow Example (30 Students - Default)

```powershell
# Step 1: Create users, security groups, and Azure RBAC roles
.\1_SubscriptionConfigure.ps1

# Step 2: Create Intune scope tags (ST1-ST30)
.\2_ScopeTags.ps1 -StudentCount 30

# Step 3: Create Administrative Units with Groups Administrator role
.\3_AdministrativeUnits.ps1 -StudentCount 30

# Step 4: Create custom Intune role and scoped assignments
.\4_IntuneCustomRole.ps1 -StudentCount 30
```

**What Gets Created:**

**Per-Student (30 pods total):**
- **2 Users**: admin{N}@ (admin) + W365Student{N}@ (managed user)
- **3 Security Groups**: 
  - SG-Student{N}-Admins (contains admin{N}@)
  - SG-Student{N}-Users (contains W365Student{N}@)
  - SG-Student{N}-Devices (initially empty)
- **1 Administrative Unit**: AU-Student{N}
  - Members: W365Student{N}@ user + SG-Student{N}-Users group
  - Role: Groups Administrator scoped to AU
  - Assigned to: SG-Student{N}-Admins group
- **1 Scope Tag**: ST{N}
- **1 Custom Intune Role Assignment**:
  - Role: "Lab Intune Admin" (custom, shared across all students)
  - Members: SG-Student{N}-Admins group
  - Scope (Groups): SG-Student{N}-Users + SG-Student{N}-Devices
  - Scope (Tags): ST{N}

**Shared Across All:**
- **2 Main Admin Accounts**: admin@ (deprecated group role) + bdoor@ (Global Admin)
- **Azure RBAC Roles**: All admins get Custom Image Builder and W365 Spoke Deployer roles
- **1 Custom Intune Role**: "Lab Intune Admin" role definition (used by all 30 assignments)

**Result:** Complete isolation where admin1@ can only see/manage W365Student1@ and cannot access anything related to admin2@ or other students.

### What It Does

1. **Creates scope tags**: ST1, ST2, ST3, etc. (one per student)
2. **Auto-assigns to admins**: Automatically assigns each scope tag to the corresponding admin account:
   - admin1@ gets ST1
   - admin2@ gets ST2
   - admin3@ gets ST3
   - etc.
3. **Verifies admin users**: Confirms specified admins exist in Entra ID
4. **Updates Intune role assignments**: Adds scope tags directly to admin role assignments via Graph API
5. **Documents mappings**: Exports scope tag IDs and names to CSV

### Manual Steps Required

**Important**: While scope tags are automatically assigned to admin accounts, you still need to:

1. **Assign to provisioning policies**:
   - Navigate to: Intune portal > Devices > Windows 365 > Provisioning policies
   - Edit each student-specific policy
   - Add corresponding scope tag (ST1 for W365Student1, ST2 for W365Student2, etc.)

2. **Verify admin assignments** (optional):
   - Navigate to: Intune portal > Tenant administration > Roles
   - Check admin role assignments to confirm scope tags were applied

3. **Assign to Cloud PC devices** (automatic):
   - Once assigned to provisioning policies, new Cloud PCs inherit the scope tag
   - Existing Cloud PCs may need manual tag assignment

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `StudentCount` | int | - | Number of scope tags to create (1-100) |
| `AdminUPNs` | string[] | `[]` (empty) | Array of admin UPNs. Leave empty to auto-assign to admin1@, admin2@, etc. |
| `TenantId` | string | - | Azure AD tenant ID |
| `SkipTagCreation` | switch | - | Skip creation, only retrieve existing tags |

### Output Files

All files are saved to your **Documents folder**:

- **Log file**: `ScopeTags-YYYY-MM-DD-HH-MM.log` - Complete execution log
- **CSV file**: `ScopeTags-YYYY-MM-DD-HH-MM.csv` - Scope tag mappings (Name, ID, Status)

### Prerequisites

- **PowerShell 7.0+**
- **Microsoft Graph modules**:
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.DeviceManagement`
  - `Microsoft.Graph.Users`
- **Permissions**: Intune Administrator or Global Administrator role
- **Required scopes**: `DeviceManagementRBAC.ReadWrite.All`, `DeviceManagementConfiguration.ReadWrite.All`, `User.Read.All`

## Administrative Units Management (3_AdministrativeUnits.ps1)

After creating student accounts, groups, and scope tags, use `3_AdministrativeUnits.ps1` to create administrative units with scoped **Groups Administrator** role for Entra ID delegation.

### Purpose

Administrative Units (AUs) enable scoped role-based access control in Microsoft Entra ID for **user and group management**. Each student admin gets their own administrative unit (AU-Student1, AU-Student2, etc.) with a **Groups Administrator** role scoped only to that AU.

**Key Benefits**:
- **User Visibility Control**: Each admin can only see users within their AU
- **Password Reset**: Admins can reset passwords for users in their AU
- **Group Management**: Admins can manage membership of groups in their AU (e.g., SG-Student1-Users)
- **Hidden Membership**: AU membership is hidden from other users for privacy
- **Least Privilege**: Groups Administrator role limited to AU scope, not tenant-wide

**NOTE**: Intune management is handled separately by custom Intune role (see 4_IntuneCustomRole.ps1). The AU role is purely for Entra ID operations.

### Usage

#### Default Mode (30 Students)

```powershell
.\3_AdministrativeUnits.ps1
```

Creates 30 administrative units (AU-Student1-AU-Student30) with scoped Groups Administrator role.

#### Custom Student Count

```powershell
# Create 10 administrative units
.\3_AdministrativeUnits.ps1 -StudentCount 10

# Create 40 administrative units
.\3_AdministrativeUnits.ps1 -StudentCount 40
```

#### Automated Mode

```powershell
.\3_AdministrativeUnits.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -StudentCount 25
```

### What It Does

1. **Creates Administrative Units**: AU-Student1, AU-Student2, AU-Student3, etc. (one per student)
   - Display name: AU-Student1, AU-Student2, etc.
   - Description: "Pod isolation AU for Student N (admin + user + group)"
   - Visibility: HiddenMembership (privacy enabled)

2. **Adds Members**: Adds student user AND users group to each AU
   - W365Student1@ (user) + SG-Student1-Users (group) → AU-Student1
   - W365Student2@ (user) + SG-Student2-Users (group) → AU-Student2
   - etc.
   - **NOTE**: Admin users are NOT added to AU (only the admin's group gets role assignment)

3. **Assigns Scoped Roles**: Assigns **Groups Administrator** role scoped to each AU
   - Role assigned to **SG-Student1-Admins group** (not direct to user)
   - admin1@ inherits role via group membership
   - Scope: Limited to AU-Student1 only
   - Permissions: Password reset, group membership management

4. **Idempotent**: Safe to re-run, skips existing AUs and assignments

### Prerequisites

- **PowerShell 7.0+**
- **Microsoft Graph modules**:
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.Identity.DirectoryManagement`
- **Permissions**: Global Administrator or Privileged Role Administrator role
- **Required scopes**: `AdministrativeUnit.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `Directory.Read.All`

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `TenantId` | string | - | Azure AD tenant ID (optional - will prompt if not provided) |
| `StudentCount` | int | `30` | Number of administrative units to create (1-100) |
| `Domain` | string | `bighatgrouptraining.ca` | Domain for student admin accounts |

### Output Files

All files are saved to your **Documents folder**:

- **Log file**: `AdministrativeUnits-YYYY-MM-DD-HH-MM.log` - Complete execution log with timestamps

### Next Steps After Creation

After running this script:

1. **Verify AU Membership**: Confirm users were added correctly (optional)
   - Navigate to: Entra Admin Center > Identity > Roles & admins > Administrative units
   - Select each AU (ST1, ST2, etc.)
   - Verify both admin and student accounts are members

2. **Verify Scoped Access**: Test that each admin can only see their AU
   - Sign in as admin1@
   - Navigate to Entra Admin Center or Intune portal
   - Verify only ST1 resources are visible

3. **Add Devices to AUs** (optional): Move Cloud PC devices to appropriate AUs
   - Devices can be added to AUs for additional scoping
   - Combine with scope tags for comprehensive isolation

### Combined with Scope Tags

Administrative Units and Scope Tags work together for comprehensive isolation:

- **Administrative Units**: Control what users/devices the admin can see in Entra ID
- **Scope Tags**: Control what Intune resources (policies, apps, Cloud PCs) the admin can manage
- **Azure RBAC**: Control what Azure resources the admin can deploy

**Complete Isolation Example**:
- admin1@ in ST1 AU (Entra ID scope)
- admin1@ assigned ST1 scope tag (Intune scope)
- admin1@ assigned Custom Image Builder role (Azure scope)
- Result: admin1@ can only see/manage resources related to W365Student1@

### Troubleshooting

#### Error: "Module not installed"

```powershell
Install-Module -Name Microsoft.Graph.DeviceManagement -Repository PSGallery -Force
```

#### Warning: "No Intune role assignments found"

**Cause**: Admin account doesn't have an Intune role assigned.

**Solution**: Run Script 4 (4_IntuneCustomRole.ps1) to create custom Intune role assignments with proper scoping.

## Custom Intune Role Management (4_IntuneCustomRole.ps1)

After creating users, groups, scope tags, and administrative units, use `4_IntuneCustomRole.ps1` to create the custom Intune role and scoped role assignments for complete pod isolation.

### Purpose

This script creates the **Intune delegation layer** of the pod model by defining a custom "Lab Intune Admin" role and creating scoped role assignments for each student. Unlike the built-in "Intune Administrator" role (which is global), this custom role can be scoped to specific groups and tags.

**Key Benefits**:
- **Custom Permissions**: Define exactly which Intune permissions admins get
- **Scoped Assignments**: Each admin limited to their assigned user/device groups
- **Automatic Tagging**: Policies created by admin auto-tagged with their scope tag
- **Assignment Restrictions**: Admin can only assign policies to their scoped groups
- **True Isolation**: admin1@ cannot see admin2@'s policies or devices

### Usage

#### Default Mode (30 Students)

```powershell
.\4_IntuneCustomRole.ps1
```

Creates custom role and 30 scoped assignments.

#### Custom Student Count

```powershell
# Create 10 role assignments
.\4_IntuneCustomRole.ps1 -StudentCount 10

# Create 40 role assignments
.\4_IntuneCustomRole.ps1 -StudentCount 40
```

#### Skip Role Creation (Re-assign Only)

```powershell
.\4_IntuneCustomRole.ps1 -SkipRoleCreation
```

### What It Does

1. **Creates Custom Intune Role**: "Lab Intune Admin" (one role, shared by all students)
   - Permissions: Mobile Apps (CRUD+Assign), Device Configurations (CRUD+Assign), Managed Devices (Read+Retire+Wipe), Remote Actions
   - **NOT** the built-in "Intune Administrator" role
   - Allows proper scoping via role assignments

2. **Creates Scoped Role Assignments**: One per student (30 total)
   - **Role**: "Lab Intune Admin" (custom role created above)
   - **Members (Who)**: SG-Student{N}-Admins group
   - **Scope (Groups)**: SG-Student{N}-Users + SG-Student{N}-Devices
   - **Scope (Tags)**: ST{N}

3. **Validates Prerequisites**: Checks that groups and scope tags exist before creating assignments

4. **Exports Results**: CSV file documenting all assignments with group IDs and scope tag IDs

### Prerequisites

- **PowerShell 7.0+**
- **Microsoft Graph modules**:
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.DeviceManagement`
  - `Microsoft.Graph.Groups`
- **Permissions**: Intune Administrator or Global Administrator role
- **Required scopes**: `DeviceManagementRBAC.ReadWrite.All`, `DeviceManagementConfiguration.ReadWrite.All`, `Group.Read.All`
- **Dependencies**: Must run Scripts 1-3 first (creates required users, groups, scope tags, AUs)

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `StudentCount` | int | `30` | Number of role assignments to create (1-100) |
| `TenantId` | string | - | Azure AD tenant ID (optional) |
| `Domain` | string | `bighatgrouptraining.ca` | Domain for student accounts |
| `SkipRoleCreation` | switch | - | Skip role creation, only create assignments |

### Output Files

All files are saved to your **Documents folder**:

- **Log file**: `IntuneCustomRole-YYYY-MM-DD-HH-MM.log` - Complete execution log
- **CSV file**: `IntuneCustomRole-YYYY-MM-DD-HH-MM.csv` - Role assignment details (groups, scope tags, assignment IDs)

### How It Enables Isolation

**When admin1@ creates an Intune policy:**
1. Policy is automatically tagged with `ST1` (from role assignment)
2. Only visible to admin1@ (scope tag visibility)
3. Assignment picker only shows SG-Student1-Users and SG-Student1-Devices (from Scope (Groups))
4. admin2@ cannot see this policy (has ST2, not ST1)

**When admin1@ views Intune portal:**
1. Only sees policies/apps tagged with ST1
2. Cannot see ST2, ST3, etc. tagged resources
3. Cannot assign policies to groups outside their scope
4. Device list filtered to ST1-tagged Cloud PCs only

### Troubleshooting

#### Error: "Custom role 'Lab Intune Admin' not found"

**Cause**: Role creation was skipped but role doesn't exist.

**Solution**: Run without `-SkipRoleCreation` flag to create the role first.

#### Warning: "Admin group not found"

**Cause**: Security groups weren't created by Script 1.

**Solution**: Run `.\1_SubscriptionConfigure.ps1` first to create users and groups.

#### Warning: "Scope tag not found"

**Cause**: Scope tags weren't created by Script 2.

**Solution**: Run `.\2_ScopeTags.ps1` first to create scope tags.

## Related Documentation

- [Student-Deploy/CreateStudentsandW365.md](../3_Student-Deploy/CreateStudentsandW365.md) - Complete lab setup workflow
- [CustomImage/README.md](../CustomImage/README.md) - Custom Image deployment
- [W365/README.md](../W365/README.md) - Spoke network deployment

## Change History

| Date | Change | Author |
|------|--------|--------|
| 2025-11-03 | Initial creation | OpenSpec automation |
| 2025-11-08 | Refactored for single tenant design (bighatgrouptraining.ca) | OpenSpec automation |
| 2025-11-08 | Added 2_ScopeTags.ps1 for Intune scope tag management | OpenSpec automation |
| 2025-11-08 | Added student account creation (W365Student1@, admin1@, etc.) | OpenSpec automation |
| 2025-11-08 | Added automatic scope tag assignment to admin accounts | OpenSpec automation |
| 2025-11-08 | Added Azure RBAC role assignment to all student admin accounts | OpenSpec automation |
| 2025-11-08 | Removed RG creation - deployment scripts handle this in preferred locations | OpenSpec automation |
| 2025-11-08 | Changed default StudentCount from 0 to 30 (creates 30 students by default) | OpenSpec automation |
| 2025-11-08 | Optimized Graph authentication - single auth for all 62 users (no repeated prompts) | OpenSpec automation |
| 2025-11-08 | Fixed custom role creation - now subscription-scoped (RGs don't exist during creation) | OpenSpec automation |
| 2025-11-09 | Added 3_AdministrativeUnits.ps1 for scoped Intune Administrator roles via AUs | OpenSpec automation |
| 2025-11-09 | Changed UsageLocation from "US" to "CA" for Canadian billing/licensing | OpenSpec automation |
| 2025-11-09 | Changed to group-based Intune Administrator role (01_ClassAdminAccts group) | OpenSpec automation |
| 2025-11-10 | **BREAKING**: Implemented complete pod security model for true student isolation | OpenSpec automation |
| 2025-11-10 | Added per-student security groups: SG-Student{N}-Admins, SG-Student{N}-Users, SG-Student{N}-Devices (90 groups total) | OpenSpec automation |
| 2025-11-10 | Changed AU names from ST{N} to AU-Student{N} for clarity | OpenSpec automation |
| 2025-11-10 | Changed AU role from Intune Administrator to Groups Administrator (Entra ID delegation only) | OpenSpec automation |
| 2025-11-10 | Added groups as AU members (W365Student{N}@ user + SG-Student{N}-Users group) | OpenSpec automation |
| 2025-11-10 | Changed AU role assignment from direct user to SG-Student{N}-Admins group | OpenSpec automation |
| 2025-11-10 | Added 4_IntuneCustomRole.ps1 for custom Intune role and scoped assignments | OpenSpec automation |
| 2025-11-10 | Replaced built-in Intune Administrator role with custom "Lab Intune Admin" role | OpenSpec automation |
| 2025-11-10 | Implemented scoped role assignments: Members (group) + Scope (Groups) + Scope (Tags) | OpenSpec automation |
| 2025-11-10 | Updated 2_ScopeTags.ps1 to only create tags (assignment now in Script 4) | OpenSpec automation |
| 2025-11-10 | Deprecated 01_ClassAdminAccts global group (kept for backwards compatibility) | OpenSpec automation |
