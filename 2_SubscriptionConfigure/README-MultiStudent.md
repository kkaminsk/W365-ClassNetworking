# Multi-Student Single-Subscription Configuration

## Overview

This directory contains scripts for configuring a **single-subscription multi-student** Windows 365 lab environment, where all 30 students share a single Azure subscription with RBAC-based isolation.

### Architecture Summary
- **Model**: Single Azure subscription with 30 students
- **Student Accounts**: `W365Student1@domain.com` through `W365Student30@domain.com`
- **Resource Groups per Student**:
  - `rg-st{N}-customimage` – Custom image builder resources
  - `rg-st{N}-spoke` – Windows 365 spoke network
- **RBAC**: Each student has Contributor role on their own 2 resource groups only
- **Network**: Hub-spoke topology with shared hub VNet

## Scripts

### 1. New-StudentResourceGroups.ps1
**Purpose**: Creates Azure resource groups for students with proper tagging.

**Usage**:
```powershell
# Single student
.\New-StudentResourceGroups.ps1 -StudentNumber 5

# All 30 students at once
.\New-StudentResourceGroups.ps1 -CreateAllStudents -TotalStudents 30

# Custom region
.\New-StudentResourceGroups.ps1 -StudentNumber 10 -Location "eastus"
```

**What it creates**:
- `rg-st{N}-customimage` – Tagged with `Student: ST{N}`, `Purpose: Lab`, `Environment: Prod`
- `rg-st{N}-spoke` – Tagged with `Student: ST{N}`, `Purpose: Lab`, `Environment: Prod`

**Features**:
- Idempotent (safe to re-run)
- Progress indicators for batch operations
- Logging to Documents folder

---

### 2. Configure-StudentRBAC.ps1
**Purpose**: Configures complete student environment including resource groups and RBAC assignments.

**Usage**:
```powershell
# Configure single student (creates RGs + assigns RBAC)
.\Configure-StudentRBAC.ps1 -StudentNumber 5

# Configure all 30 students
.\Configure-StudentRBAC.ps1 -ConfigureAllStudents -TotalStudents 30

# Re-assign RBAC only (assumes RGs already exist)
.\Configure-StudentRBAC.ps1 -StudentNumber 10 -SkipResourceGroupCreation

# Skip resource provider registration
.\Configure-StudentRBAC.ps1 -StudentNumber 15 -SkipResourceProviders
```

**What it does**:
1. Verifies Azure subscription context
2. Registers required resource providers (Microsoft.Compute, Microsoft.Storage, etc.)
3. Creates resource groups (calls New-StudentResourceGroups.ps1)
4. Assigns Contributor role to `W365Student{N}@domain.com` on their resource groups
5. Validates and reports success/failures

**Prerequisites**:
- Azure subscription context set (`Connect-AzAccount`)
- Owner or User Access Administrator role at subscription level
- Student accounts must exist in Azure AD (`W365Student1@domain.com`, etc.)

---

### 3. SubscriptionConfigure.ps1 (Legacy - Multi-Tenant)
**Status**: **DEPRECATED for multi-student labs**

This is the original multi-tenant script. For new multi-student deployments, use **Configure-StudentRBAC.ps1** instead.

The legacy script is retained for reference and backward compatibility with existing multi-tenant deployments.

---

## Quick Start Guide

### Initial Setup (One Time)
1. **Deploy Hub Landing Zone** (if not already deployed):
   ```powershell
   cd ../1_Hub
   .\deploy.ps1
   ```

2. **Connect to Azure**:
   ```powershell
   Connect-AzAccount
   Select-AzSubscription -SubscriptionName "Your Lab Subscription"
   ```

3. **Create Student Accounts in Azure AD**:
   Students must exist as `W365Student1@domain.com` through `W365Student30@domain.com`

### Configure All Students (Batch Mode)
```powershell
cd 2_SubscriptionConfigure
.\Configure-StudentRBAC.ps1 -ConfigureAllStudents -TotalStudents 30
```

**Output**:
- 60 resource groups created (2 per student)
- 60 RBAC assignments (Contributor on each RG)
- Complete in ~5 minutes

### Configure Single Student
```powershell
.\Configure-StudentRBAC.ps1 -StudentNumber 5
```

**Output**:
- `rg-st5-customimage` and `rg-st5-spoke` created
- W365Student5@domain.com assigned Contributor on both RGs

---

## Student Isolation & Permissions

### What Students Can Do
- **Full control** within their own resource groups:
  - Deploy custom images in `rg-st{N}-customimage`
  - Deploy spoke networks in `rg-st{N}-spoke`
  - Create/delete all resources within their RGs
  
### What Students Cannot Do
- View or modify other students' resource groups
- Create resources outside their assigned RGs
- Change subscription-level settings
- Access shared hub infrastructure directly

### Instructor Access
Instructors with **Owner** or **Contributor** at subscription level can:
- View all student resource groups
- Monitor all student deployments
- Troubleshoot issues across all students
- Centralized cost tracking via `Student: ST{N}` tags

---

## Resource Naming Convention

| Resource Type | Pattern | Example |
|--------------|---------|---------|
| Resource Group (Custom Image) | `rg-st{N}-customimage` | `rg-st5-customimage` |
| Resource Group (Spoke) | `rg-st{N}-spoke` | `rg-st5-spoke` |
| VNet (Spoke) | `vnet-st{N}-spoke` | `vnet-st5-spoke` |
| VNet (Image Build) | `vnet-st{N}-imagebuild` | `vnet-st5-imagebuild` |
| Subnet (Cloud PC) | `snet-st{N}-cloudpc` | `snet-st5-cloudpc` |
| NSG | `nsg-st{N}-spoke` | `nsg-st5-spoke` |
| Managed Identity | `st{N}-imagebuilder-identity` | `st5-imagebuilder-identity` |
| Gallery | `st{N}gallery` | `st5gallery` |

---

## Network Architecture

### Hub VNet (Shared)
- **Name**: `vnet-hub`
- **Address Space**: `10.10.0.0/20`
- **Resources**: Azure Firewall, Log Analytics, Private DNS
- **Shared by**: All 30 students

### Student Spoke VNets (Isolated)
- **Pattern**: `vnet-st{N}-spoke`
- **Address Spaces**:
  - Student 1: `10.1.1.0/24`
  - Student 2: `10.1.2.0/24`
  - ...
  - Student 30: `10.1.30.0/24`
- **Peering**: Each spoke peers to hub (no spoke-to-spoke connectivity)

---

## Troubleshooting

### Error: "User not found: W365Student5@domain.com"
**Cause**: Student account doesn't exist in Azure AD.

**Solution**: Create the student account first:
```powershell
# Create accounts using your Entra ID provisioning process
# Or manually in Azure Portal
```

### Error: "No Azure context found"
**Cause**: Not logged in to Azure.

**Solution**:
```powershell
Connect-AzAccount
Select-AzSubscription -SubscriptionName "Your Lab Subscription"
```

### Error: "Insufficient permissions"
**Cause**: Your account doesn't have Owner/UAA role at subscription level.

**Solution**: Ask subscription Owner to run the script or grant you Owner role.

### Re-running Scripts
Both scripts are **idempotent**:
- Resource groups: Skips if already exists
- RBAC assignments: Skips if already assigned
- Safe to re-run after failures

---

## Cost Management

### Tagging for Cost Tracking
All resource groups are tagged with:
- `Student: ST{N}` - Student identifier
- `Purpose: Student Lab Environment`
- `CostCenter: Education`

Use Azure Cost Management to track spending per student using these tags.

---

## Resource Quotas

### Per-Student Quotas (Automatic ✅)

Built-in validation in deployment scripts enforces:
- **Max 1 VM** per student's customimage resource group
- **Max 1 VNet** per student's spoke resource group

Students receive clear error messages if they try to exceed quotas.

### Subscription-Wide Quotas (Safety Net)

Use `Set-SubscriptionQuotas.ps1` to view and manage subscription-level limits:

```powershell
# View current quota usage
.\Set-SubscriptionQuotas.ps1 -ViewCurrentQuotas -Region "southcentralus"

# Check if current quotas support 30 students
.\Set-SubscriptionQuotas.ps1 -MaxVMs 35 -MaxVCPUs 140 -MaxVNets 35

# Results show if Azure Support ticket needed for increases
```

**Recommended Subscription Quotas for 30 Students:**
| Resource | Recommended | Calculation |
|----------|-------------|-------------|
| VMs | 35 | 30 students + 5 buffer |
| vCPUs | 140 | 30 × 4 vCPUs + 20 buffer |
| VNets | 35 | 30 students + 5 hub/shared |
| Public IPs | 40 | Temporary for image builds |

**Note**: Quota increases require Azure Support ticket and take 1-3 business days.

See `RESOURCE-QUOTAS-GUIDE.md` for detailed information.

---

## Budget Alerts
Set budget alerts at subscription level with filtering by `Student` tag.

---

## Next Steps

After configuring students:

1. **Deploy Spoke Networks** (per student):
   ```powershell
   cd ../4_W365
   .\deploy.ps1 -StudentNumber 5
   ```

2. **Provision Cloud PCs** (via Intune):
   - Assign students to provisioning policies
   - Use gallery or custom images as needed

---

## Migration Notes

### From Multi-Tenant to Multi-Student
This architecture is **not compatible** with the previous multi-tenant model. 

**Multi-Tenant (Old)**:
- Each student had their own Azure AD tenant
- Resource groups: `rg-w365-customimage`, `rg-w365-spoke-prod`
- Student was Owner of entire tenant

**Multi-Student (New)**:
- All students in single Azure AD tenant
- Resource groups: `rg-st{N}-customimage`, `rg-st{N}-spoke`
- Student is Contributor on their 2 resource groups only

**No automatic migration** - this is a greenfield deployment model for new labs.

---

## Files in This Directory

| File | Purpose | Status |
|------|---------|--------|
| `New-StudentResourceGroups.ps1` | Create student resource groups | ✅ Multi-Student |
| `Configure-StudentRBAC.ps1` | Configure RGs and RBAC for students | ✅ Multi-Student |
| `SubscriptionConfigure.ps1` | Legacy multi-tenant script | ⚠️ Deprecated |
| `Invoke-GraphUserCreation.ps1` | Helper for legacy script | ⚠️ Deprecated |
| `README-MultiStudent.md` | This file | ✅ Multi-Student |
| `README.md` | Original documentation | ⚠️ Legacy |

---

## Support & Documentation

- **OpenSpec Proposal**: `../openspec/changes/multi-student-single-subscription/`
- **Architecture Design**: `../openspec/changes/multi-student-single-subscription/design.md`
- **Project Documentation**: `../openspec/project.md`

---

## Change History

| Date | Change | Type |
|------|--------|------|
| 2025-11-06 | Created multi-student scripts (Phase 1) | New |
| 2025-11-06 | OpenSpec proposal approved | Architecture |
