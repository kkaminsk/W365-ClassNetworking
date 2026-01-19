# Windows 365 Permissions Fix

## Problem

The W365 infrastructure deployment was creating networking resources but **not assigning the required permissions** for the Windows 365 service to use those resources. This caused provisioning failures with the following errors:

```
The application 'Windows 365' doesn't have sufficient permissions on the Azure resource group 'rg-w365-spoke-student1-prod'. 
Make sure that the application has Windows 365 Network Interface Contributor role on the resource group.

The application 'Windows 365' doesn't have sufficient permissions on the Azure vNet 'vnet-w365-spoke-student1-prod'. 
Make sure that the application has Windows 365 Network User role on the vNet.
```

## Root Cause

The Bicep templates only created:
- ✅ Resource group
- ✅ Virtual network
- ✅ Subnets
- ✅ Network security groups

But **did not** assign the required Azure RBAC roles to the Windows 365 service principal.

## Solution

### 1. Created New Permissions Module

**File**: `W365\infra\modules\w365-permissions\main.bicep`

This module:
- References the Windows 365 service principal by its Object ID
- Assigns **Windows 365 Network Interface Contributor** role on the resource group
- Assigns **Windows 365 Network User** role on the virtual network
- Uses deterministic GUIDs for idempotent role assignments

### 2. Updated Main Deployment Template

**File**: `W365\infra\envs\prod\main.bicep`

Changes:
- Added `windows365ServicePrincipalId` parameter (required)
- Added `w365Permissions` module deployment step
- Added output for permissions status

### 3. Enhanced Deployment Script

**File**: `W365\deploy.ps1`

Added:
- `Get-Windows365ServicePrincipal` function to dynamically retrieve the service principal Object ID
- Automatic injection of the service principal ID into deployment parameters
- Validation checks to ensure the service principal exists before deployment
- Error handling for missing service principal

## Required Roles

The Windows 365 service principal now receives:

| Role | Scope | Purpose |
|------|-------|---------|
| **Windows 365 Network Interface Contributor** | Resource Group | Create/manage NICs for Cloud PCs |
| **Windows 365 Network User** | Virtual Network | Use VNet for Cloud PC connectivity |

## Windows 365 Service Principal Details

- **Application ID**: `0af06dc6-e4b5-4f28-818e-e78e62d137a5` (constant)
- **Display Name**: "Windows 365"
- **Object ID**: Retrieved dynamically per tenant

## Deployment Flow

### Before (Missing Permissions)
```
1. deploy.ps1 runs
2. Resource group created ✅
3. Virtual network created ✅
4. Subnets created ✅
5. NSGs created ✅
6. ❌ No role assignments
7. Windows 365 provisioning fails ❌
```

### After (With Permissions)
```
1. deploy.ps1 runs
2. Get Windows 365 service principal Object ID ✅
3. Resource group created ✅
4. Virtual network created ✅
5. Subnets created ✅
6. NSGs created ✅
7. Windows 365 permissions assigned ✅
   - Network Interface Contributor → RG
   - Network User → VNet
8. Windows 365 provisioning succeeds ✅
```

## Usage

### Deploy with Automatic Permissions

```powershell
# Single command deployment - permissions are automatically configured
.\deploy.ps1 -StudentNumber 1
```

The script will:
1. Retrieve the Windows 365 service principal Object ID
2. Deploy all networking resources
3. Automatically assign the required permissions

### Verify Permissions

```powershell
# Check if permissions are correctly configured
.\Check-W365Permissions.ps1
```

Expected output:
```
✅ Success: Found 'Windows 365 Network Interface Contributor' role on the resource group.
✅ Success: Found 'Windows 365 Network User' role on the vNet.
```

## Files Changed

| File | Type | Changes |
|------|------|---------|
| `infra/modules/w365-permissions/main.bicep` | New | Permission assignment module |
| `infra/modules/w365-permissions/README.md` | New | Documentation |
| `infra/envs/prod/main.bicep` | Modified | Added permissions module call |
| `deploy.ps1` | Modified | Added SP retrieval and parameter injection |

## Testing

### Before Deploying to Production

1. **Validate the template**:
   ```powershell
   .\deploy.ps1 -Validate -StudentNumber 1
   ```

2. **Preview changes**:
   ```powershell
   .\deploy.ps1 -WhatIf -StudentNumber 1
   ```

3. **Deploy to a test student**:
   ```powershell
   .\deploy.ps1 -StudentNumber 1
   ```

4. **Verify permissions**:
   ```powershell
   .\Check-W365Permissions.ps1
   ```

## Benefits

✅ **Automated**: No manual permission configuration required
✅ **Idempotent**: Safe to rerun deployments
✅ **Per-Student**: Each student deployment gets correct permissions automatically
✅ **Validated**: Script validates service principal exists before deployment
✅ **Documented**: Clear error messages and documentation

## Prerequisites

The deploying user account must have:
- **Owner** role OR
- **User Access Administrator** role

On the subscription or resource group to assign roles.

## Troubleshooting

### "Windows 365 service principal not found"

**Cause**: No Windows 365 licenses in the tenant

**Solution**: Ensure Windows 365 licenses are assigned in Microsoft 365 admin center

### "Insufficient privileges to complete the operation"

**Cause**: Account lacks permission to assign roles

**Solution**: Run as a user with Owner or User Access Administrator role

## Next Steps

After deploying with the fix:

1. ✅ Deploy spoke network: `.\deploy.ps1 -StudentNumber <N>`
2. ✅ Verify permissions: `.\Check-W365Permissions.ps1`
3. ✅ Create Windows 365 provisioning policy in Intune portal
4. ✅ Assign Cloud PC licenses to users
5. ✅ Provision Cloud PCs

The network will now have the correct permissions for Windows 365 provisioning to succeed!
