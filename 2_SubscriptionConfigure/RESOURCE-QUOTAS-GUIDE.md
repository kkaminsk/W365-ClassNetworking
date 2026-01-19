# Student Resource Quota Enforcement Guide

## Overview

This document explains how to limit each student to create only the minimum required resources:
- **CustomImage RG**: Maximum 1 VM at a time (for image builds)
- **W365 Spoke RG**: Maximum 1 VNet (for Windows 365 network)

## ⚠️ Important: Azure Policy Limitations

**Azure Policy CANNOT enforce resource count quotas directly**. Azure Policy can:
- ✅ Audit resource creation
- ✅ Deny specific resource types entirely
- ✅ Enforce naming conventions
- ❌ **Cannot count existing resources and block based on count**

This is a known limitation of Azure Policy's evaluation model.

---

## 🎯 Recommended Approach: Built-In Validation

The **best solution** is to add resource count validation **directly into the deployment scripts**. This ensures students see clear error messages and cannot exceed limits.

### Implementation Status

| Script | Quota Validation | Status |
|--------|------------------|--------|
| `Deploy-W365CustomImage.ps1` | Max 1 VM in RG | ✅ **IMPLEMENTED** |
| `W365/deploy.ps1` | Max 1 VNet in RG | ✅ **IMPLEMENTED** |

---

## 📝 Solution 1: Script-Level Validation (RECOMMENDED)

### Advantages
- ✅ **Enforces limits immediately** before deployment starts
- ✅ **Clear error messages** explaining the limit to students
- ✅ **No additional Azure resources** or policies needed
- ✅ **Works reliably** without Azure Policy limitations
- ✅ **Graceful handling** - can allow deletion and recreation

### Implementation

Add these validation checks to the deployment scripts:

#### For `Deploy-W365CustomImage.ps1`:

```powershell
# Add after Azure context is established, before Bicep deployment

function Test-ResourceQuota {
    param(
        [string]$ResourceGroupName,
        [string]$ResourceType,
        [int]$MaxAllowed
    )
    
    Write-Log "Checking resource quota: $ResourceType (max: $MaxAllowed)" -Level Info
    
    $existingResources = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType $ResourceType -ErrorAction SilentlyContinue
    $currentCount = ($existingResources | Measure-Object).Count
    
    Write-Log "  Current count: $currentCount" -Level Info
    
    if ($currentCount -ge $MaxAllowed) {
        Write-Log "ERROR: Resource quota exceeded!" -Level Error
        Write-Log "  Resource Type: $ResourceType" -Level Error
        Write-Log "  Current: $currentCount / Max: $MaxAllowed" -Level Error
        Write-Log "  You must delete existing resources before creating new ones." -Level Error
        
        # List existing resources
        Write-Log "`nExisting resources:" -Level Warning
        $existingResources | ForEach-Object {
            Write-Log "  - $($_.Name)" -Level Warning
        }
        
        throw "Resource quota exceeded: Cannot create more than $MaxAllowed $ResourceType in $ResourceGroupName"
    }
    
    Write-Log "  ✓ Quota check passed" -Level Success
    return $true
}

# Check VM quota (max 1 VM per student customimage RG)
if ($isStudentMode) {
    Test-ResourceQuota -ResourceGroupName $ResourceGroupName `
        -ResourceType "Microsoft.Compute/virtualMachines" `
        -MaxAllowed 1
}
```

#### For `W365/deploy.ps1`:

```powershell
# Add to Test-Deployment function or after context establishment

function Test-VNetQuota {
    param([string]$ResourceGroupName)
    
    Write-Host "Checking VNet quota (max: 1)..." -ForegroundColor Yellow
    
    try {
        # Get resource group
        $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        if (-not $rg) {
            Write-Host "✓ Resource group doesn't exist yet - quota check passed" -ForegroundColor Green
            return $true
        }
        
        # Count existing VNets
        $existingVNets = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        $vnetCount = ($existingVNets | Measure-Object).Count
        
        Write-Host "  Current VNets: $vnetCount" -ForegroundColor Gray
        
        if ($vnetCount -ge 1) {
            Write-Host "`nERROR: VNet quota exceeded!" -ForegroundColor Red
            Write-Host "  Maximum allowed: 1 VNet per resource group" -ForegroundColor Red
            Write-Host "  Current count: $vnetCount" -ForegroundColor Red
            Write-Host "`nExisting VNets:" -ForegroundColor Yellow
            $existingVNets | ForEach-Object {
                Write-Host "  - $($_.Name) ($($_.AddressSpace.AddressPrefixes -join ', '))" -ForegroundColor Yellow
            }
            Write-Host "`nYou must delete the existing VNet before creating a new one." -ForegroundColor Yellow
            Write-Host "Command: Remove-AzVirtualNetwork -Name <vnet-name> -ResourceGroupName $ResourceGroupName -Force" -ForegroundColor Cyan
            
            return $false
        }
        
        Write-Host "✓ VNet quota check passed" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "WARNING: Quota check failed - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Continuing with deployment..." -ForegroundColor Yellow
        return $true  # Don't block deployment on check failure
    }
}

# Add before deployment validation
if ($isStudentMode) {
    if (-not (Test-VNetQuota -ResourceGroupName $rgName)) {
        throw "VNet quota exceeded. Cannot proceed with deployment."
    }
}
```

---

## 📋 Solution 2: Azure Resource Locks (Partial Solution)

### Use Case
Prevent students from **deleting** critical resources (VNet, NSGs) after creation.

### Implementation

```powershell
# After VNet is created, apply a read-only lock
$vnet = Get-AzVirtualNetwork -ResourceGroupName "rg-st5-spoke" -Name "vnet-st5-spoke"
New-AzResourceLock -LockName "DoNotDelete-VNet" `
    -LockLevel CanNotDelete `
    -ResourceId $vnet.Id `
    -LockNotes "Windows 365 requires this VNet - do not delete" `
    -Force
```

**Limitations**: This prevents deletion but doesn't prevent creating additional VNets.

---

## 📋 Solution 3: Azure Subscription Quotas (Subscription-Wide)

### Overview
Use Azure's quota system to set subscription-level limits per region as an additional safety mechanism.

### Implementation

Use the provided script to view and manage subscription quotas:

```powershell
# View current quota usage
.\Set-SubscriptionQuotas.ps1 -ViewCurrentQuotas -Region "southcentralus"

# Set recommended quotas for 30-student lab
.\Set-SubscriptionQuotas.ps1 -Region "southcentralus" -MaxVMs 35 -MaxVCPUs 140 -MaxVNets 35 -MaxPublicIPs 40
```

### What the Script Does

1. **Views Current Quota Usage** - Shows a dashboard with current/limit/percentage
2. **Checks Requested Limits** - Compares requested quotas against current limits
3. **Provides Guidance** - Tells you if Azure Support ticket is needed
4. **Color-Coded Dashboard** - Green (<60%), Yellow (60-80%), Red (>80%)

### Example Output

```
========================================
Azure Quota Dashboard - southcentralus
========================================

📊 COMPUTE QUOTAS
─────────────────────────────────────────
Virtual Machines:      8 / 100 (8.0%)
Total vCPUs:           32 / 350 (9.14%)
DSv3 Family vCPUs:     16 / 100 (16.0%)

🌐 NETWORK QUOTAS
─────────────────────────────────────────
Virtual Networks:      5 / 1000 (0.5%)
Public IP Addresses:   3 / 1000 (0.3%)
Network Security Groups: 8 / 5000 (0.16%)

========================================
Legend: < 60% = Good | 60-80% = Warning | > 80% = Critical
========================================
```

### Recommended Quotas for 30-Student Lab

| Resource | Recommended Limit | Calculation |
|----------|------------------|-------------|
| Virtual Machines | **35** | 30 students + 5 buffer |
| Total vCPUs | **140** | 30 × 4 vCPUs + 20 buffer |
| Virtual Networks | **35** | 30 students + 5 hub/shared |
| Public IPs | **40** | Temporary for image builds |

### Limitations
- ❌ **Cannot scope to individual resource groups** - applies to entire subscription in region
- ❌ **Cannot enforce per-student limits** - only total subscription limits
- ⚠️ **Quota increases require Azure Support ticket** - cannot be automated
- ⏱️ **Changes take 1-3 business days** through Azure Support
- ✅ **Good as safety net** - prevents subscription-wide runaway costs

### When to Use This

Use subscription quotas as a **secondary safety mechanism**:
- ✅ Prevents accidental deployment of 100+ VMs subscription-wide
- ✅ Catches bulk provisioning errors
- ✅ Provides overall cost protection
- ❌ Does NOT replace per-student script validation

**Recommendation**: Use BOTH approaches together:
1. **Per-student script validation** (primary enforcement)
2. **Subscription quotas** (safety net)

---

## 📋 Solution 4: Custom RBAC Role (Most Restrictive)

### Overview
Create a custom RBAC role that allows students to:
- ✅ Read all resources
- ✅ Create/manage VMs (but only in customimage RG)
- ✅ Create/manage VNets (but only in spoke RG)
- ❌ Cannot create multiple of the same resource type

### Example Custom Role

```json
{
  "Name": "Student Custom Image Builder",
  "IsCustom": true,
  "Description": "Allows building custom images with resource limits",
  "Actions": [
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachines/write",
    "Microsoft.Compute/virtualMachines/delete",
    "Microsoft.Compute/images/*",
    "Microsoft.Network/*/read",
    "Microsoft.Network/networkInterfaces/*",
    "Microsoft.Network/publicIPAddresses/*",
    "Microsoft.ManagedIdentity/*/read"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "/subscriptions/{subscription-id}/resourceGroups/rg-st{N}-customimage"
  ]
}
```

### Limitations
- ❌ **Very complex to implement and maintain**
- ❌ **Still doesn't enforce count limits** (RBAC can't count resources)
- ❌ Students can still create multiple VMs/VNets if they have create permission
- ✅ Only useful for limiting *types* of resources, not counts

**Not recommended** - doesn't solve the count problem.

---

## ✅ RECOMMENDED IMPLEMENTATION

Based on Azure's limitations, here's the recommended approach:

### 1. **Add Quota Validation to Scripts** (Immediate enforcement)

Modify these scripts with the code examples above:
- ✅ `CustomImage/Deploy-W365CustomImage.ps1` - Check VM count before deployment
- ✅ `W365/deploy.ps1` - Check VNet count before deployment

**Benefits**:
- Immediate feedback to students
- Clear error messages
- No additional Azure resources
- Works reliably every time

### 2. **Apply Resource Locks** (Prevent accidental deletion)

After resources are created, lock them:
```powershell
# Lock VNet (prevents accidental deletion)
New-AzResourceLock -LockName "DoNotDelete-VNet" `
    -LockLevel CanNotDelete `
    -ResourceId $vnetId `
    -Force
```

### 3. **Monitor with Azure Policy** (Auditing only)

Use the `Set-StudentResourceQuotas.ps1` script to create **audit** policies:
```powershell
.\Set-StudentResourceQuotas.ps1 -ConfigureAllStudents -TotalStudents 30
```

This creates policies that **audit** (not deny) resource creation for monitoring.

### 4. **Regular Compliance Checks** (Instructor monitoring)

Create a monitoring script to check for quota violations:

```powershell
# Check-StudentCompliance.ps1
1..30 | ForEach-Object {
    $customImageRg = "rg-st$_-customimage"
    $spokeRg = "rg-st$_-spoke"
    
    # Check VM count
    $vms = Get-AzVM -ResourceGroupName $customImageRg -ErrorAction SilentlyContinue
    if ($vms.Count -gt 1) {
        Write-Host "⚠ Student $_ has $($vms.Count) VMs (limit: 1)" -ForegroundColor Yellow
    }
    
    # Check VNet count
    $vnets = Get-AzVirtualNetwork -ResourceGroupName $spokeRg -ErrorAction SilentlyContinue
    if ($vnets.Count -gt 1) {
        Write-Host "⚠ Student $_ has $($vnets.Count) VNets (limit: 1)" -ForegroundColor Yellow
    }
}
```

---

## 🎓 Student Communication

Clearly communicate the limits to students in lab instructions:

> **Resource Quotas**
>
> Each student lab environment has resource limits:
> - **CustomImage Resource Group**: Maximum 1 VM at a time
> - **Spoke Resource Group**: Maximum 1 VNet
>
> If you need to rebuild:
> 1. Delete the existing resource first
> 2. Run the deployment script again
>
> The deployment script will check quotas and prevent creation if limits are exceeded.

---

## 📊 Summary Matrix

| Method | Enforces Per-Student? | Enforces Subscription? | Complexity | Recommended? |
|--------|---------------------|----------------------|------------|--------------|
| **Script Validation** | ✅ Yes | ❌ No | Low | ✅ **PRIMARY** |
| **Subscription Quotas** | ❌ No | ✅ Yes | Low | ✅ **SAFETY NET** |
| Azure Policy | ❌ No | ❌ No (audit only) | Medium | ⚠️ Monitoring |
| Resource Locks | ❌ No | ❌ No | Low | ⚠️ Prevent delete |
| Custom RBAC | ❌ No | ❌ No | High | ❌ No |

**Final Recommendation**: Implement **BOTH** for layered protection:
1. **Script-level validation** (per-student enforcement) - PRIMARY
2. **Subscription quotas** (subscription-wide safety net) - SECONDARY

---

## 🚀 Next Steps

### Phase 1: Per-Student Enforcement ✅ **COMPLETE**
1. ✅ **`Deploy-W365CustomImage.ps1`** - VM count validation implemented
2. ✅ **`W365/deploy.ps1`** - VNet count validation implemented
3. ✅ **`STUDENT-DEPLOYMENT-GUIDE.md`** - Quota documentation added
4. ⏭️ **Test with students** to ensure clear error messages

### Phase 2: Subscription-Wide Safety Net (New Script ✅)
1. ✅ **`Set-SubscriptionQuotas.ps1`** - View and manage subscription quotas
2. ⏭️ **Run quota check** before lab starts:
   ```powershell
   .\Set-SubscriptionQuotas.ps1 -ViewCurrentQuotas -Region "southcentralus"
   ```
3. ⏭️ **Request quota increases** if needed (via Azure Support)
4. ⏭️ **Set monitoring alerts** for quota usage approaching 80%

### Phase 3: Optional Enhancements
5. **Optionally**: Add resource locks to critical resources after creation
6. **Optionally**: Create monitoring script to check for quota violations daily
7. **Optionally**: Set up Azure Monitor alerts for quota usage

This provides **layered protection** with both per-student and subscription-wide enforcement.
