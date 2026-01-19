# Student Deployment Guide - Multi-Student Lab Environment

Complete guide for deploying Windows 365 lab environments for individual students in a single-subscription architecture.

## 🎯 Overview

This guide walks through deploying a complete Windows 365 environment for a single student, including:
- Resource group provisioning with RBAC isolation
- Custom image creation in student-specific gallery
- Spoke network deployment with hub peering
- Integration with Windows 365 provisioning

**Time to Complete**: ~90 minutes per student (mostly automated)

## 🔒 Resource Quotas (Per Student)

To ensure students can only create the resources needed for their labs, **automatic quota enforcement** is built into the deployment scripts:

| Resource Type | Resource Group | Maximum Allowed | Enforcement |
|--------------|----------------|-----------------|-------------|
| Virtual Machines | rg-st{N}-customimage | **1 VM** | ✅ Automatic |
| Virtual Networks | rg-st{N}-spoke | **1 VNet** | ✅ Automatic |

**How it works**:
- Deployment scripts check resource counts **before** creating new resources
- If quota exceeded, deployment stops with clear error message
- Students must delete existing resources before creating new ones
- Quotas only apply in **per-student mode** (not shared/legacy mode)

**Example Error Message**:
```
========================================
VM QUOTA EXCEEDED
========================================
Maximum allowed: 1 VM per resource group
Current count: 1

Existing VMs in rg-st5-customimage:
  - st5-build-vm-20251106... (Status: VM running)

ACTION REQUIRED:
1. Delete the existing VM before creating a new custom image:
   Remove-AzVM -Name 'st5-build-vm-...' -ResourceGroupName 'rg-st5-customimage' -Force
2. Or wait for the current image build to complete and auto-cleanup
```

---

## 📋 Prerequisites

Before deploying for any student, ensure these are in place:

### 1. Hub Landing Zone (One-Time Setup)
```powershell
cd 1_Hub
.\deploy.ps1
```

Creates:
- Hub VNet (`vnet-hub`: 10.10.0.0/20)
- Azure Firewall Standard
- Log Analytics Workspace
- Private DNS Zones

**Deployment Time**: ~15-20 minutes

### 2. Student Accounts (One-Time Setup)

Create student accounts in Azure AD:
- **Account Format**: `W365Student{N}@domain.com`
- **Example**: W365Student5@domain.com, W365Student10@domain.com
- **Range**: W365Student1 through W365Student30

These accounts can be created via Azure Portal, PowerShell, or your organization's provisioning process.

### 3. Azure Subscription & Quota Verification

- **Model**: Single subscription shared by all students
- **Required Permissions (for instructor)**:
  - Owner or Contributor at subscription level
  - User Access Administrator (for RBAC assignments)

#### Verify Subscription Quotas (IMPORTANT!)

Before deploying students, check if your subscription can support 30 students:

```powershell
cd 2_SubscriptionConfigure

# View current quota usage
.\Set-SubscriptionQuotas.ps1 -ViewCurrentQuotas -Region "southcentralus"

# Check if quotas support 30 students
.\Set-SubscriptionQuotas.ps1 -MaxVMs 35 -MaxVCPUs 140 -MaxVNets 35 -MaxPublicIPs 40
```

**Recommended Subscription Quotas:**
| Resource | Minimum Required | Why |
|----------|-----------------|-----|
| Virtual Machines | 35 | 30 students + 5 buffer |
| Total vCPUs | 140 | 30 × 4 vCPUs + buffer |
| Virtual Networks | 35 | 30 spokes + 5 hub/shared |
| Public IPs | 40 | Temporary for builds |

**If quotas need increase**: The script will provide instructions to request increases via Azure Support (1-3 business days).

---

## 🚀 Student Deployment Workflow

Follow these steps **for each student** (e.g., Student 5):

### Step 1: Provision Resource Groups and RBAC (5 minutes)

Create the student's resource groups and assign permissions:

```powershell
cd 2_SubscriptionConfigure

# Single student
.\Configure-StudentRBAC.ps1 -StudentNumber 5

# Or all students at once (recommended for initial setup)
.\Configure-StudentRBAC.ps1 -ConfigureAllStudents -TotalStudents 30
```

**What this does**:
- Creates `rg-st5-customimage` (for custom images)
- Creates `rg-st5-spoke` (for Windows 365 network)
- Assigns **Contributor** role to W365Student5@domain.com on both RGs
- Registers required Azure resource providers
- Tags resources with `Student: ST5`

**Validation**:
```powershell
# Check resource groups
Get-AzResourceGroup -Name "rg-st5-*" | Select-Object ResourceGroupName, Location, Tags

# Check RBAC assignments
Get-AzRoleAssignment -ResourceGroupName "rg-st5-customimage" | Where-Object {$_.SignInName -like "*Student5*"}
```

---

### Step 2: Deploy Custom Image (30-60 minutes)

**Option A: Instructor Deploys (Recommended for First Image)**

```powershell
cd CustomImage

# Deploy custom image for Student 5
.\Deploy-W365CustomImage.ps1 -StudentNumber 5
```

**Option B: Student Deploys (Learning Exercise)**

Student logs in with their account (W365Student5@domain.com) and runs:

```powershell
cd CustomImage
.\Deploy-W365CustomImage.ps1 -StudentNumber 5
```

**What this does**:
1. Deploys build infrastructure in `rg-st5-customimage`
2. Creates VNet `vnet-st5-imagebuild` (temporary)
3. Deploys Windows 11 25H2 Enterprise VM
4. Installs applications (VSCode, Chrome, 7-Zip, Adobe Reader)
5. Runs Windows Updates
6. Executes sysprep
7. Captures managed image: `st5-custom-image-{timestamp}`
8. Cleans up temporary resources
9. Creates gallery: `st5gallery`

**Deployment Time**: 30-60 minutes (fully automated)

**Validation**:
```powershell
# Check managed images
Get-AzImage -ResourceGroupName "rg-st5-customimage" | Select-Object Name, ProvisioningState, HyperVGeneration

# View deployment log
Get-Content "$env:USERPROFILE\Documents\W365Customimage-*.log" | Select-Object -Last 50
```

---

### Step 3: Deploy Spoke Network (10 minutes)

Deploy the student's Windows 365 spoke network with automatic hub peering:

```powershell
cd W365

# Get hub VNet resource ID
$hubVnetId = (Get-AzVirtualNetwork -ResourceGroupName "rg-hub-net" -Name "vnet-hub").Id

# Deploy spoke for Student 5
.\deploy.ps1 -StudentNumber 5 -HubVnetResourceId $hubVnetId
```

**What this does**:
1. Creates VNet `vnet-st5-spoke` (10.1.5.0/24) in `rg-st5-spoke`
2. Creates subnets:
   - `snet-st5-cloudpc`: 10.1.5.0/26 (62 usable IPs)
   - `snet-st5-mgmt`: 10.1.5.64/26 (62 usable IPs)
   - `snet-st5-avd`: 10.1.5.128/26 (optional)
3. Creates Network Security Groups with Windows 365 rules
4. Configures service endpoints (Storage, KeyVault)
5. **Automatically peers** `vnet-st5-spoke` to `vnet-hub`

**Deployment Time**: ~10 minutes

**Validation**:
```powershell
# Check VNet
Get-AzVirtualNetwork -ResourceGroupName "rg-st5-spoke" -Name "vnet-st5-spoke" | Select-Object Name, AddressSpace, Subnets

# Check peering
Get-AzVirtualNetworkPeering -VirtualNetworkName "vnet-st5-spoke" -ResourceGroupName "rg-st5-spoke"

# Test connectivity (from a VM in the hub or spoke)
Test-NetConnection -ComputerName 10.1.5.4 -Port 443
```

---

### Step 4: Configure Windows 365 (15 minutes)

Configure Windows 365 to use the student's custom image and network:

#### A. Create Azure Network Connection

1. Open **Microsoft Intune Admin Center** (https://intune.microsoft.com)
2. Navigate to **Devices** → **Windows 365** → **Azure network connection**
3. Click **Create connection**
4. Configure:
   - **Name**: `ANC-ST5-Spoke`
   - **Subscription**: Your subscription
   - **Resource Group**: `rg-st5-spoke`
   - **Virtual Network**: `vnet-st5-spoke`
   - **Subnet**: `snet-st5-cloudpc`
   - **Domain Join Type**: Azure AD Join (or Hybrid if needed)
5. Click **Create** and wait for health check (~5-10 minutes)

**Validation**: Connection status shows **Checks successful**

#### B. Create Provisioning Policy

1. In Intune, navigate to **Devices** → **Windows 365** → **Provisioning policies**
2. Click **Create policy**
3. Configure:
   - **Name**: `ST5-Windows365-Policy`
   - **Image type**: **Custom image**
   - **Image**: Select `st5-custom-image-{timestamp}` from `rg-st5-customimage`
   - **Azure network connection**: `ANC-ST5-Spoke`
   - **License**: Windows 365 Enterprise (2vCPU/4GB or higher)
4. **Assign** to Student 5's user or group
5. Click **Create**

**Validation**: Policy appears in list with correct image and network connection

---

### Step 5: Provision Cloud PC (20 minutes)

Cloud PC is automatically provisioned when student is licensed and assigned:

1. Assign Windows 365 license to W365Student5@domain.com
2. Wait for automatic provisioning (~15-20 minutes)
3. Monitor status in Intune → **Devices** → **Windows 365** → **All Cloud PCs**

**Student Access**:
- Web: https://windows365.microsoft.com
- Windows 365 app
- Remote Desktop client

---

## 📊 Student Environment Summary

After completion, Student 5 has:

| Resource Type | Name | Address Space | Purpose |
|---------------|------|---------------|---------|
| Resource Group | rg-st5-customimage | N/A | Custom image gallery |
| Resource Group | rg-st5-spoke | N/A | Windows 365 network |
| Gallery | st5gallery | N/A | Custom image storage |
| Custom Image | st5-custom-image-{timestamp} | N/A | Windows 11 custom build |
| VNet | vnet-st5-spoke | 10.1.5.0/24 | Spoke network |
| Subnet | snet-st5-cloudpc | 10.1.5.0/26 | Cloud PC subnet (62 IPs) |
| Subnet | snet-st5-mgmt | 10.1.5.64/26 | Management subnet |
| Peering | vnet-st5-spoke → vnet-hub | N/A | Hub connectivity |
| RBAC | Contributor on RGs | N/A | Student access |

---

## 🔄 Deploying Multiple Students

### Batch Provisioning (Recommended)

For initial lab setup, provision all students at once:

```powershell
# Step 1: Provision all resource groups and RBAC (5 minutes)
cd 2_SubscriptionConfigure
.\Configure-StudentRBAC.ps1 -ConfigureAllStudents -TotalStudents 30

# Step 2: Deploy custom images (can be done in parallel or sequentially)
cd CustomImage
1..30 | ForEach-Object {
    Write-Host "Deploying custom image for Student $_" -ForegroundColor Cyan
    .\Deploy-W365CustomImage.ps1 -StudentNumber $_
}

# Step 3: Deploy spoke networks for all students
cd W365
$hubVnetId = (Get-AzVirtualNetwork -ResourceGroupName "rg-hub-net" -Name "vnet-hub").Id
1..30 | ForEach-Object {
    Write-Host "Deploying spoke for Student $_" -ForegroundColor Cyan
    .\deploy.ps1 -StudentNumber $_ -HubVnetResourceId $hubVnetId
}
```

**Total Time**:
- Resource Groups: ~5 minutes
- Custom Images: ~30-60 minutes per student (can run 3-5 in parallel)
- Spoke Networks: ~10 minutes per student (can run in parallel)

### Parallel Deployment

To speed up deployment, run multiple students in parallel using PowerShell jobs:

```powershell
# Deploy custom images for students 1-5 in parallel
cd CustomImage
$students = 1..5
$jobs = $students | ForEach-Object {
    Start-Job -ScriptBlock {
        param($StudentNum)
        & ".\Deploy-W365CustomImage.ps1" -StudentNumber $StudentNum
    } -ArgumentList $_
}

# Wait for all jobs to complete
$jobs | Wait-Job | Receive-Job
```

---

## 🔍 Troubleshooting

### Issue: "User not found: W365Student5@domain.com"

**Cause**: Student account doesn't exist in Azure AD.

**Fix**: Create the student account first:
```powershell
# Via Azure AD PowerShell
New-AzureADUser -DisplayName "Windows 365 Student 5" -UserPrincipalName "W365Student5@domain.com" -PasswordProfile $passwordProfile -AccountEnabled $true
```

### Issue: "Resource group 'rg-st5-spoke' not found"

**Cause**: Step 1 (Configure-StudentRBAC.ps1) was skipped or failed.

**Fix**: Run Step 1 to create resource groups:
```powershell
.\Configure-StudentRBAC.ps1 -StudentNumber 5
```

### Issue: "Custom image not visible in Windows 365"

**Cause**: Image and network connection in different regions, or missing permissions.

**Fix**:
1. Verify image and network are in same region
2. Check Windows 365 service principal permissions:
   ```powershell
   cd CustomImage
   .\check-W365permissions.ps1
   ```

### Issue: "Network connection health check failed"

**Cause**: Network configuration issue or missing DNS resolution.

**Fix**:
1. Verify spoke-to-hub peering exists:
   ```powershell
   Get-AzVirtualNetworkPeering -VirtualNetworkName "vnet-st5-spoke" -ResourceGroupName "rg-st5-spoke"
   ```
2. Check NSG rules allow required traffic
3. Review Azure Network Connection health check logs in Intune

### Issue: "Address space conflict"

**Cause**: Manual address space configuration overlaps with student ranges.

**Fix**: Don't manually specify address spaces in per-student mode. The script automatically calculates `10.1.{N}.0/24`.

### Issue: "Quota exceeded" at subscription level

**Cause**: Subscription has reached Azure quota limits for VMs, vCPUs, or VNets.

**Fix**:
1. Check current quota usage:
   ```powershell
   cd 2_SubscriptionConfigure
   .\Set-SubscriptionQuotas.ps1 -ViewCurrentQuotas
   ```
2. If quotas are insufficient, request increases via Azure Support:
   - The script provides step-by-step instructions
   - Typical approval time: 1-3 business days
3. Alternatively, delete unused resources from other students to free up quota

### Issue: "VM quota exceeded" for individual student

**Cause**: Student trying to create a 2nd VM when 1 already exists in their resource group.

**Fix**: 
This is expected behavior - quotas limit students to 1 VM at a time. Student should:
1. Wait for current image build to complete and auto-cleanup
2. Or manually delete the existing VM:
   ```powershell
   Remove-AzVM -Name 'st5-build-vm-...' -ResourceGroupName 'rg-st5-customimage' -Force
   ```

### Issue: "VNet quota exceeded" for individual student

**Cause**: Student trying to create a 2nd VNet when 1 already exists in their spoke resource group.

**Fix**:
This is expected behavior - quotas limit students to 1 VNet. Student should:
1. Keep the existing VNet (don't redeploy unless necessary)
2. Or manually delete to recreate:
   ```powershell
   Remove-AzVirtualNetwork -Name 'vnet-st5-spoke' -ResourceGroupName 'rg-st5-spoke' -Force
   ```

---

## 📚 Additional Resources

- **Multi-Student Setup**: `../2_SubscriptionConfigure/README-MultiStudent.md`
- **Resource Quotas Guide**: `../2_SubscriptionConfigure/RESOURCE-QUOTAS-GUIDE.md`
- **Custom Image Guide**: `../CustomImage/README.md`
- **W365 Spoke Network**: `../W365/README.md`
- **OpenSpec Design**: `../openspec/changes/multi-student-single-subscription/design.md`

---

## ✅ Deployment Checklist

Use this checklist for each student:

### Pre-Deployment
- [ ] Hub landing zone deployed
- [ ] Subscription quotas verified (use Set-SubscriptionQuotas.ps1)
- [ ] Student account created (W365Student{N}@domain.com)
- [ ] Windows 365 licenses available

### Student Deployment
- [ ] Step 1: Resource groups and RBAC configured
- [ ] Step 2: Custom image deployed
- [ ] Step 3: Spoke network deployed with hub peering
- [ ] Step 4: Azure Network Connection created and healthy
- [ ] Step 5: Provisioning policy created and assigned
- [ ] Step 6: Cloud PC provisioned and accessible

### Validation
- [ ] Student can sign in to https://windows365.microsoft.com
- [ ] Cloud PC shows in Intune
- [ ] Student has access to their resource groups only
- [ ] Network connectivity working (hub and internet)
- [ ] Custom applications installed and working

---

## 📊 Ongoing Monitoring & Maintenance

### Weekly Quota Check

Monitor subscription quota usage to catch issues early:

```powershell
cd 2_SubscriptionConfigure
.\Set-SubscriptionQuotas.ps1 -ViewCurrentQuotas -Region "southcentralus"
```

**Action if usage > 80%** (red):
- Review and cleanup unused resources
- Check for orphaned VMs or VNets
- Consider requesting quota increase if legitimate growth

### Resource Cleanup Commands

Remove resources for a specific student:

```powershell
# List all resources for a student
Get-AzResource -ResourceGroupName "rg-st5-*"

# Remove custom image resources (keeps images)
Remove-AzVM -Name "st5-build-vm-*" -ResourceGroupName "rg-st5-customimage" -Force

# Remove entire student environment (WARNING: Deletes everything)
Remove-AzResourceGroup -Name "rg-st5-customimage" -Force
Remove-AzResourceGroup -Name "rg-st5-spoke" -Force
```

### Cost Monitoring

Track costs per student using tags:

```powershell
# View costs by student tag
Get-AzConsumptionUsageDetail -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) | 
    Where-Object {$_.Tags.Student -like "ST*"} | 
    Group-Object -Property {$_.Tags.Student} | 
    Select-Object Name, @{N='Cost';E={($_.Group | Measure-Object -Property PretaxCost -Sum).Sum}}
```

Or use Azure Cost Management in the portal with tag filtering.

---

**Ready to deploy?** Start with Step 1 for your first student! 🚀
