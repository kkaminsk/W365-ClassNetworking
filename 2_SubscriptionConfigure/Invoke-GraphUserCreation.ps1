#Requires -Version 7.0
<#
.SYNOPSIS
    Helper script to create user and assign Intune role via Microsoft Graph (runs in isolated process)
#>
param(
    [Parameter(Mandatory=$false)]
    [string]$TenantId,
    
    [Parameter(Mandatory=$false)]
    [string]$AdminUPN = "admin@bighatgrouptraining.ca",
    
    [Parameter(Mandatory=$false)]
    [string]$AdminDisplayName = "BHG Class Admin",
    
    [Parameter(Mandatory=$false)]
    [string]$TenantNumberPadded,
    
    [Parameter(Mandatory=$false)]
    [string]$CsvFile,
    
    [Parameter(Mandatory=$false)]
    [string]$DirectoryRole = "Intune Administrator",
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipTenantConfirmation
)

$ErrorActionPreference = "Stop"

try {
    # Import modules
    Import-Module Microsoft.Graph.Users -ErrorAction Stop
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    
    # List available tenants and confirm default tenant
    if (-not $TenantId -or -not $SkipTenantConfirmation) {
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "TENANT SELECTION" -ForegroundColor Cyan
        Write-Host "========================================`n" -ForegroundColor Cyan
        
        # Try to get available tenants from existing Graph context
        $availableTenants = @()
        $currentContext = Get-MgContext -ErrorAction SilentlyContinue
        
        if ($currentContext) {
            Write-Host "[Tenant] Found existing Graph connection" -ForegroundColor Yellow
            Write-Host "[Tenant] Current Tenant: $($currentContext.TenantId)" -ForegroundColor Gray
            $availableTenants += $currentContext.TenantId
        }
        
        # Attempt to connect and list available tenants
        Write-Host "`n[Tenant] Connecting to Microsoft Graph to enumerate available tenants..." -ForegroundColor Cyan
        Write-Host "[Tenant] Browser authentication may be required..." -ForegroundColor Yellow
        
        try {
            # Connect without specifying tenant to get available tenants
            if (-not $currentContext) {
                Connect-MgGraph -Scopes "User.Read.All", "Organization.Read.All" -NoWelcome -ErrorAction Stop | Out-Null
                $currentContext = Get-MgContext
            }
            
            # Get organization details for current tenant
            $org = Get-MgOrganization -ErrorAction Stop
            $defaultTenant = $currentContext.TenantId
            
            Write-Host "`n[Tenant] Available Tenant(s):" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Gray
            Write-Host "Tenant ID:        $defaultTenant" -ForegroundColor White
            Write-Host "Display Name:     $($org.DisplayName)" -ForegroundColor White
            Write-Host "Default Domain:   $($org.VerifiedDomains | Where-Object IsDefault | Select-Object -ExpandProperty Name)" -ForegroundColor White
            Write-Host "Verified Domains: $($org.VerifiedDomains.Name -join ', ')" -ForegroundColor White
            Write-Host "========================================`n" -ForegroundColor Gray
            
            # If TenantId was not provided, use the default
            if (-not $TenantId) {
                $TenantId = $defaultTenant
                Write-Host "[Tenant] No TenantId specified, using default: $TenantId" -ForegroundColor Yellow
            }
            
            # Confirm with user unless skip flag is set
            if (-not $SkipTenantConfirmation) {
                Write-Host "`n[Tenant] Proceeding with Tenant: $TenantId" -ForegroundColor Cyan
                $confirmation = Read-Host "[Tenant] Is this correct? (Y/N)"
                
                if ($confirmation -notmatch '^[Yy]') {
                    Write-Host "[Tenant] Operation cancelled by user" -ForegroundColor Red
                    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
                    exit 0
                }
                
                Write-Host "[Tenant] Tenant confirmed: $TenantId" -ForegroundColor Green
            }
            
            # Disconnect to reconnect with proper scopes for the confirmed tenant
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Write-Host "[Tenant] WARNING: Could not enumerate tenants automatically" -ForegroundColor Yellow
            Write-Host "[Tenant] Error: $($_.Exception.Message)" -ForegroundColor Yellow
            
            if (-not $TenantId) {
                Write-Error "TenantId parameter is required when automatic tenant detection fails"
                exit 1
            }
            
            Write-Host "[Tenant] Proceeding with provided TenantId: $TenantId" -ForegroundColor Cyan
        }
        
        Write-Host "`n========================================`n" -ForegroundColor Cyan
    }
    
    # TenantNumberPadded is optional for single tenant design (bhgtraining.ca)
    # Only used for legacy multi-tenant scenarios or MailNickname generation
    if ($TenantNumberPadded) {
        Write-Host "[Config] Tenant Number specified: $TenantNumberPadded" -ForegroundColor Gray
    }
    else {
        Write-Host "[Config] Single tenant mode (no tenant number required)" -ForegroundColor Gray
    }
    
    # Connect to Microsoft Graph
    Write-Host "[Graph] Connecting to Microsoft Graph for tenant $TenantId..." -ForegroundColor Cyan
    Write-Host "[Graph] Browser authentication may be required..." -ForegroundColor Yellow
    
    try {
        Connect-MgGraph -TenantId $TenantId -Scopes "User.ReadWrite.All", "RoleManagement.ReadWrite.Directory", "Organization.Read.All" -NoWelcome -ErrorAction Stop | Out-Null
        
        # Verify connection succeeded
        $context = Get-MgContext
        if (-not $context) {
            Write-Error "Failed to establish Microsoft Graph connection"
            exit 1
        }
        
        Write-Host "[Graph] Connected to Microsoft Graph successfully" -ForegroundColor Green
        Write-Host "[Graph] Account: $($context.Account)" -ForegroundColor Gray
    }
    catch {
        Write-Host "[Graph] ERROR: Failed to connect to Microsoft Graph" -ForegroundColor Red
        Write-Host "[Graph] Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Error "Microsoft Graph authentication failed. Please ensure you have appropriate permissions and can complete authentication."
        exit 1
    }
    
    # Verify the domain exists in this tenant
    Write-Host "[Graph] Verifying domain for UPN: $AdminUPN..." -ForegroundColor Cyan
    $upnUsername = $AdminUPN.Split('@')[0]
    $upnDomain = $AdminUPN.Split('@')[1]
    
    $org = Get-MgOrganization -ErrorAction Stop
    $verifiedDomain = $org.VerifiedDomains | Where-Object { $_.Name -eq $upnDomain }
    
    if (-not $verifiedDomain) {
        # Try to find bighatgrouptraining.ca as fallback
        $bhgDomain = $org.VerifiedDomains | Where-Object { $_.Name -eq 'bighatgrouptraining.ca' }
        
        if ($bhgDomain) {
            Write-Host "[Graph] Domain '$upnDomain' not found, using bighatgrouptraining.ca..." -ForegroundColor Yellow
            $upnDomain = 'bighatgrouptraining.ca'
            $AdminUPN = "$upnUsername@$upnDomain"
            Write-Host "[Graph] Adjusted UPN to: $AdminUPN" -ForegroundColor Cyan
            Write-Output "DOMAIN_ADJUSTED|$AdminUPN"
            $verifiedDomain = $bhgDomain
        }
    }
    
    if (-not $verifiedDomain) {
        Write-Host "[Graph] ERROR: Domain '$upnDomain' is not verified in this tenant" -ForegroundColor Red
        Write-Host "[Graph] Available verified domains:" -ForegroundColor Yellow
        $org.VerifiedDomains | ForEach-Object {
            Write-Host "[Graph]   - $($_.Name)" -ForegroundColor Gray
        }
        Write-Error "Domain '$upnDomain' is not a verified domain in tenant $TenantId"
        exit 1
    }
    
    Write-Host "[Graph] Domain verified: $upnDomain" -ForegroundColor Green
    
    # Check if user exists
    Write-Host "[Graph] Checking if user exists: $AdminUPN" -ForegroundColor Cyan
    $existingUser = Get-MgUser -Filter "userPrincipalName eq '$AdminUPN'" -ErrorAction SilentlyContinue
    
    $password = $null
    $userId = $null
    
    if ($existingUser) {
        Write-Host "[Graph] User already exists: $AdminUPN" -ForegroundColor Green
        $userId = $existingUser.Id
        Write-Output "USER_EXISTS|$userId"
    }
    else {
        # Generate random password
        $password = -join ((65..90) + (97..122) + (48..57) + (33, 35, 36, 37, 38, 42, 43, 61) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
        
        Write-Host "[Graph] Creating new user: $AdminUPN" -ForegroundColor Cyan
        $passwordProfile = @{
            Password                      = $password
            ForceChangePasswordNextSignIn = $true
        }
        
        # Generate MailNickname from username part of UPN
        $mailNickname = if ($TenantNumberPadded) {
            "bhgadmin$TenantNumberPadded"
        }
        else {
            $upnUsername -replace '[^a-zA-Z0-9]', ''
        }
        
        $userParams = @{
            UserPrincipalName = $AdminUPN
            DisplayName       = $AdminDisplayName
            MailNickname      = $mailNickname
            AccountEnabled    = $true
            PasswordProfile   = $passwordProfile
            UsageLocation     = "US"
        }
        
        $adminUser = New-MgUser -BodyParameter $userParams -ErrorAction Stop
        $userId = $adminUser.Id
        Write-Host "[Graph] User created successfully: $AdminUPN (ObjectId: $userId)" -ForegroundColor Green
        
        # Export credentials to CSV if specified
        if ($CsvFile) {
            $csvEntry = "$AdminUPN,$password,$DirectoryRole,$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            $csvEntry | Out-File -FilePath $CsvFile -Append -Encoding UTF8
            Write-Host "[Graph] Credentials saved to CSV" -ForegroundColor Green
        }
        
        Write-Output "USER_CREATED|$userId|$password"
    }
    
    # Assign Directory Role (skip for regular users)
    if ($DirectoryRole -and $DirectoryRole -ne "User") {
        Write-Host "[Graph] Assigning $DirectoryRole role..." -ForegroundColor Cyan
        
        # Get all directory roles and filter client-side (Filter parameter not supported)
        $targetRole = Get-MgDirectoryRole -All -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $DirectoryRole }
        
        if (-not $targetRole) {
            Write-Host "[Graph] Activating $DirectoryRole role..." -ForegroundColor Yellow
            # Get all role templates and filter client-side (Filter parameter not supported)
            $roleTemplate = Get-MgDirectoryRoleTemplate -All -ErrorAction Stop | Where-Object { $_.DisplayName -eq $DirectoryRole }
            
            if (-not $roleTemplate) {
                Write-Error "Could not find '$DirectoryRole' role template"
                exit 1
            }
            
            $targetRole = New-MgDirectoryRole -RoleTemplateId $roleTemplate.Id -ErrorAction Stop
            Write-Host "[Graph] $DirectoryRole role activated" -ForegroundColor Green
        }
        
        $existingAssignment = Get-MgDirectoryRoleMember -DirectoryRoleId $targetRole.Id -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq $userId }
        
        if ($existingAssignment) {
            Write-Host "[Graph] User already has $DirectoryRole role" -ForegroundColor Green
        }
        else {
            $directoryObject = @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId"
            }
            New-MgDirectoryRoleMemberByRef -DirectoryRoleId $targetRole.Id -BodyParameter $directoryObject -ErrorAction Stop
            Write-Host "[Graph] $DirectoryRole role assigned successfully" -ForegroundColor Green
        }
        
        Write-Output "ROLE_ASSIGNED|$DirectoryRole"
    }
    else {
        Write-Host "[Graph] No directory role assignment required (regular user)" -ForegroundColor Gray
        Write-Output "ROLE_ASSIGNED|None"
    }
    
    # Disconnect
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    
    exit 0
}
catch {
    Write-Error "Graph operation failed: $($_.Exception.Message)"
    exit 1
}
