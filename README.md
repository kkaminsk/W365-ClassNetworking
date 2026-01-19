# TechmentorOrlando-2025-Windows365

This repo delivers a minimal hub landing zone for a new Azure tenant using Bicep. It aligns with `Landing Zone (Hub-Only, Minimal).md` and the implementation plan in `plan.md`.

Key capabilities:
- Hub VNet with `mgmt-snet` and `priv-endpoints-snet`, NSGs, and Firewall Standard enabled by default.
- Log Analytics Workspace (30‑day default retention) and diagnostics wiring (subscription + hub resources).
- Baseline governance: allowed locations policy, budgets, and group‑based RBAC at RG scope.
- Private DNS zones and VNet links for common Azure PaaS privatelink endpoints.

Non‑Bicep tenant tasks (Entra/M365) are noted in `plan.md` and should be automated via Microsoft Graph/PowerShell where possible.

---

## Repository Structure

```
infra/
  modules/
    rg/                     # Resource groups (sub scope)
    hub-network/            # VNet, subnets, NSGs, Firewall Standard (+ PIP)
    private-dns/            # Private DNS zones + VNet links
    log-analytics/          # LAW + retention
    diagnostics/            # Subscription + resource diagnostics → LAW
    policy/                 # (Start) Allowed locations – extend with tags/diag/public IP
    rbac/                   # Group-based role assignments
    budget/                 # Subscription budget
  envs/
    prod/
      main.bicep           # Subscription-scope orchestration
      parameters.prod.jsonc
scripts/
  entra/
    1-Setup-RbacGroups.ps1  # Create groups and assign Azure roles at RG scope
    2-Setup-LabUsers.ps1    # Create lab users (break-glass, student admin/test) and write creds file
Landing Zone (Hub-Only, Minimal).md
plan.md
```

---

## Prerequisites (New Azure Tenant)

- Permissions
  - Subscription Owner (recommended for initial deployment), or Contributor + User Access Administrator + Policy Contributor.
- Tools
  - Azure CLI with Bicep: `az version`, `az bicep version`; upgrade if needed: `az bicep upgrade`.
- Authentication
  - Login to the correct tenant/sub: `az login --tenant <tenantId>` then `az account set --subscription "<subscriptionNameOrId>"`.
- Resource providers (register if needed)
  - `Microsoft.Network`, `Microsoft.OperationalInsights`, `Microsoft.Insights`, `Microsoft.Authorization`, `Microsoft.Consumption`, `Microsoft.PolicyInsights`, (optional) `Microsoft.Security`.
  - Example:
    ```powershell
    $providers = 'Microsoft.Network','Microsoft.OperationalInsights','Microsoft.Insights','Microsoft.Authorization','Microsoft.Consumption','Microsoft.PolicyInsights','Microsoft.Security'
    foreach ($p in $providers) { az provider register --namespace $p }
    ```
- Entra ID groups (needed for RBAC)
  - Create groups and capture their object IDs:
    - `grp-platform-network-admins` (Owner on `rg-hub-net`)
    - `grp-platform-ops` (Contributor on `rg-hub-ops`)
    - (Optional) auditors group (Reader)

---

## Configure Parameters

Edit `infra/envs/prod/parameters.prod.jsonc`:
- `location`: e.g., `canada-central`.
- `allowedLocations`: e.g., `["canada-central", "canada-east"]`.
- `tags`: `env`, `owner`, `costCenter`, `dataSensitivity` (required by policy later).
- `networkAdminsGroupObjectId`, `opsGroupObjectId`: set to Entra group object IDs (from the groups you create). If left blank, RBAC assignments will be skipped.
- Optional: budgets and other parameters if you extend modules.

The Orchestrator `infra/envs/prod/main.bicep` enables Firewall Standard by default and sets a 30‑day LAW retention.

---

## Validate and Deploy

From the repo root:

```powershell
# Select the subscription
az account set --subscription "<subscriptionNameOrId>"

# What-if (subscription-scope deployment)
az deployment sub what-if `
  --name hub-minimal-whatif `
  --location canada-central `
  --template-file infra/envs/prod/main.bicep `
  --parameters @infra/envs/prod/parameters.prod.jsonc

# Deploy
az deployment sub create `
  --name hub-minimal-deploy `
  --location canada-central `
  --template-file infra/envs/prod/main.bicep `
  --parameters @infra/envs/prod/parameters.prod.jsonc
```

---

## What Gets Deployed

- `rg-hub-net`, `rg-hub-ops` (subscription scope)
- `vnet-hub` with:
  - `mgmt-snet` (NSG attached)
  - `priv-endpoints-snet` (private endpoint policies disabled; NSG attached)
  - `AzureFirewallSubnet` with Firewall Standard + Public IP
- Log Analytics Workspace `log-ops-hub` (PerGB2018, 30 days retention)
- Subscription Activity Log diagnostic setting → LAW
- Private DNS zones (e.g., `privatelink.azurewebsites.net`, blob privatelink zone uses environment-specific suffix) and VNet link
- Allowed locations policy assignment (extend as needed)
- Group-based RBAC at RG scope
- Subscription budget with 80% and 100% alerts

---

## Post‑Deploy Validation

- Resource groups exist and contain expected resources (`rg-hub-net`, `rg-hub-ops`).
- LAW deployed and retention set to 30 days.
- Subscription diagnostic setting exists and targets LAW.
- VNet/subnets and NSGs created; Firewall Standard and Public IP present.
- Private DNS zones linked to the hub VNet.
- Policy assignment active and shows compliant locations.
- Budget visible in Cost Management.

---

## Non‑Bicep Tenant Tasks (Entra/M365)

Per `Landing Zone (Hub-Only, Minimal).md` and `plan.md`:
- Create 2 break‑glass accounts (exclude from CA; monitor).
- Create Student Administrator and Student Test accounts; add Student Admin to `grp-w365-admin`.
- Assign Intune roles: `grp-w365-admin` → Intune Administrator; `grp-w365-ops` → Help Desk Operator.
- Conditional Access: require MFA, block legacy auth, restrict admin device state, named locations for Canada/office IPs.
- Enable SSPR with MFA methods and authentication strengths (FIDO2/Passkeys if feasible).
- Enable Unified Audit Log; disable legacy basic auth as applicable.
- Consider automating via Microsoft Graph (place scripts under `scripts/entra/`).

---

## Scripts (optional automation)

- **`scripts/entra/1-Setup-RbacGroups.ps1`**
  - Creates or reuses Entra ID groups and assigns Azure roles at RG scope:
    - `grp-platform-network-admins` → Owner on `rg-hub-net`
    - `grp-platform-ops` → Contributor on `rg-hub-ops`
  - Example:
    ```powershell
    ./scripts/entra/1-Setup-RbacGroups.ps1 `
      -SubscriptionId "<subId>" `
      -RgNetName "rg-hub-net" -RgOpsName "rg-hub-ops" `
      -NetworkAdminsGroupName "grp-platform-network-admins" `
      -OpsGroupName "grp-platform-ops"
    ```
  - Use the output Object IDs to populate `networkAdminsGroupObjectId` and `opsGroupObjectId` in `parameters.prod.jsonc`.

- **`scripts/entra/2-Setup-LabUsers.ps1`**
  - Creates lab users and writes credentials to `<TenantName><TenantId>.txt`:
    - Break‑Glass 1/2, Student Administrator (added to `grp-w365-admin`), Student Test
  - Example:
    ```powershell
    ./scripts/entra/2-Setup-LabUsers.ps1 -UseDeviceCode
    # or specify domain and rotate passwords
    ./scripts/entra/2-Setup-LabUsers.ps1 -DomainName "contoso.onmicrosoft.com" -RotatePasswords -OutputDirectory .
    ```

---

## Customization

- Addressing: change `vnetAddressSpace`, `mgmtSubnetPrefix`, `privEndpointsSubnetPrefix` in `infra/envs/prod/main.bicep`.
- Firewall: toggle `enableFirewall`, adjust `firewallSubnetPrefix`; add rules via Firewall Policy (future module).
- Private DNS: extend the zones list in `infra/modules/private-dns/main.bicep` or pass via parameters.
- Policies: extend `infra/modules/policy/main.bicep` to enforce required tags, required diagnostics to LAW, and audit/deny public IPs.
- Diagnostics: add resource-level diagnostics wiring in `infra/modules/diagnostics/resources.bicep`.

---

## Troubleshooting

- Authorization errors: ensure you are Owner or have Contributor + User Access Administrator + Policy Contributor.
- Provider errors: register missing providers (see prerequisites).
- Diagnostics assignment failures: ensure `Microsoft.Insights` is registered and LAW exists before running diag modules.
- Azure Firewall SKU/tier warnings: You may see a Bicep type warning on `sku` for the Firewall resource; it is safe to ignore. Ensure region supports Firewall Standard and a Standard Public IP is used.

---

## Clean Up

Deleting resource groups will remove deployed resources:

```powershell
az group delete -n rg-hub-net -y
az group delete -n rg-hub-ops -y
```

Note: This is destructive; confirm you are in the correct subscription.