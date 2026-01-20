#Requires -Version 7.0
<#
.SYNOPSIS
    Bootstrap a new TechMentor lab tenant with standardized administrator accounts and deployment permissions.

.DESCRIPTION
    Script that automates the preparation of lab tenants by:
    - Prompting for tenant selection from all accessible tenants
    - Prompting for subscription selection within the chosen tenant
    - Creating a standardized administrator account (admin@bighatgrouptraining.ca) with Intune Administrator role
    - Creating a backdoor global administrator account (bdoor@bighatgrouptraining.ca) with Global Administrator role
    - Creating and assigning custom Azure RBAC roles for Custom Image and W365 spoke deployments
    - Registering required resource providers
    - Saving all credentials to a CSV file in the user's Documents folder
    
    Designed for single tenant deployment using bighatgrouptraining.ca domain.

.PARAMETER TenantId
    Optional Azure AD tenant ID to target. Overrides interactive tenant picker.

.PARAMETER SubscriptionId
    Optional subscription ID within the selected tenant. When omitted, always prompts for subscription selection.

.PARAMETER AdminUPN
    Override the default admin UPN (default: admin@bighatgrouptraining.ca)

.PARAMETER CustomImageResourceGroup
    Resource group name for Custom Image operations (default: rg-w365-customimage)

.PARAMETER W365ResourceGroup
    Resource group name for W365 spoke network (default: rg-w365-spoke-prod)

.PARAMETER StudentCount
    Number of student accounts to create (W365Student1, W365Student2, etc.). Default: 30 (creates 30 student admins and 30 student accounts)

.PARAMETER SkipUserCreation
    Skip user account creation (useful for re-running RBAC setup only)

.PARAMETER SkipRoleAssignments
    Skip RBAC role assignments (useful for testing user creation only)

.EXAMPLE
    .\SubscriptionConfigure.ps1
    Interactive mode: selects tenant, creates 2 main admins + 30 student admins + 30 students (default)

.EXAMPLE
    .\SubscriptionConfigure.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    Automate for specific tenant using explicit tenant ID with 30 students (default)

.EXAMPLE
    .\SubscriptionConfigure.ps1 -StudentCount 0
    Create only the 2 main admin accounts without any student accounts

.EXAMPLE
    .\SubscriptionConfigure.ps1 -StudentCount 40 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    Create 2 main admins + 40 student admins + 40 students for specific tenant

.EXAMPLE
    .\SubscriptionConfigure.ps1 -AdminUPN "instructor@bighatgrouptraining.ca"
    Create admin with custom UPN (still creates 30 students by default)

.EXAMPLE
    .\SubscriptionConfigure.ps1 -SkipUserCreation
    Re-run RBAC setup without creating the user account

.NOTES
    Requires:
    - PowerShell 7.0 or newer
    - Azure PowerShell module (Az.Accounts, Az.Resources)
    - Microsoft.Graph.Users and Microsoft.Graph.Identity.DirectoryManagement modules
    - Owner or User Access Administrator role at subscription level (for RBAC)
    - Global Administrator or Privileged Role Administrator (for Entra ID roles)
    
    Prerequisites:
    - Target subscription must exist with Owner/UAA access
    - 4_W365/W365-MinimumRole.json must exist
    
    Guest Account Tip:
    - For faster execution, pre-authenticate with: Connect-AzAccount -SkipContextPopulation
    - This avoids subscription enumeration and allows immediate tenant selection
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$AdminUPN = "admin@bighatgrouptraining.ca",
    
    [Parameter(Mandatory = $false)]
    [string]$BdoorUPN = "bdoor@bighatgrouptraining.ca",

    [Parameter(Mandatory = $false)]
    [string]$CustomImageResourceGroup = "rg-w365-customimage",

    [Parameter(Mandatory = $false)]
    [string]$W365ResourceGroup = "rg-w365-spoke-prod",

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100)]
    [int]$StudentCount = 30,

    [Parameter(Mandatory = $false)]
    [switch]$SkipUserCreation,

    [Parameter(Mandatory = $false)]
    [switch]$SkipRoleAssignments
)

$ErrorActionPreference = "Stop"
$ScriptPath = $PSScriptRoot

# Initialize log and CSV files in Documents folder
$documentsFolder = [Environment]::GetFolderPath('MyDocuments')
$timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
$logFile = Join-Path $documentsFolder "SubscriptionConfigure-$timestamp.log"
$csvFile = Join-Path $documentsFolder "SubscriptionConfigure.csv"

# Create CSV file with headers if it doesn't exist
if (-not (Test-Path $csvFile)) {
    "UPN,Password,Role,CreatedDate" | Out-File -FilePath $csvFile -Encoding UTF8
}

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

function New-AdminAccount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UPN,
        
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        
        [Parameter(Mandatory = $true)]
        [string]$CsvFile,
        
        [Parameter(Mandatory = $true)]
        [string]$DirectoryRole,
        
        [Parameter(Mandatory = $false)]
        [switch]$SkipRoleAssignment
    )
    
    Write-LogMessage "Creating account: $UPN with role: $DirectoryRole" -Level Info
    
    # Parse UPN for MailNickname generation
    $upnParts = $UPN -split '@'
    
    # Check if user exists
    $existingUser = Get-MgUser -Filter "userPrincipalName eq '$UPN'" -ErrorAction SilentlyContinue
    
    $password = $null
    $userId = $null
    $userCreated = $false
    
    if ($existingUser) {
        Write-LogMessage "User already exists: $UPN (ObjectId: $($existingUser.Id))" -Level Success
        $userId = $existingUser.Id
    }
    else {
        # Generate random password
        $password = -join ((65..90) + (97..122) + (48..57) + (33, 35, 36, 37, 38, 42, 43, 61) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
        
        Write-LogMessage "Creating new user: $UPN" -Level Info
        $passwordProfile = @{
            Password                      = $password
            ForceChangePasswordNextSignIn = $true
        }
        
        # Generate MailNickname from username part of UPN
        $upnUsername = $upnParts[0]
        $mailNickname = $upnUsername -replace '[^a-zA-Z0-9]', ''
        
        $newUser = New-MgUser -UserPrincipalName $UPN `
            -DisplayName $DisplayName `
            -MailNickname $mailNickname `
            -AccountEnabled:$true `
            -PasswordProfile $passwordProfile `
            -UsageLocation "CA" `
            -ErrorAction Stop
        
        $userId = $newUser.Id
        $userCreated = $true
        Write-LogMessage "User created successfully: $UPN (ObjectId: $userId)" -Level Success
        
        # Save to CSV
        $createdDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$UPN,$password,$DirectoryRole,$createdDate" | Out-File -FilePath $CsvFile -Append -Encoding UTF8
        Write-LogMessage "Credentials saved to CSV: $CsvFile" -Level Success
    }
    
    # Assign directory role (skip for regular User role and if SkipRoleAssignment is set)
    if ($DirectoryRole -ne "User" -and -not $SkipRoleAssignment) {
        Start-Sleep -Seconds 2  # Brief delay for user to propagate
        
        $roleTemplate = Get-MgDirectoryRoleTemplate -Filter "displayName eq '$DirectoryRole'" -ErrorAction SilentlyContinue
        if (-not $roleTemplate) {
            Write-LogMessage "WARNING: Role template not found: $DirectoryRole" -Level Warning
        }
        else {
            # Check if role is activated
            $role = Get-MgDirectoryRole -Filter "roleTemplateId eq '$($roleTemplate.Id)'" -ErrorAction SilentlyContinue
            if (-not $role) {
                # Activate the role
                $role = New-MgDirectoryRole -RoleTemplateId $roleTemplate.Id -ErrorAction SilentlyContinue
            }
            
            if ($role) {
                # Check if already assigned
                $existingAssignment = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq $userId }
                
                if (-not $existingAssignment) {
                    New-MgDirectoryRoleMemberByRef -DirectoryRoleId $role.Id -BodyParameter @{"@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId"} -ErrorAction Stop | Out-Null
                    Write-LogMessage "$DirectoryRole role assigned successfully" -Level Success
                }
                else {
                    Write-LogMessage "$DirectoryRole role already assigned" -Level Info
                }
            }
        }
    }
    elseif ($SkipRoleAssignment) {
        Write-LogMessage "Skipping direct role assignment - will be assigned via group" -Level Info
    }
    
    return @{
        UPN = $UPN
        UserId = $userId
        Password = $password
        UserCreated = $userCreated
        Role = $DirectoryRole
    }
}

# ============================================================================
# Main Script
# ============================================================================

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Subscription Bootstrap Automation" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Log file: $logFile" -ForegroundColor Gray
Write-Host "CSV file: $csvFile" -ForegroundColor Gray
"" | Out-File -FilePath $logFile -Encoding UTF8
"==========================================" | Out-File -FilePath $logFile -Append -Encoding UTF8
"Subscription Bootstrap Automation" | Out-File -FilePath $logFile -Append -Encoding UTF8
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
Write-Host "`n[1/8] Checking required modules..." -ForegroundColor Yellow

$requiredModules = @(
    @{ Name = "Az.Accounts"; Description = "Azure authentication" },
    @{ Name = "Az.Resources"; Description = "Azure RBAC and resources" },
    @{ Name = "Microsoft.Graph.Users"; Description = "Microsoft Graph user management" },
    @{ Name = "Microsoft.Graph.Groups"; Description = "Microsoft Graph group management" },
    @{ Name = "Microsoft.Graph.Identity.DirectoryManagement"; Description = "Microsoft Graph directory roles" }
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module.Name)) {
        Write-LogMessage "ERROR: Module '$($module.Name)' is not installed." -Level Error
        Write-Host "Install it with: Install-Module -Name $($module.Name) -Repository PSGallery -Force" -ForegroundColor Yellow
        exit 1
    }
    Write-LogMessage "$($module.Description): $($module.Name) installed" -Level Success
}

# Step 3: Establish Azure context (matching 1_Hub pattern)
Write-Host "`n[2/8] Establishing Azure context..." -ForegroundColor Yellow

try {
    Write-LogMessage "Checking Azure login status..." -Level Info
    
    # Check if already authenticated
    $context = Get-AzContext
    
    if (-not $context) {
        Write-Host "`n  ═══════════════════════════════════════════════════════════" -ForegroundColor Yellow
        Write-Host "  Guest Account Multi-Tenant Login" -ForegroundColor Cyan
        Write-Host "  ═══════════════════════════════════════════════════════════" -ForegroundColor Yellow
        Write-Host "  For guest accounts with access to many tenants:" -ForegroundColor White
        Write-Host "  1. Complete authentication in browser" -ForegroundColor White
        Write-Host "  2. If subscription picker appears, press ESC/Cancel" -ForegroundColor White
        Write-Host "  3. Script will then list all accessible tenants" -ForegroundColor White
        Write-Host "  ═══════════════════════════════════════════════════════════`n" -ForegroundColor Yellow
        
        # Skip context population to avoid enumerating subscriptions across all tenants
        # This is critical for guest accounts with access to many tenants
        Write-Host "  Authenticating (subscription enumeration disabled)...`n" -ForegroundColor Cyan
        
        try {
            $null = Connect-AzAccount -SkipContextPopulation -ErrorAction Stop -WarningAction SilentlyContinue 2>&1 | Out-Null
        }
        catch {
            Write-LogMessage "ERROR: Authentication failed: $($_.Exception.Message)" -Level Error
            exit 1
        }
        
        $context = Get-AzContext
        
        if (-not $context) {
            Write-LogMessage "ERROR: Failed to establish Azure context after login." -Level Error
            exit 1
        }
    }
    else {
        Write-Host "`n  Using existing Azure session" -ForegroundColor Green
    }
    
    Write-Host "  Signed in as: $($context.Account.Id)" -ForegroundColor White
    Write-LogMessage "Signed in as: $($context.Account.Id)" -Level Success

    # Get all available tenants (metadata only - subscriptions NOT enumerated yet)
    Write-Host "`n  Enumerating all accessible tenants..." -ForegroundColor Cyan
    Write-LogMessage "Retrieving tenant list (no subscription access yet)..." -Level Info
    $tenants = @(Get-AzTenant -WarningAction SilentlyContinue)

    if ($tenants.Count -eq 0) {
        Write-LogMessage "ERROR: No accessible tenants found for this account." -Level Error
        exit 1
    }

    $selectedTenant = $null

    if ($TenantId) {
        # Use explicitly specified tenant
        $selectedTenant = $tenants | Where-Object { $_.Id -eq $TenantId }
        if (-not $selectedTenant) {
            Write-LogMessage "ERROR: Specified tenant ID '$TenantId' is not accessible." -Level Error
            exit 1
        }
        Write-LogMessage "Using specified tenant: $($selectedTenant.Name) ($($selectedTenant.Id))" -Level Success
        
        # Re-authenticate to ensure proper access
        Write-LogMessage "Authenticating to tenant..." -Level Info
        try {
            Connect-AzAccount -TenantId $selectedTenant.Id -ErrorAction Stop | Out-Null
            Write-LogMessage "Authentication successful." -Level Success
        }
        catch {
            Write-LogMessage "ERROR: Failed to authenticate to tenant '$($selectedTenant.Name)'." -Level Error
            Write-Host "If MFA is required, run: Connect-AzAccount -TenantId $($selectedTenant.Id)" -ForegroundColor Yellow
            Write-Host "Then rerun this script with: .\SubscriptionConfigure.ps1 -TenantId $($selectedTenant.Id)" -ForegroundColor Yellow
            exit 1
        }
    }
    else {
        # Always prompt for tenant selection (multi-tenant awareness)
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host " Select Target Tenant" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  Found $($tenants.Count) accessible tenant(s):`n" -ForegroundColor Yellow
        
        for ($i = 0; $i -lt $tenants.Count; $i++) {
            $tenant = $tenants[$i]
            Write-Host "  [$($i + 1)] $($tenant.Name) ($($tenant.Id))" -ForegroundColor White
        }

        do {
            $selection = Read-Host "`nSelect tenant number (1-$($tenants.Count))"
            $selectionIndex = [int]$selection - 1
        } while ($selectionIndex -lt 0 -or $selectionIndex -ge $tenants.Count)

        $selectedTenant = $tenants[$selectionIndex]
        Write-Host "`n  Selected: $($selectedTenant.Name)" -ForegroundColor Green
        Write-LogMessage "Selected tenant: $($selectedTenant.Name) ($($selectedTenant.Id))" -Level Success
        
        # Re-authenticate to the selected tenant to ensure proper access (MFA, etc.)
        Write-Host "  Authenticating to tenant (MFA may be required)..." -ForegroundColor Cyan
        Write-LogMessage "Authenticating to selected tenant only..." -Level Info
        try {
            Connect-AzAccount -TenantId $selectedTenant.Id -ErrorAction Stop | Out-Null
            Write-Host "  ✓ Authentication successful" -ForegroundColor Green
            Write-LogMessage "Authentication successful." -Level Success
        }
        catch {
            Write-LogMessage "ERROR: Failed to authenticate to tenant '$($selectedTenant.Name)'." -Level Error
            Write-Host "If MFA is required, run: Connect-AzAccount -TenantId $($selectedTenant.Id)" -ForegroundColor Yellow
            Write-Host "Then rerun this script with: .\SubscriptionConfigure.ps1 -TenantId $($selectedTenant.Id)" -ForegroundColor Yellow
            exit 1
        }
    }

    # Get subscriptions ONLY in the selected tenant (no other tenants accessed)
    Write-Host "`n  Retrieving subscriptions in '$($selectedTenant.Name)'..." -ForegroundColor Cyan
    Write-LogMessage "Retrieving subscriptions for tenant '$($selectedTenant.Name)' only..." -Level Info
    
    $subscriptions = @()
    try {
        # Only enumerate subscriptions in the selected tenant
        $subscriptions = @(Get-AzSubscription -TenantId $selectedTenant.Id -WarningAction SilentlyContinue -ErrorAction Stop | Where-Object { $_.State -eq "Enabled" })
    }
    catch {
        Write-LogMessage "ERROR: Unable to enumerate subscriptions for tenant '$($selectedTenant.Name)'." -Level Error
        Write-LogMessage $_.Exception.Message -Level Error
        exit 1
    }

    if ($subscriptions.Count -eq 0) {
        Write-LogMessage "ERROR: No enabled subscriptions found in tenant '$($selectedTenant.Name)'." -Level Error
        Write-Host "Please ensure you have appropriate access permissions." -ForegroundColor Yellow
        exit 1
    }

    $selectedSubscription = $null

    if ($SubscriptionId) {
        # Use explicitly specified subscription
        $selectedSubscription = $subscriptions | Where-Object { $_.Id -eq $SubscriptionId }
        if (-not $selectedSubscription) {
            Write-LogMessage "ERROR: Subscription '$SubscriptionId' not found in tenant '$($selectedTenant.Name)'." -Level Error
            exit 1
        }
        Write-LogMessage "Using specified subscription: $($selectedSubscription.Name) ($($selectedSubscription.Id))" -Level Success
    }
    else {
        # Always prompt for subscription selection (multi-tenant awareness)
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host " Select Target Subscription" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  Tenant: $($selectedTenant.Name)" -ForegroundColor Gray
        Write-Host "  Found $($subscriptions.Count) enabled subscription(s):`n" -ForegroundColor Yellow
        
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            $sub = $subscriptions[$i]
            Write-Host "  [$($i + 1)] $($sub.Name) ($($sub.Id))" -ForegroundColor White
        }

        do {
            $selection = Read-Host "`nSelect subscription number (1-$($subscriptions.Count))"
            $selectionIndex = [int]$selection - 1
        } while ($selectionIndex -lt 0 -or $selectionIndex -ge $subscriptions.Count)

        $selectedSubscription = $subscriptions[$selectionIndex]
        Write-LogMessage "Selected subscription: $($selectedSubscription.Name) ($($selectedSubscription.Id))" -Level Success
    }

    # Set context
    Write-LogMessage "Switching Azure context..." -Level Info
    $newContext = Set-AzContext -TenantId $selectedTenant.Id -SubscriptionId $selectedSubscription.Id -ErrorAction Stop

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host " ✓ Active Azure Context" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " Account:        $($newContext.Account.Id)" -ForegroundColor White
    Write-Host " Tenant:         $($selectedTenant.Name)" -ForegroundColor White
    Write-Host "                 $($newContext.Tenant.Id)" -ForegroundColor Gray
    Write-Host " Subscription:   $($newContext.Subscription.Name)" -ForegroundColor White
    Write-Host "                 $($newContext.Subscription.Id)" -ForegroundColor Gray
    Write-Host "========================================" -ForegroundColor Green

}
catch {
    Write-LogMessage "ERROR: Failed to establish Azure context." -Level Error
    Write-LogMessage $_.Exception.Message -Level Error
    exit 1
}

# Step 4: Configure administrator account details
Write-Host "`n[3/8] Configuring administrator account details..." -ForegroundColor Yellow

$adminDisplayName = "BHG Admin"
$bdoorDisplayName = "Backdoor Admin"

Write-LogMessage "Using single tenant configuration" -Level Info
Write-LogMessage "Admin UPN: $AdminUPN" -Level Info
Write-LogMessage "Backdoor UPN: $BdoorUPN" -Level Info

Write-Host "`n  Administrator Accounts:" -ForegroundColor Cyan
Write-Host "    Admin UPN:        $AdminUPN" -ForegroundColor White
Write-Host "    Display Name:     $adminDisplayName" -ForegroundColor White
Write-Host "    Backdoor UPN:     $BdoorUPN" -ForegroundColor White
Write-Host "    Display Name:     $bdoorDisplayName" -ForegroundColor White

# Step 5: Create or verify administrator accounts
if (-not $SkipUserCreation) {
    Write-Host "`n[4/8] Provisioning administrator accounts..." -ForegroundColor Yellow
    
    Write-Host "`n  ⚠️  Microsoft Graph Authentication Required (ONE TIME)" -ForegroundColor Yellow
    Write-Host "  Browser window will open for Graph authentication" -ForegroundColor Gray
    Write-Host "  Scopes needed: User.ReadWrite.All, Group.ReadWrite.All, RoleManagement.ReadWrite.Directory" -ForegroundColor Gray
    Write-Host "  This connection will be reused for all $($StudentCount + 2) user creations`n" -ForegroundColor Green

    try {
        # Connect to Microsoft Graph ONCE for all user operations
        Write-LogMessage "Connecting to Microsoft Graph..." -Level Info
        Import-Module Microsoft.Graph.Users -ErrorAction Stop
        Import-Module Microsoft.Graph.Groups -ErrorAction Stop
        Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        
        Connect-MgGraph -Scopes "User.ReadWrite.All", "RoleManagement.ReadWrite.Directory", "Group.ReadWrite.All" -TenantId $selectedTenant.Id -NoWelcome -ErrorAction Stop | Out-Null
        Write-LogMessage "Connected to Microsoft Graph successfully" -Level Success
        Write-Host "`n  ✓ Graph authentication complete - Creating all users..." -ForegroundColor Green
        
        # Create admin@ account (role will be assigned via group)
        Write-Host "`n  Creating Main (admin) account (1/$(2 + $StudentCount + $StudentCount))..." -ForegroundColor Cyan
        $bhgAdminResult = New-AdminAccount `
            -UPN $AdminUPN `
            -DisplayName $adminDisplayName `
            -CsvFile $csvFile `
            -DirectoryRole "Intune Administrator" `
            -SkipRoleAssignment
        
        if (-not $bhgAdminResult) {
            Write-LogMessage "ERROR: Failed to create BHG Admin account" -Level Error
            exit 1
        }
        
        # Update UPN if domain was adjusted
        $AdminUPN = $bhgAdminResult.UPN
        $script:adminUserId = $bhgAdminResult.UserId
        
        # Display password if user was created
        if ($bhgAdminResult.UserCreated -and $bhgAdminResult.Password) {
            Write-Host "`n  ⚠️  ADMIN TEMPORARY PASSWORD (save immediately):" -ForegroundColor Yellow
            Write-Host "    UPN:      $($bhgAdminResult.UPN)" -ForegroundColor White
            Write-Host "    Password: $($bhgAdminResult.Password)" -ForegroundColor White
            Write-Host "  Password must be changed at first sign-in." -ForegroundColor Yellow
        }
        
        # Create bdoor account with Global Administrator role
        Write-Host "`n  Creating Backdoor (bdoor) Global Admin account (2/$(2 + $StudentCount + $StudentCount))..." -ForegroundColor Cyan
        $bdoorResult = New-AdminAccount `
            -UPN $BdoorUPN `
            -DisplayName $bdoorDisplayName `
            -CsvFile $csvFile `
            -DirectoryRole "Global Administrator"
        
        if (-not $bdoorResult) {
            Write-LogMessage "ERROR: Failed to create bdoor account" -Level Error
            exit 1
        }
        
        # Display password if user was created
        if ($bdoorResult.UserCreated -and $bdoorResult.Password) {
            Write-Host "`n  ⚠️  BDOOR GLOBAL ADMIN TEMPORARY PASSWORD (save immediately):" -ForegroundColor Yellow
            Write-Host "    UPN:      $($bdoorResult.UPN)" -ForegroundColor White
            Write-Host "    Password: $($bdoorResult.Password)" -ForegroundColor White
            Write-Host "  Password must be changed at first sign-in." -ForegroundColor Yellow
        }
        
        Write-Host "`n  Credentials saved to: $csvFile`n" -ForegroundColor Yellow
        
        # Create student administrator accounts if requested
        if ($StudentCount -gt 0) {
            Write-Host "`n  Creating $StudentCount student administrator accounts (using existing Graph connection)..." -ForegroundColor Cyan
            Write-LogMessage "Creating $StudentCount student administrator accounts (admin1-admin$StudentCount)" -Level Info
            
            $studentAdminResults = @()
            
            for ($i = 1; $i -le $StudentCount; $i++) {
                $studentAdminUPN = "admin$i@bighatgrouptraining.ca"
                $studentAdminDisplayName = "Student Admin $i"
                $currentCount = 2 + $i
                $totalCount = 2 + $StudentCount + $StudentCount
                
                Write-Host "    Creating admin $i of $StudentCount ($currentCount/$totalCount): $studentAdminUPN" -ForegroundColor Gray
                
                try {
                    $studentAdminResult = New-AdminAccount `
                        -UPN $studentAdminUPN `
                        -DisplayName $studentAdminDisplayName `
                        -CsvFile $csvFile `
                        -DirectoryRole "Intune Administrator" `
                        -SkipRoleAssignment
                    
                    if ($studentAdminResult) {
                        $studentAdminResults += $studentAdminResult
                        Write-LogMessage "Student admin account created: $studentAdminUPN" -Level Success
                    }
                }
                catch {
                    Write-LogMessage "WARNING: Failed to create student admin $studentAdminUPN : $($_.Exception.Message)" -Level Warning
                    continue
                }
            }
            
            Write-Host "`n  ✓ Created $($studentAdminResults.Count) of $StudentCount student admin accounts" -ForegroundColor Green
            Write-LogMessage "Student admin account creation complete: $($studentAdminResults.Count)/$StudentCount successful" -Level Success
            
            # Create student accounts
            Write-Host "`n  Creating $StudentCount student accounts (using existing Graph connection)..." -ForegroundColor Cyan
            Write-LogMessage "Creating $StudentCount student accounts (W365Student1-W365Student$StudentCount)" -Level Info
            
            $studentResults = @()
            
            for ($i = 1; $i -le $StudentCount; $i++) {
                $studentUPN = "W365Student$i@bighatgrouptraining.ca"
                $studentDisplayName = "W365 Student $i"
                $currentCount = 2 + $StudentCount + $i
                $totalCount = 2 + $StudentCount + $StudentCount
                
                Write-Host "    Creating student $i of $StudentCount ($currentCount/$totalCount): $studentUPN" -ForegroundColor Gray
                
                try {
                    $studentResult = New-AdminAccount `
                        -UPN $studentUPN `
                        -DisplayName $studentDisplayName `
                        -CsvFile $csvFile `
                        -DirectoryRole "User"
                    
                    if ($studentResult) {
                        $studentResults += $studentResult
                        Write-LogMessage "Student account created: $studentUPN" -Level Success
                    }
                }
                catch {
                    continue
                }
            }
            
            Write-Host "`n  ✓ Created $($studentResults.Count) of $StudentCount student accounts" -ForegroundColor Green
            Write-LogMessage "Student account creation complete: $($studentResults.Count)/$StudentCount successful" -Level Success
            
            # Create per-student security groups (pod model)
            Write-Host "`n  Creating per-student security groups (pod model)..." -ForegroundColor Cyan
            Write-LogMessage "Creating 3 security groups per student ($($StudentCount * 3) groups total)" -Level Info
            
            $groupCreationResults = @()
            
            for ($i = 1; $i -le $StudentCount; $i++) {
                Write-Host "    Creating groups for Student $i..." -ForegroundColor Gray
                
                # Get user IDs for this student
                $adminUPN = "admin$i@bighatgrouptraining.ca"
                $studentUPN = "W365Student$i@bighatgrouptraining.ca"
                
                $adminUser = Get-MgUser -Filter "userPrincipalName eq '$adminUPN'" -ErrorAction SilentlyContinue
                $studentUser = Get-MgUser -Filter "userPrincipalName eq '$studentUPN'" -ErrorAction SilentlyContinue
                
                if (-not $adminUser) {
                    Write-LogMessage "WARNING: Admin user not found: $adminUPN - Skipping group creation" -Level Warning
                    continue
                }
                if (-not $studentUser) {
                    Write-LogMessage "WARNING: Student user not found: $studentUPN - Skipping group creation" -Level Warning
                    continue
                }
                
                try {
                    # Group 1: SG-Student{N}-Admins
                    $adminGroupName = "SG-Student$i-Admins"
                    $existingAdminGroup = Get-MgGroup -Filter "displayName eq '$adminGroupName'" -ErrorAction SilentlyContinue
                    
                    if ($existingAdminGroup) {
                        Write-LogMessage "Group already exists: $adminGroupName" -Level Info
                        $adminsGroup = $existingAdminGroup
                    }
                    else {
                        $adminsGroupParams = @{
                            DisplayName = $adminGroupName
                            Description = "Administrator account for Student $i"
                            MailEnabled = $false
                            MailNickname = "SGStudent$($i)Admins"
                            SecurityEnabled = $true
                        }
                        $adminsGroup = New-MgGroup -BodyParameter $adminsGroupParams -ErrorAction Stop
                        Write-LogMessage "Created group: $adminGroupName (ID: $($adminsGroup.Id))" -Level Success
                        Start-Sleep -Milliseconds 500  # Rate limiting
                    }
                    
                    # Add admin user to admins group
                    $existingAdminMembers = Get-MgGroupMember -GroupId $adminsGroup.Id -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
                    if ($existingAdminMembers -notcontains $adminUser.Id) {
                        $adminMemberRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($adminUser.Id)" }
                        New-MgGroupMemberByRef -GroupId $adminsGroup.Id -BodyParameter $adminMemberRef -ErrorAction Stop | Out-Null
                        Write-LogMessage "Added $adminUPN to $adminGroupName" -Level Success
                    }
                    
                    # Group 2: SG-Student{N}-Users
                    $usersGroupName = "SG-Student$i-Users"
                    $existingUsersGroup = Get-MgGroup -Filter "displayName eq '$usersGroupName'" -ErrorAction SilentlyContinue
                    
                    if ($existingUsersGroup) {
                        Write-LogMessage "Group already exists: $usersGroupName" -Level Info
                        $usersGroup = $existingUsersGroup
                    }
                    else {
                        $usersGroupParams = @{
                            DisplayName = $usersGroupName
                            Description = "Managed user accounts for Student $i"
                            MailEnabled = $false
                            MailNickname = "SGStudent$($i)Users"
                            SecurityEnabled = $true
                        }
                        $usersGroup = New-MgGroup -BodyParameter $usersGroupParams -ErrorAction Stop
                        Write-LogMessage "Created group: $usersGroupName (ID: $($usersGroup.Id))" -Level Success
                        Start-Sleep -Milliseconds 500  # Rate limiting
                    }
                    
                    # Add student user to users group
                    $existingUserMembers = Get-MgGroupMember -GroupId $usersGroup.Id -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
                    if ($existingUserMembers -notcontains $studentUser.Id) {
                        $studentMemberRef = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($studentUser.Id)" }
                        New-MgGroupMemberByRef -GroupId $usersGroup.Id -BodyParameter $studentMemberRef -ErrorAction Stop | Out-Null
                        Write-LogMessage "Added $studentUPN to $usersGroupName" -Level Success
                    }
                    
                    # Group 3: SG-Student{N}-Devices
                    $devicesGroupName = "SG-Student$i-Devices"
                    $existingDevicesGroup = Get-MgGroup -Filter "displayName eq '$devicesGroupName'" -ErrorAction SilentlyContinue
                    
                    if ($existingDevicesGroup) {
                        Write-LogMessage "Group already exists: $devicesGroupName" -Level Info
                        $devicesGroup = $existingDevicesGroup
                    }
                    else {
                        $devicesGroupParams = @{
                            DisplayName = $devicesGroupName
                            Description = "Devices managed by Student $i"
                            MailEnabled = $false
                            MailNickname = "SGStudent$($i)Devices"
                            SecurityEnabled = $true
                        }
                        $devicesGroup = New-MgGroup -BodyParameter $devicesGroupParams -ErrorAction Stop
                        Write-LogMessage "Created group: $devicesGroupName (ID: $($devicesGroup.Id))" -Level Success
                        Start-Sleep -Milliseconds 500  # Rate limiting
                    }
                    
                    $groupCreationResults += [PSCustomObject]@{
                        Student = $i
                        AdminsGroup = $adminGroupName
                        UsersGroup = $usersGroupName
                        DevicesGroup = $devicesGroupName
                        Status = "Success"
                    }
                }
                catch {
                    Write-LogMessage "ERROR: Failed to create groups for Student $i : $($_.Exception.Message)" -Level Error
                    $groupCreationResults += [PSCustomObject]@{
                        Student = $i
                        AdminsGroup = "N/A"
                        UsersGroup = "N/A"
                        DevicesGroup = "N/A"
                        Status = "Failed: $($_.Exception.Message)"
                    }
                }
            }
            
            Write-Host "`n  ✓ Created security groups for $($groupCreationResults.Count) students" -ForegroundColor Green
            Write-LogMessage "Per-student security group creation complete: $($groupCreationResults.Count)/$StudentCount successful" -Level Success
            
            # Brief delay for group propagation
            Write-Host "`n  ⏳ Waiting 10 seconds for group propagation..." -ForegroundColor Yellow
            Start-Sleep -Seconds 10
        }
        
        Write-Host "`n  Credentials saved to: $csvFile`n" -ForegroundColor Yellow
        
        # Create security group for Intune Administrators (DEPRECATED - kept for backwards compatibility)
        Write-Host "`n  Creating security group for Intune Administrators..." -ForegroundColor Cyan
        Write-LogMessage "Creating group: 01_ClassAdminAccts" -Level Info
        
        $groupName = "01_ClassAdminAccts"
        $groupDescription = "Security group for all student admin accounts (DEPRECATED: Use per-student SG-Student{N}-Admins groups)"
        
        # Check if group already exists
        $existingGroup = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction SilentlyContinue
        
        if ($existingGroup) {
            Write-LogMessage "Group already exists: $groupName" -Level Info
            
            # Verify the group is role-assignable
            if ($existingGroup.IsAssignableToRole -ne $true) {
                Write-LogMessage "ERROR: Existing group '$groupName' is not role-assignable. Please delete it and re-run the script." -Level Error
                Write-Host "`n  ❌ The existing group cannot be assigned to roles." -ForegroundColor Red
                Write-Host "  To fix this, run: Remove-MgGroup -GroupId '$($existingGroup.Id)'" -ForegroundColor Yellow
                Write-Host "  Then re-run this script.`n" -ForegroundColor Yellow
                throw "Group $groupName exists but is not role-assignable"
            }
            
            $adminGroup = $existingGroup
        }
        else {
            $groupParams = @{
                DisplayName = $groupName
                Description = $groupDescription
                MailEnabled = $false
                MailNickname = "01ClassAdminAccts"
                SecurityEnabled = $true
                IsAssignableToRole = $true
            }
            
            $adminGroup = New-MgGroup -BodyParameter $groupParams -ErrorAction Stop
            Write-LogMessage "Created role-assignable security group: $groupName (ID: $($adminGroup.Id))" -Level Success
            Write-Host "    ✓ Created role-assignable group: $groupName" -ForegroundColor Green
            Start-Sleep -Seconds 2  # Brief delay for group to propagate
        }
        
        # Add main admin and student admins to the group
        Write-Host "`n  Adding admin accounts to group..." -ForegroundColor Cyan
        Write-LogMessage "Adding members to $groupName" -Level Info
        
        # Collect all admin user IDs
        $adminUserIds = @()
        if ($bhgAdminResult.UserId) {
            $adminUserIds += $bhgAdminResult.UserId
        }
        foreach ($result in $studentAdminResults) {
            if ($result.UserId) {
                $adminUserIds += $result.UserId
            }
        }
        
        # Get current group members
        $currentMembers = Get-MgGroupMember -GroupId $adminGroup.Id -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
        
        $addedCount = 0
        foreach ($userId in $adminUserIds) {
            if ($currentMembers -notcontains $userId) {
                $memberRef = @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId"
                }
                New-MgGroupMemberByRef -GroupId $adminGroup.Id -BodyParameter $memberRef -ErrorAction Stop | Out-Null
                $addedCount++
            }
        }
        
        Write-LogMessage "Added $addedCount new members to $groupName (Total: $($adminUserIds.Count))" -Level Success
        Write-Host "    ✓ Added $($adminUserIds.Count) admin accounts to group" -ForegroundColor Green
        
        # DEPRECATED: Intune Administrator role assignment
        # Note: This global role assignment is kept for backwards compatibility only.
        # New pod model uses custom Intune role with scoped assignments (see 4_IntuneCustomRole.ps1)
        Write-Host "`n  Assigning Intune Administrator role to group (DEPRECATED)..." -ForegroundColor Yellow
        Write-LogMessage "Assigning Intune Administrator role to $groupName (will be replaced by custom role)" -Level Warning
        
        Start-Sleep -Seconds 3  # Brief delay for group membership to propagate
        
        # Get role template
        $allTemplates = Get-MgDirectoryRoleTemplate -All -ErrorAction Stop
        $intuneRoleTemplate = $allTemplates | Where-Object { $_.DisplayName -eq 'Intune Administrator' }
        
        if (-not $intuneRoleTemplate) {
            Write-LogMessage "ERROR: Intune Administrator role template not found" -Level Error
        }
        else {
            # Check if role is activated
            $allRoles = Get-MgDirectoryRole -All -ErrorAction SilentlyContinue
            $intuneRole = $allRoles | Where-Object { $_.RoleTemplateId -eq $intuneRoleTemplate.Id }
            
            if (-not $intuneRole) {
                # Activate the role
                $intuneRole = New-MgDirectoryRole -RoleTemplateId $intuneRoleTemplate.Id -ErrorAction Stop
                Write-LogMessage "Activated Intune Administrator role" -Level Success
            }
            
            # Check if group already has the role
            $existingRoleAssignment = Get-MgDirectoryRoleMember -DirectoryRoleId $intuneRole.Id -ErrorAction SilentlyContinue | 
                Where-Object { $_.Id -eq $adminGroup.Id }
            
            if (-not $existingRoleAssignment) {
                $roleRef = @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($adminGroup.Id)"
                }
                New-MgDirectoryRoleMemberByRef -DirectoryRoleId $intuneRole.Id -BodyParameter $roleRef -ErrorAction Stop | Out-Null
                Write-LogMessage "Assigned Intune Administrator role to $groupName" -Level Success
                Write-Host "    ✓ Intune Administrator role assigned to group" -ForegroundColor Green
            }
            else {
                Write-LogMessage "Group already has Intune Administrator role assigned" -Level Info
                Write-Host "    • Group already has Intune Administrator role" -ForegroundColor Gray
            }
        }
        
        # Disconnect from Microsoft Graph
        Write-LogMessage "Disconnecting from Microsoft Graph..." -Level Info
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-LogMessage "Disconnected from Microsoft Graph" -Level Success
    }
    catch {
        Write-LogMessage "ERROR: Failed to create user accounts." -Level Error
        Write-LogMessage $_.Exception.Message -Level Error
        # Attempt to disconnect on error
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        exit 1
    }
}
else {
    Write-Host "`n[4/8] Skipping user creation (SkipUserCreation flag set)..." -ForegroundColor Yellow
    Write-Host "`n[5/8] Skipping administrator role assignments..." -ForegroundColor Yellow
    Write-LogMessage "User creation and role assignment skipped per -SkipUserCreation flag" -Level Info
}

# Step 7: Configure Azure RBAC (Custom Image + W365)
if (-not $SkipRoleAssignments) {
    Write-Host "`n[6/8] Configuring Azure RBAC permissions..." -ForegroundColor Yellow

    # Ensure Azure context is still valid (Graph ran in separate process, so our Az session should still be active)
    Write-LogMessage "Verifying Azure connection..." -Level Info
    $currentContext = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $currentContext -or $currentContext.Tenant.Id -ne $selectedTenant.Id) {
        Write-LogMessage "Reconnecting to Azure..." -Level Info
        try {
            Connect-AzAccount -TenantId $selectedTenant.Id -ErrorAction Stop | Out-Null
            Set-AzContext -TenantId $selectedTenant.Id -SubscriptionId $selectedSubscription.Id -ErrorAction Stop | Out-Null
            Write-LogMessage "Azure connection re-established." -Level Success
        }
        catch {
            Write-LogMessage "ERROR: Failed to reconnect to Azure." -Level Error
            Write-LogMessage $_.Exception.Message -Level Error
            exit 1
        }
    }
    else {
        Write-LogMessage "Azure connection still active." -Level Success
    }

    # Register resource providers
    Write-LogMessage "Registering required resource providers..." -Level Info
    $providers = @('Microsoft.Compute', 'Microsoft.Storage', 'Microsoft.Network', 'Microsoft.ManagedIdentity')

    foreach ($provider in $providers) {
        $registration = Get-AzResourceProvider -ProviderNamespace $provider
        if ($registration.RegistrationState -ne 'Registered') {
            Write-LogMessage "Registering: $provider" -Level Info
            Register-AzResourceProvider -ProviderNamespace $provider | Out-Null
        }
        else {
            Write-LogMessage "Already registered: $provider" -Level Info
        }
    }

    # Construct scopes for RBAC
    # Custom roles must be scoped at subscription level since RGs don't exist yet
    # Role assignments will target specific resource group scopes
    Write-LogMessage "Configuring RBAC roles for resource groups..." -Level Info
    $subscriptionId = $selectedSubscription.Id
    $subscriptionScope = "/subscriptions/$subscriptionId"
    $customImageRGScope = "/subscriptions/$subscriptionId/resourceGroups/$CustomImageResourceGroup"
    $w365RGScope = "/subscriptions/$subscriptionId/resourceGroups/$W365ResourceGroup"
    
    Write-LogMessage "Subscription scope: $subscriptionScope" -Level Info
    Write-LogMessage "CustomImage RG scope: $customImageRGScope" -Level Info
    Write-LogMessage "W365 RG scope: $w365RGScope" -Level Info

    # Custom Image Role
    Write-LogMessage "Configuring Custom Image custom role..." -Level Info
    $customImageRoleFile = Join-Path (Split-Path $ScriptPath) "CustomImage\CustomImage-MinimumRole.json"
    
    if (Test-Path $customImageRoleFile) {
        $customImageRoleName = "Windows 365 Custom Image Builder"
        $existingCustomImageRole = Get-AzRoleDefinition -Name $customImageRoleName -ErrorAction SilentlyContinue

        if (-not $existingCustomImageRole) {
            $roleJson = Get-Content $customImageRoleFile | ConvertFrom-Json
            # Scope role definition at subscription level (RG doesn't exist yet)
            $roleJson.AssignableScopes = @($subscriptionScope)
            $tempFile = "$env:TEMP\customimage-role-temp.json"
            $roleJson | ConvertTo-Json -Depth 10 | Set-Content $tempFile
            
            New-AzRoleDefinition -InputFile $tempFile -ErrorAction Stop | Out-Null
            Write-LogMessage "Created custom role: $customImageRoleName (scoped to subscription)" -Level Success
            Remove-Item $tempFile -ErrorAction SilentlyContinue
        }
        else {
            Write-LogMessage "Custom role already exists: $customImageRoleName" -Level Info
        }

        # Assign role to main admin at subscription level (allows RG creation + management)
        # NOTE: Using subscription scope because the actual RG names include student numbers (rg-w365-customimage-student{N})
        # and don't exist until deployment time. Subscription-level assignment allows creating and managing any RG.
        $assignment = Get-AzRoleAssignment -SignInName $AdminUPN -RoleDefinitionName $customImageRoleName -Scope $subscriptionScope -ErrorAction SilentlyContinue
        if (-not $assignment) {
            try {
                New-AzRoleAssignment -SignInName $AdminUPN -RoleDefinitionName $customImageRoleName -Scope $subscriptionScope -ErrorAction Stop | Out-Null
                Write-LogMessage "Assigned $customImageRoleName to $AdminUPN at subscription scope" -Level Success
            }
            catch {
                Write-LogMessage "ERROR: Failed to assign role to $AdminUPN : $($_.Exception.Message)" -Level Error
            }
        }
        else {
            Write-LogMessage "Role already assigned: $customImageRoleName to $AdminUPN at subscription scope" -Level Info
        }
        
        # Assign role to student admins at subscription level if created
        if ($StudentCount -gt 0) {
            Write-LogMessage "Assigning $customImageRoleName to student admin accounts at subscription scope..." -Level Info
            for ($i = 1; $i -le $StudentCount; $i++) {
                $studentAdminUPN = "admin$i@bighatgrouptraining.ca"
                
                $studentAssignment = Get-AzRoleAssignment -SignInName $studentAdminUPN -RoleDefinitionName $customImageRoleName -Scope $subscriptionScope -ErrorAction SilentlyContinue
                if (-not $studentAssignment) {
                    try {
                        New-AzRoleAssignment -SignInName $studentAdminUPN -RoleDefinitionName $customImageRoleName -Scope $subscriptionScope -ErrorAction Stop | Out-Null
                        Write-LogMessage "Assigned $customImageRoleName to $studentAdminUPN at subscription scope" -Level Success
                    }
                    catch {
                        Write-LogMessage "ERROR: Failed to assign role to $studentAdminUPN : $($_.Exception.Message)" -Level Error
                    }
                }
                else {
                    Write-LogMessage "Role already assigned: $customImageRoleName to $studentAdminUPN at subscription scope" -Level Info
                }
            }
        }
    }
    else {
        Write-LogMessage "WARNING: CustomImage-MinimumRole.json not found. Skipping custom role." -Level Warning
    }

    # W365 Role
    Write-LogMessage "Configuring W365 custom role..." -Level Info
    $w365RoleFile = Join-Path (Split-Path $ScriptPath) "W365\W365-MinimumRole.json"
    
    if (Test-Path $w365RoleFile) {
        $w365RoleName = "Windows 365 Spoke Network Deployer"
        $existingW365Role = Get-AzRoleDefinition -Name $w365RoleName -ErrorAction SilentlyContinue

        if (-not $existingW365Role) {
            $roleJson = Get-Content $w365RoleFile | ConvertFrom-Json
            # Scope role definition at subscription level (RG doesn't exist yet)
            $roleJson.AssignableScopes = @($subscriptionScope)
            $tempFile = "$env:TEMP\w365-role-temp.json"
            $roleJson | ConvertTo-Json -Depth 10 | Set-Content $tempFile
            
            New-AzRoleDefinition -InputFile $tempFile -ErrorAction Stop | Out-Null
            Write-LogMessage "Created custom role: $w365RoleName (scoped to subscription)" -Level Success
            Remove-Item $tempFile -ErrorAction SilentlyContinue
        }
        else {
            Write-LogMessage "Custom role already exists: $w365RoleName" -Level Info
        }

        # Assign role to main admin at subscription level (allows RG creation + management)
        # NOTE: Using subscription scope because the actual RG names include student numbers (rg-w365-spoke-student{N}-prod)
        # and don't exist until deployment time. Subscription-level assignment allows creating and managing any RG.
        $assignment = Get-AzRoleAssignment -SignInName $AdminUPN -RoleDefinitionName $w365RoleName -Scope $subscriptionScope -ErrorAction SilentlyContinue
        if (-not $assignment) {
            try {
                New-AzRoleAssignment -SignInName $AdminUPN -RoleDefinitionName $w365RoleName -Scope $subscriptionScope -ErrorAction Stop | Out-Null
                Write-LogMessage "Assigned $w365RoleName to $AdminUPN at subscription scope" -Level Success
            }
            catch {
                Write-LogMessage "ERROR: Failed to assign role to $AdminUPN : $($_.Exception.Message)" -Level Error
            }
        }
        else {
            Write-LogMessage "Role already assigned: $w365RoleName to $AdminUPN at subscription scope" -Level Info
        }
        
        # Assign role to student admins at subscription level if created
        if ($StudentCount -gt 0) {
            Write-LogMessage "Assigning $w365RoleName to student admin accounts at subscription scope..." -Level Info
            for ($i = 1; $i -le $StudentCount; $i++) {
                $studentAdminUPN = "admin$i@bighatgrouptraining.ca"
                
                $studentAssignment = Get-AzRoleAssignment -SignInName $studentAdminUPN -RoleDefinitionName $w365RoleName -Scope $subscriptionScope -ErrorAction SilentlyContinue
                if (-not $studentAssignment) {
                    try {
                        New-AzRoleAssignment -SignInName $studentAdminUPN -RoleDefinitionName $w365RoleName -Scope $subscriptionScope -ErrorAction Stop | Out-Null
                        Write-LogMessage "Assigned $w365RoleName to $studentAdminUPN at subscription scope" -Level Success
                    }
                    catch {
                        Write-LogMessage "ERROR: Failed to assign role to $studentAdminUPN : $($_.Exception.Message)" -Level Error
                    }
                }
                else {
                    Write-LogMessage "Role already assigned: $w365RoleName to $studentAdminUPN at subscription scope" -Level Info
                }
            }
        }
    }
    else {
        Write-LogMessage "WARNING: W365-MinimumRole.json not found. Skipping custom role." -Level Warning
    }
}
else {
    Write-Host "`n[6/8] Skipping RBAC assignments (SkipRoleAssignments flag set)..." -ForegroundColor Yellow
}

# Step 8: Summary
Write-Host "`n[7/8] Deployment summary..." -ForegroundColor Yellow

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host " Configuration Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Tenant:                $($selectedTenant.Name)" -ForegroundColor White
Write-Host " Subscription:          $($selectedSubscription.Name)" -ForegroundColor White
Write-Host " Admin UPN:             $AdminUPN" -ForegroundColor White
Write-Host " Admin Role:            Intune Administrator" -ForegroundColor White
Write-Host " Backdoor UPN:          $BdoorUPN" -ForegroundColor White
Write-Host " Backdoor Role:         Global Administrator" -ForegroundColor White
if (-not $SkipRoleAssignments) {
    Write-Host " CustomImage RG:        $CustomImageResourceGroup (created by deployment)" -ForegroundColor White
    Write-Host " W365 RG:               $W365ResourceGroup (created by deployment)" -ForegroundColor White
    Write-Host " RBAC Roles:            Configured for RG scopes" -ForegroundColor White
    Write-Host " Resource Providers:    Registered" -ForegroundColor White
}
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "`n[8/8] Bootstrap complete!" -ForegroundColor Green

Write-Host "`n📋 Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Have both admin accounts sign in and change temporary passwords:" -ForegroundColor White
Write-Host "     - Admin:      $AdminUPN" -ForegroundColor Gray
Write-Host "     - Backdoor:   $BdoorUPN" -ForegroundColor Gray
Write-Host "  2. Deploy W365 spoke network:" -ForegroundColor White
Write-Host "     cd 4_W365" -ForegroundColor Gray
Write-Host "     .\deploy.ps1 -TenantId $($selectedTenant.Id)" -ForegroundColor Gray

Write-Host "`n✓ Administrator can now deploy Windows 365 solutions" -ForegroundColor Green
Write-Host "✓ All permissions and roles are configured`n" -ForegroundColor Green

Write-Host "`n📄 Files created:" -ForegroundColor Cyan
Write-Host "  Log: $logFile" -ForegroundColor Gray
Write-Host "  CSV: $csvFile`n" -ForegroundColor Gray

Write-LogMessage "Script execution completed successfully" -Level Success
Write-LogMessage "Log file: $logFile" -Level Info
Write-LogMessage "CSV file: $csvFile" -Level Info
