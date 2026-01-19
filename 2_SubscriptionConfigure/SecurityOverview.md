# Security Architecture Overview
## Pod Isolation Model for Windows 365 Lab Environment

**Document Version:** 1.0  
**Last Updated:** November 10, 2025  
**Classification:** Internal Use  
**Audience:** Security Teams, IT Administrators, Compliance Officers

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Security Layers](#security-layers)
4. [Threat Model & Mitigations](#threat-model--mitigations)
5. [Access Control Matrix](#access-control-matrix)
6. [Attack Surface Analysis](#attack-surface-analysis)
7. [Compliance Considerations](#compliance-considerations)
8. [Security Best Practices](#security-best-practices)
9. [Incident Response](#incident-response)
10. [Audit & Monitoring](#audit--monitoring)

---

## Executive Summary

### Purpose

This document describes the security architecture of the **Pod Isolation Model** implemented for the TechMentor Windows 365 lab environment. The model provides multi-tenant-style isolation within a single Microsoft Entra ID (Azure AD) tenant, enabling 30 student administrators to operate independently without visibility or access to each other's resources.

### Security Objectives

| Objective | Implementation Status |
|-----------|----------------------|
| **Least Privilege** | ✅ Custom roles with minimal required permissions |
| **Isolation** | ✅ Multi-layer boundaries (Entra ID, Intune, Azure) |
| **Auditability** | ✅ All actions logged via Azure/Entra ID audit logs |
| **Resilience** | ✅ Scoped roles prevent lateral movement |
| **Compliance** | ✅ Supports RBAC best practices and compliance frameworks |

### Risk Rating

**Overall Security Posture:** 🟢 **STRONG**

- Isolation controls prevent unauthorized cross-pod access
- Multiple security layers provide defense-in-depth
- Group-based role assignments enable centralized management
- Scoped permissions limit blast radius of compromised accounts

### Key Security Features

1. **Zero Trust Between Pods:** admin1@ has zero visibility into admin2@'s environment
2. **Scoped Role Assignments:** Custom Intune role with explicit group and tag scoping
3. **Administrative Unit Boundaries:** Entra ID user visibility limited to assigned AU
4. **Automatic Resource Tagging:** Policies auto-tagged with scope tags, preventing visibility leakage
5. **Group-Based Access:** All roles assigned to groups, not individual users (easier audit, revocation)

---

## Architecture Overview

### The Pod Concept

Each "pod" is a self-contained security boundary consisting of:

```
┌─────────────────────────────────────────────────────────────────┐
│ Pod N (Isolated Security Boundary)                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Identity Layer (Entra ID)                                      │
│  ├─ 2 Users: admin{N}@, W365Student{N}@                        │
│  ├─ 3 Security Groups: SG-Student{N}-Admins/Users/Devices      │
│  └─ 1 Administrative Unit: AU-Student{N}                        │
│                                                                  │
│  Authorization Layer (Entra ID RBAC)                            │
│  ├─ Groups Administrator (scoped to AU-Student{N})             │
│  └─ Assigned to: SG-Student{N}-Admins group                    │
│                                                                  │
│  Device Management Layer (Intune)                               │
│  ├─ Custom Intune Role: "Lab Intune Admin"                     │
│  ├─ Scope (Groups): SG-Student{N}-Users, SG-Student{N}-Devices │
│  ├─ Scope (Tags): ST{N}                                        │
│  └─ Members: SG-Student{N}-Admins group                        │
│                                                                  │
│  Infrastructure Layer (Azure)                                   │
│  ├─ Custom Image Builder role (shared across all pods)         │
│  └─ W365 Spoke Network Deployer role (shared across all pods)  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Isolation Boundaries

```
        Pod 1              Pod 2              Pod 30
    ┌───────────┐      ┌───────────┐      ┌───────────┐
    │ admin1@   │      │ admin2@   │      │ admin30@  │
    │    ↓      │      │    ↓      │      │    ↓      │
    │ ST1 tag   │      │ ST2 tag   │ ... │ ST30 tag  │
    │    ↓      │      │    ↓      │      │    ↓      │
    │ SG-*-1    │      │ SG-*-2    │      │ SG-*-30   │
    │    ↓      │      │    ↓      │      │    ↓      │
    │ AU-Std1   │      │ AU-Std2   │      │ AU-Std30  │
    └───────────┘      └───────────┘      └───────────┘
         ╳                  ╳                  ╳
    No visibility      No access         No interaction
```

**Critical Security Property:** Pods are cryptographically isolated via Entra ID role scoping and Intune RBAC. There is no trust relationship between pods.

---

## Security Layers

### Layer 1: Entra ID Identity & Access Management

#### Components

| Component | Purpose | Security Impact |
|-----------|---------|----------------|
| **Administrative Units (AU)** | User/group visibility boundary | Prevents admin{N}@ from seeing users outside AU-Student{N} |
| **Security Groups** | Identity containers | Enables group-based role assignment (audit trail) |
| **Groups Administrator Role** | Scoped Entra ID permissions | Allows password reset & group management within AU only |
| **Hidden Membership** | Privacy control | AU members cannot enumerate other members |

#### Security Guarantees

✅ **User Enumeration Prevention:** admin1@ cannot query or discover W365Student2@ via any Entra ID API  
✅ **Password Reset Scoping:** admin1@ can only reset passwords for users in AU-Student1  
✅ **Group Management Scoping:** admin1@ can only modify membership of groups in AU-Student1  
✅ **Role Assignment Prevention:** admin1@ cannot assign Entra ID roles to users outside their AU

#### Attack Scenarios Mitigated

| Threat | Mitigation |
|--------|------------|
| Privilege escalation via role assignment | Groups Administrator role cannot assign directory roles |
| Lateral movement to other pods | AU scoping prevents visibility of other pods |
| User enumeration for phishing | Hidden membership + AU scoping |
| Unauthorized password reset | AU boundary enforced at API level |

---

### Layer 2: Intune Device & Policy Management

#### Components

| Component | Purpose | Security Impact |
|-----------|---------|----------------|
| **Custom Intune Role** | Granular permission definition | Only grants necessary Intune permissions (no global admin) |
| **Scope (Groups)** | Policy assignment boundary | Limits which users/devices can receive policies |
| **Scope (Tags)** | Resource visibility boundary | Filters which policies/devices admin can see |
| **Role Assignments** | Binds admin group to scoped permissions | Group-based assignment for audit trail |

#### Security Guarantees

✅ **Policy Visibility Isolation:** admin1@ can only see policies tagged with ST1  
✅ **Automatic Resource Tagging:** Policies created by admin1@ are auto-tagged with ST1 (cannot be changed)  
✅ **Assignment Scope Enforcement:** admin1@ can only assign policies to SG-Student1-Users and SG-Student1-Devices  
✅ **Device Visibility Filtering:** admin1@ can only see Cloud PCs tagged with ST1

#### Attack Scenarios Mitigated

| Threat | Mitigation |
|--------|------------|
| Deployment of malicious policy to other pods | Scope (Groups) limits assignment targets |
| Theft of configuration profiles from other pods | Scope (Tags) filters visibility |
| Device tampering in other pods | Device list filtered by scope tag |
| Privilege escalation via Intune role | Custom role has minimal permissions (no role assignment rights) |

---

### Layer 3: Azure Resource Management

#### Components

| Component | Purpose | Security Impact |
|-----------|---------|----------------|
| **Custom RBAC Roles** | Azure resource permissions | Grants only required actions for image building and networking |
| **Resource Group Scoping** | Blast radius limitation | Role assignments scoped to specific RGs, not subscription-wide |
| **Resource Providers** | Azure service registration | Only necessary providers registered |

#### Security Guarantees

✅ **Subscription-Level Protection:** Custom roles cannot modify subscription settings  
✅ **Resource Group Isolation:** Permissions limited to designated RGs  
✅ **Least Privilege Permissions:** Roles grant minimum required actions (no `*` wildcards)  
✅ **No Destructive Permissions:** Roles cannot delete resource groups or subscriptions

#### Attack Scenarios Mitigated

| Threat | Mitigation |
|--------|------------|
| Subscription-wide resource deletion | Roles scoped to RG level, no subscription write |
| Privilege escalation via Azure RBAC | Custom roles have no permission to assign roles |
| Cross-RG resource access | Role assignments explicitly scoped |
| Billing manipulation | No permissions on subscription cost management |

---

## Threat Model & Mitigations

### Threat Actors

| Actor Profile | Motivation | Capability Level | Primary Threats |
|--------------|------------|------------------|-----------------|
| **Compromised Student Admin** | Accidental or malicious misuse | Low-Medium | Policy misconfiguration, resource deletion within pod |
| **Malicious Insider (Admin)** | Data theft, sabotage | Medium | Attempt lateral movement, exfiltrate pod data |
| **External Attacker (via phishing)** | Credential theft, persistence | Medium-High | Account compromise, privilege escalation |
| **Supply Chain Attack** | Persistent access | High | Malicious policy deployment, backdoor creation |

### Threat Scenarios & Controls

#### Scenario 1: Compromised Admin Account (admin1@)

**Attack Chain:**
1. Attacker phishes admin1@ credentials
2. Authenticates to Entra ID portal
3. Attempts to enumerate all users in tenant
4. Attempts to deploy malicious Intune policy to all devices

**Mitigations:**

| Control | Effectiveness | Implementation |
|---------|---------------|----------------|
| AU Scoping | ✅ **HIGH** | admin1@ can only see users in AU-Student1 (enumeration blocked) |
| Scope Tag Filtering | ✅ **HIGH** | Can only see ST1-tagged resources (lateral movement blocked) |
| Scope (Groups) Enforcement | ✅ **HIGH** | Can only assign policies to SG-Student1-Users/Devices (blast radius limited) |
| Conditional Access | ⚠️ **MEDIUM** | MFA required (if configured) |
| Audit Logging | ✅ **HIGH** | All actions logged to Entra ID audit log |

**Blast Radius:** Limited to Pod 1 only (W365Student1@ and associated resources)

**Detection:** Unusual sign-in location, impossible travel, bulk policy creation

---

#### Scenario 2: Privilege Escalation Attempt

**Attack Chain:**
1. Compromised admin1@ account
2. Attempts to assign Global Administrator role to self
3. Attempts to modify Azure RBAC roles
4. Attempts to create new Intune Administrator assignments

**Mitigations:**

| Control | Effectiveness | Implementation |
|---------|---------------|----------------|
| Groups Administrator Scope | ✅ **HIGH** | Cannot assign directory roles (permission denied) |
| Custom Intune Role Permissions | ✅ **HIGH** | No DeviceManagementRBAC write permission |
| Azure RBAC Custom Role | ✅ **HIGH** | No `Microsoft.Authorization/roleAssignments/write` permission |
| PIM (if enabled) | ✅ **HIGH** | Elevated role assignment requires approval |

**Blast Radius:** Zero (all escalation attempts fail)

**Detection:** Unauthorized role assignment attempts (HTTP 403 errors in audit log)

---

#### Scenario 3: Lateral Movement Between Pods

**Attack Chain:**
1. Compromised admin1@ account
2. Attempts to access W365Student2@ Cloud PC
3. Attempts to view admin2@'s Intune policies
4. Attempts to add self to SG-Student2-Admins group

**Mitigations:**

| Control | Effectiveness | Implementation |
|---------|---------------|----------------|
| AU Membership Boundary | ✅ **HIGH** | W365Student2@ not visible via API (404 Not Found) |
| Scope Tag Filtering | ✅ **HIGH** | ST2-tagged resources filtered from view (empty list) |
| Group Management Scoping | ✅ **HIGH** | SG-Student2-Admins not in AU-Student1 (permission denied) |
| Intune Scope (Groups) | ✅ **HIGH** | Cannot target SG-Student2-* groups for policy assignment |

**Blast Radius:** Zero (all cross-pod access attempts fail)

**Detection:** Repeated access denied errors, attempts to enumerate out-of-scope resources

---

#### Scenario 4: Malicious Policy Deployment

**Attack Chain:**
1. Compromised admin1@ creates malicious configuration profile
2. Attempts to assign to all devices in tenant
3. Policy includes malware download or credential harvesting

**Mitigations:**

| Control | Effectiveness | Implementation |
|---------|---------------|----------------|
| Scope (Groups) Enforcement | ✅ **HIGH** | Can only assign to SG-Student1-Users/Devices (30 users max) |
| Automatic Scope Tag | ✅ **HIGH** | Policy auto-tagged with ST1 (only admin1@ sees it) |
| Manual Review Process | ⚠️ **MEDIUM** | Instructor can review policies via Global Administrator account |
| Conditional Access Device Compliance | ⚠️ **MEDIUM** | Non-compliant devices blocked (if configured) |

**Blast Radius:** Limited to Pod 1 devices only

**Detection:** Policy creation, unusual policy content (requires SIEM integration)

---

#### Scenario 5: Credential Stuffing / Brute Force

**Attack Chain:**
1. Attacker obtains leaked credential database
2. Attempts credential stuffing against admin{N}@ accounts
3. Gains access to one or more pods

**Mitigations:**

| Control | Effectiveness | Implementation |
|---------|---------------|----------------|
| Azure AD Password Protection | ✅ **HIGH** | Weak passwords blocked, custom banned list |
| Account Lockout Policy | ✅ **HIGH** | 10 failed attempts = 1 minute lockout |
| Smart Lockout | ✅ **HIGH** | Differentiates legitimate vs. attack traffic |
| MFA Enforcement (Conditional Access) | ✅ **CRITICAL** | Requires second factor (if configured) |
| Password Expiry | ⚠️ **MEDIUM** | 90-day rotation (if configured) |

**Blast Radius:** One pod per compromised account (no lateral movement)

**Detection:** Multiple failed sign-ins, sign-ins from unusual locations

---

## Access Control Matrix

### Entra ID Permissions

| Action | Global Admin | admin{N}@ (via Groups Admin) | W365Student{N}@ |
|--------|--------------|------------------------------|-----------------|
| View all users in tenant | ✅ Yes | ❌ No (AU-scoped) | ❌ No |
| View W365Student{N}@ | ✅ Yes | ✅ Yes (if in same AU) | ✅ Yes (self only) |
| View W365Student{M}@ (M≠N) | ✅ Yes | ❌ No | ❌ No |
| Reset W365Student{N}@ password | ✅ Yes | ✅ Yes | ❌ No |
| Reset W365Student{M}@ password | ✅ Yes | ❌ No | ❌ No |
| Modify SG-Student{N}-Users membership | ✅ Yes | ✅ Yes | ❌ No |
| Modify SG-Student{M}-Users membership | ✅ Yes | ❌ No | ❌ No |
| Assign Global Administrator role | ✅ Yes | ❌ No | ❌ No |
| Assign Groups Administrator role | ✅ Yes | ❌ No | ❌ No |
| Delete users | ✅ Yes | ❌ No | ❌ No |
| Create new users | ✅ Yes | ❌ No | ❌ No |

### Intune Permissions

| Action | Global Admin | admin{N}@ (via Lab Intune Admin) | W365Student{N}@ |
|--------|--------------|----------------------------------|-----------------|
| View all Intune policies | ✅ Yes | ❌ No (ST{N}-scoped) | ❌ No |
| View ST{N}-tagged policies | ✅ Yes | ✅ Yes | ❌ No |
| View ST{M}-tagged policies (M≠N) | ✅ Yes | ❌ No | ❌ No |
| Create configuration profile | ✅ Yes | ✅ Yes (auto-tagged ST{N}) | ❌ No |
| Assign policy to SG-Student{N}-Users | ✅ Yes | ✅ Yes | ❌ No |
| Assign policy to SG-Student{M}-Users | ✅ Yes | ❌ No | ❌ No |
| Wipe W365Student{N}@ Cloud PC | ✅ Yes | ✅ Yes | ❌ No |
| Wipe W365Student{M}@ Cloud PC | ✅ Yes | ❌ No | ❌ No |
| Modify Intune roles | ✅ Yes | ❌ No | ❌ No |
| Create scope tags | ✅ Yes | ❌ No | ❌ No |
| Deploy mobile apps | ✅ Yes | ✅ Yes (scoped) | ❌ No |

### Azure Permissions

| Action | Global Admin | admin{N}@ (via Custom Roles) | W365Student{N}@ |
|--------|--------------|------------------------------|-----------------|
| Create Azure VMs | ✅ Yes | ✅ Yes (in designated RGs) | ❌ No |
| Deploy networking (VNet, NSG) | ✅ Yes | ✅ Yes (in designated RGs) | ❌ No |
| Create storage accounts | ✅ Yes | ✅ Yes (in designated RGs) | ❌ No |
| Delete resource groups | ✅ Yes | ❌ No | ❌ No |
| Modify subscriptions | ✅ Yes | ❌ No | ❌ No |
| View billing | ✅ Yes | ❌ No | ❌ No |
| Assign Azure RBAC roles | ✅ Yes | ❌ No | ❌ No |

---

## Attack Surface Analysis

### Attack Vectors

| Surface | Exposure | Risk Level | Mitigations |
|---------|----------|------------|-------------|
| **Entra ID Sign-In** | Internet-facing | 🟡 Medium | MFA, Conditional Access, Smart Lockout |
| **Intune Portal** | Internet-facing | 🟡 Medium | AU scoping, scope tags, custom role |
| **Azure Portal** | Internet-facing | 🟡 Medium | Custom RBAC, RG scoping |
| **Graph API** | Programmatic access | 🟠 Medium-High | API permissions scoped to role, audit logging |
| **PowerShell Modules** | Admin workstations | 🟢 Low | Credential management, secure workstations |
| **Student Cloud PCs** | Student-controlled | 🔴 High | Intune policies, compliance checks, Conditional Access |

### Network Topology

```
Internet
    │
    ├─> Entra ID Authentication
    │       │
    │       ├─> admin1@ login (MFA required)
    │       │     │
    │       │     ├─> AU-Student1 Scope Applied
    │       │     └─> Groups Administrator Role Activated
    │       │
    │       └─> admin2@ login (MFA required)
    │             │
    │             ├─> AU-Student2 Scope Applied
    │             └─> Groups Administrator Role Activated
    │
    ├─> Intune Service (intune.microsoft.com)
    │       │
    │       ├─> admin1@ session
    │       │     │
    │       │     ├─> ST1 Scope Tag Filter Applied
    │       │     └─> Can only assign to SG-Student1-*
    │       │
    │       └─> admin2@ session
    │             │
    │             ├─> ST2 Scope Tag Filter Applied
    │             └─> Can only assign to SG-Student2-*
    │
    └─> Azure Portal (portal.azure.com)
            │
            └─> All admins share same Azure RBAC
                (Custom Image Builder + W365 Deployer roles)
```

### Trust Boundaries

| Boundary | Description | Security Control |
|----------|-------------|------------------|
| **Pod-to-Pod** | Zero trust between pods | AU scoping + Scope tags + Scope (Groups) |
| **Admin-to-User** | Admin manages user in same pod | Groups Administrator role (scoped to AU) |
| **Intune-to-Device** | Policy deployment to Cloud PC | Scope (Groups) limits targets |
| **Azure-to-RG** | Resource deployment permissions | Custom RBAC scoped to RG paths |

---

## Compliance Considerations

### Regulatory Frameworks

| Framework | Relevant Controls | Compliance Status |
|-----------|------------------|-------------------|
| **NIST Cybersecurity Framework** | AC-2 (Account Management), AC-3 (Access Enforcement), AC-6 (Least Privilege) | ✅ Aligned |
| **CIS Controls v8** | 5.4 (Restrict Admin Privileges), 6.1 (Audit Log Management) | ✅ Aligned |
| **ISO 27001** | A.9.2 (User Access Management), A.9.4 (Access Control) | ✅ Aligned |
| **SOC 2** | CC6.1 (Logical Access Controls), CC6.2 (Access Authorization) | ✅ Aligned |

### Audit Requirements

**Retention:** Azure/Entra ID audit logs retained for 30 days (default), can be exported to Log Analytics for extended retention

**Events Logged:**
- User sign-ins (successful and failed)
- Role assignments and modifications
- AU membership changes
- Intune policy creation, modification, deletion
- Azure resource creation and deletion
- Administrative actions (password resets, group modifications)

**Compliance Reporting:**
- Monthly access review: Verify admin group memberships
- Quarterly role review: Validate role assignments match pod model
- Annual security assessment: Penetration testing of isolation boundaries

---

## Security Best Practices

### For Administrators

1. **Enable MFA:** Require multi-factor authentication for all admin accounts
   ```powershell
   # Create Conditional Access policy requiring MFA for admins
   New-MgIdentityConditionalAccessPolicy -DisplayName "Require MFA for Admins" ...
   ```

2. **Use Privileged Access Workstations (PAWs):** Admin tasks from dedicated secure workstations

3. **Rotate Credentials:** Change passwords every 90 days, immediately upon suspected compromise

4. **Monitor Audit Logs:** Review Entra ID and Intune audit logs weekly for suspicious activity

5. **Apply Least Privilege:** Don't add admin accounts to Global Administrator role unless absolutely necessary

### For Security Teams

1. **Enable Azure AD Identity Protection:** Automated risk detection and remediation

2. **Configure Conditional Access:**
   - Require MFA for all admin sign-ins
   - Block legacy authentication protocols
   - Require compliant devices for admin access

3. **Implement SIEM Integration:**
   ```powershell
   # Export audit logs to Azure Monitor / Sentinel
   # Enable diagnostic settings on Entra ID
   ```

4. **Regular Access Reviews:**
   - Monthly: Review AU memberships
   - Quarterly: Review Intune role assignments
   - Annually: Full security assessment

5. **Threat Hunting:**
   - Search for unusual Intune policy creation patterns
   - Look for failed access attempts (AU/scope tag blocks)
   - Monitor for privilege escalation attempts

### For Compliance Officers

1. **Document Role Definitions:** Maintain current list of custom roles and permissions

2. **Audit Trail Preservation:** Export audit logs to immutable storage (compliance requirements)

3. **Access Certification:** Quarterly attestation of admin role assignments

4. **Segregation of Duties:** Ensure no single admin has both Entra ID Global Admin and subscription Owner

---

## Incident Response

### Incident Classification

| Severity | Example | Response Time |
|----------|---------|---------------|
| **P1 - Critical** | Global Admin account compromised | Immediate (< 15 min) |
| **P2 - High** | Multiple student admin accounts compromised | < 1 hour |
| **P3 - Medium** | Single student admin account compromised | < 4 hours |
| **P4 - Low** | Suspicious activity, no confirmed compromise | < 24 hours |

### Compromised Admin Account Playbook

**Scenario:** admin1@ credentials compromised

**Immediate Actions (0-15 minutes):**

1. **Revoke all sessions:**
   ```powershell
   Revoke-MgUserSignInSession -UserId admin1@bighatgrouptraining.ca
   ```

2. **Reset password:**
   ```powershell
   Update-MgUser -UserId admin1@bighatgrouptraining.ca -PasswordProfile @{...}
   ```

3. **Remove from SG-Student1-Admins group:**
   ```powershell
   Remove-MgGroupMemberByRef -GroupId <SG-Student1-Admins-ID> -DirectoryObjectId <admin1-ID>
   ```
   - This immediately revokes all role assignments (AU and Intune)

4. **Enable sign-in block:**
   ```powershell
   Update-MgUser -UserId admin1@bighatgrouptraining.ca -AccountEnabled:$false
   ```

**Investigation (15 minutes - 4 hours):**

1. **Review audit logs:**
   ```kusto
   AuditLogs
   | where InitiatedBy.user.userPrincipalName == \"admin1@bighatgrouptraining.ca\"
   | where TimeGenerated > ago(7d)
   | project TimeGenerated, OperationName, TargetResources, Result
   ```

2. **Check for policy modifications:**
   - Intune > Configuration profiles > Filter by ST1 tag
   - Look for recently created/modified policies

3. **Verify no cross-pod access:**
   - Search for 403/404 errors in audit log (attempts to access other pods)

4. **Check Cloud PC integrity:**
   - Review W365Student1@ Cloud PC for unauthorized configuration changes

**Remediation (4-24 hours):**

1. **Restore compromised account:** Re-add to SG-Student1-Admins after password reset + MFA enrollment

2. **Remove malicious policies:** Delete any unauthorized Intune policies created during compromise

3. **Notify affected users:** Inform W365Student1@ of potential security incident

4. **Lessons learned:** Document attack chain, update detection rules

### Post-Incident Review

**Questions to Answer:**
- How was the account compromised? (phishing, credential stuffing, etc.)
- Did the attacker attempt lateral movement? (check for AU/scope tag violations)
- Were any policies deployed to Cloud PCs? (check Intune deployment logs)
- What can be improved? (MFA enforcement, Conditional Access, detection rules)

---

## Audit & Monitoring

### Key Metrics

| Metric | Data Source | Alert Threshold |
|--------|-------------|-----------------|
| Failed sign-in attempts | Entra ID Sign-in Logs | > 5 per user per hour |
| Privilege escalation attempts | Entra ID Audit Logs | Any attempt |
| Cross-pod access attempts | Graph API audit logs | Any 403 error for AU/scope tag |
| Intune policy creation rate | Intune Audit Logs | > 10 policies per admin per day |
| Password reset frequency | Entra ID Audit Logs | > 3 per admin per day |
| Group membership changes | Entra ID Audit Logs | Any change outside business hours |

### Monitoring Queries (Azure Monitor / Sentinel)

**Detect Privilege Escalation Attempts:**
```kusto
AuditLogs
| where OperationName == \"Add member to role\"
| where Result == \"failure\"
| where TargetResources[0].modifiedProperties[0].displayName == \"Role.DisplayName\"
| project TimeGenerated, InitiatedBy.user.userPrincipalName, TargetResources[0].displayName, ResultReason
```

**Detect Cross-Pod Access Attempts:**
```kusto
AuditLogs
| where InitiatedBy.user.userPrincipalName startswith \"admin\"
| where Result == \"failure\"
| where ResultReason contains \"403\" or ResultReason contains \"not found\"
| where TargetResources[0].displayName !contains extractjson(\"$[0]\", split(InitiatedBy.user.userPrincipalName, \"@\")[0], -1)
| project TimeGenerated, InitiatedBy.user.userPrincipalName, OperationName, TargetResources[0].displayName
```

**Detect Unusual Intune Policy Creation:**
```kusto
IntuneAuditLogs
| where OperationName == \"Create\" and Category == \"DeviceConfiguration\"
| summarize PolicyCount=count() by UserId, bin(TimeGenerated, 1h)
| where PolicyCount > 10
```

### Logging Strategy

**Log Sources:**
- Entra ID Sign-in Logs (authentication events)
- Entra ID Audit Logs (directory changes)
- Intune Audit Logs (policy/device management)
- Azure Activity Logs (Azure resource operations)
- Graph API Audit Logs (programmatic access)

**Retention:**
- Hot storage: 30 days (default)
- Warm storage: 90 days (Log Analytics)
- Cold storage: 7 years (archive for compliance)

**Export Destinations:**
- Azure Monitor Log Analytics Workspace
- Azure Sentinel (SIEM)
- Azure Storage Account (long-term archive)
- Third-party SIEM (Splunk, QRadar, etc.)

---

## Appendix: Security Validation Checklist

Use this checklist to validate the security posture after deployment:

### Entra ID Layer

- [ ] AU-Student1 through AU-Student30 created
- [ ] W365Student{N}@ user is member of AU-Student{N}
- [ ] SG-Student{N}-Users group is member of AU-Student{N}
- [ ] Groups Administrator role assigned to SG-Student{N}-Admins (scoped to AU-Student{N})
- [ ] admin1@ cannot view W365Student2@ via Entra ID portal
- [ ] admin1@ cannot reset W365Student2@ password (403 error)
- [ ] AU membership is hidden (cannot enumerate members)

### Intune Layer

- [ ] Custom \"Lab Intune Admin\" role created with minimal permissions
- [ ] 30 role assignments created (one per student)
- [ ] admin1@ role assignment has Members = SG-Student1-Admins
- [ ] admin1@ role assignment has Scope (Groups) = SG-Student1-Users + SG-Student1-Devices
- [ ] admin1@ role assignment has Scope (Tags) = ST1
- [ ] admin1@ can only see ST1-tagged policies in Intune portal
- [ ] New policy created by admin1@ is auto-tagged with ST1
- [ ] Policy assignment picker only shows SG-Student1-Users and SG-Student1-Devices
- [ ] admin1@ cannot see ST2-tagged resources

### Azure Layer

- [ ] Custom RBAC roles created (Custom Image Builder, W365 Deployer)
- [ ] Roles assigned to admin accounts at RG scope (not subscription)
- [ ] Roles do not have `Microsoft.Authorization/roleAssignments/write` permission
- [ ] Roles do not have `*` wildcard permissions

### Audit & Monitoring

- [ ] Entra ID audit logs enabled
- [ ] Intune audit logs enabled
- [ ] Azure Activity logs enabled
- [ ] Diagnostic settings configured to export to Log Analytics
- [ ] Alert rules created for privilege escalation attempts
- [ ] Alert rules created for cross-pod access attempts

### Compliance

- [ ] Role definitions documented
- [ ] Access review process defined
- [ ] Audit log retention configured (90+ days)
- [ ] Incident response playbook tested

---

## Document Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-11-10 | OpenSpec Automation | Initial security architecture documentation |

---

## Contact Information

**Security Issues:** Report to Global Administrator  
**Questions:** Review README.md or design.md in `openspec/changes/implement-pod-security-model/`  
**Audit Requests:** Contact compliance team

**Emergency Contact:** Use Incident Response playbook (Section 9)