<#
.SYNOPSIS
    Automates the creation of student user accounts for Windows 365 deployment.

.DESCRIPTION
    This script creates a specified number of student accounts in Microsoft 365
    and adds them to the W365 Class security group. Group membership automatically
    triggers license assignment via group-based licensing and Windows 365 
    provisioning via the group's assigned provisioning profile. The script
    generates credential files for easy distribution.

.NOTES
    File Name      : New-W365Students.ps1
    Prerequisite   : PowerShell 7+, Microsoft.Graph module
    Required Roles : Global Administrator or User Administrator
    Requirements   : W365 Class group must have group-based licensing and provisioning profile configured
    Author         : Auto-generated from specification
    Date           : 2025-10-13
#>

#Requires -Version 7.0

# ============================================================================
# SECTION 1: LOGGING SETUP
# ============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR', 'INPUT')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console with color coding
    switch ($Level) {
        'ERROR'   { Write-Host $logEntry -ForegroundColor Red }
        'WARNING' { Write-Host $logEntry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $logEntry -ForegroundColor Green }
        'INPUT'   { Write-Host $logEntry -ForegroundColor Cyan }
        default   { Write-Host $logEntry }
    }
    
    # Write to log file
    Add-Content -Path $script:LogFilePath -Value $logEntry
}

# Initialize log file
$logFileName = "W365ClassDeploy-$(Get-Date -Format 'yyyy-MM-dd-HH-mm').log"
$script:LogFilePath = Join-Path -Path $env:USERPROFILE -ChildPath "Documents\$logFileName"

# Create log file
try {
    New-Item -Path $script:LogFilePath -ItemType File -Force | Out-Null
    Write-Log -Message "Log file created at: $script:LogFilePath" -Level INFO
}
catch {
    Write-Host "FATAL: Unable to create log file at $script:LogFilePath" -ForegroundColor Red
    exit 1
}

# ============================================================================
# SECTION 2: MODULE VERIFICATION AND IMPORT
# ============================================================================

Write-Log -Message "Verifying PowerShell version..." -Level INFO
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Log -Message "PowerShell 7 or newer is required. Current version: $($PSVersionTable.PSVersion)" -Level ERROR
    exit 1
}
Write-Log -Message "PowerShell version $($PSVersionTable.PSVersion) confirmed." -Level SUCCESS

Write-Log -Message "Checking for Microsoft.Graph module..." -Level INFO
$graphModule = Get-Module -ListAvailable -Name Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement

if (-not $graphModule) {
    Write-Log -Message "Microsoft.Graph modules not found. Installing..." -Level WARNING
    try {
        Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
        Write-Log -Message "Microsoft.Graph module installed successfully." -Level SUCCESS
    }
    catch {
        Write-Log -Message "Failed to install Microsoft.Graph module: $($_.Exception.Message)" -Level ERROR
        exit 1
    }
}

Write-Log -Message "Importing Microsoft.Graph modules..." -Level INFO
try {
    # Import only the specific modules we need (faster than importing entire Microsoft.Graph)
    $modulesToImport = @(
        'Microsoft.Graph.Authentication'
        'Microsoft.Graph.Users'
        'Microsoft.Graph.Groups'
        'Microsoft.Graph.Identity.DirectoryManagement'
    )
    
    foreach ($moduleName in $modulesToImport) {
        $loadedModule = Get-Module -Name $moduleName
        if (-not $loadedModule) {
            Write-Host "  Loading $moduleName..." -ForegroundColor Gray
            Import-Module $moduleName -ErrorAction Stop -WarningAction SilentlyContinue
        }
    }
    
    Write-Log -Message "Microsoft.Graph modules imported successfully." -Level SUCCESS
}
catch {
    Write-Log -Message "Failed to import Microsoft.Graph modules: $($_.Exception.Message)" -Level ERROR
    Write-Log -Message "TIP: Try running 'Disconnect-MgGraph' then close and reopen PowerShell." -Level WARNING
    exit 1
}

# ============================================================================
# SECTION 3: MICROSOFT GRAPH CONNECTION
# ============================================================================

Write-Log -Message "Connecting to Microsoft Graph..." -Level INFO
try {
    # Request necessary permissions
    $requiredScopes = @(
        'User.ReadWrite.All',
        'Group.ReadWrite.All',
        'Directory.ReadWrite.All',
        'Organization.Read.All'
    )
    
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome -ErrorAction Stop
    
    $context = Get-MgContext
    Write-Log -Message "Successfully connected to Microsoft Graph." -Level SUCCESS
    Write-Log -Message "Tenant ID: $($context.TenantId)" -Level INFO
    Write-Log -Message "Account: $($context.Account)" -Level INFO
}
catch {
    Write-Log -Message "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -Level ERROR
    exit 1
}

# Get tenant domain
try {
    $organization = Get-MgOrganization
    $tenantDomain = $organization.VerifiedDomains | Where-Object { $_.IsDefault -eq $true } | Select-Object -ExpandProperty Name
    Write-Log -Message "Tenant Domain: $tenantDomain" -Level INFO
}
catch {
    Write-Log -Message "Failed to retrieve tenant domain: $($_.Exception.Message)" -Level ERROR
    Disconnect-MgGraph | Out-Null
    exit 1
}

# ============================================================================
# SECTION 4: USER INPUT AND VALIDATION
# ============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "W365 Student Account Creation Script" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Get Account Count
do {
    $accountCountInput = Read-Host "Enter the number of student accounts to create (1-40)"
    $accountCountValid = [int]::TryParse($accountCountInput, [ref]$null)
    
    if ($accountCountValid) {
        $AccountCount = [int]$accountCountInput
        if ($AccountCount -lt 1 -or $AccountCount -gt 40) {
            Write-Host "ERROR: Account count must be between 1 and 40." -ForegroundColor Red
            $accountCountValid = $false
        }
    }
    else {
        Write-Host "ERROR: Please enter a valid number." -ForegroundColor Red
    }
} while (-not $accountCountValid)

Write-Log -Message "Administrator requested $AccountCount accounts." -Level INPUT

# Get Group ID
do {
    $GroupId = Read-Host "Enter the W365 Class Group Object ID (GUID)"
    $guidValid = $GroupId -match '^[{]?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}[}]?$'
    
    if (-not $guidValid) {
        Write-Host "ERROR: Invalid GUID format. Please enter a valid Group Object ID." -ForegroundColor Red
    }
} while (-not $guidValid)

Write-Log -Message "Target Group ID: $GroupId" -Level INPUT

# Verify group exists
try {
    $targetGroup = Get-MgGroup -GroupId $GroupId -ErrorAction Stop
    Write-Log -Message "Target group verified: $($targetGroup.DisplayName)" -Level SUCCESS
}
catch {
    Write-Log -Message "Failed to retrieve group with ID $GroupId : $($_.Exception.Message)" -Level ERROR
    Disconnect-MgGraph | Out-Null
    exit 1
}

# ============================================================================
# SECTION 5: GROUP-BASED LICENSING REMINDER
# ============================================================================

Write-Log -Message "License and provisioning configuration:" -Level INFO
Write-Log -Message "  - Licenses will be assigned automatically via group-based licensing" -Level INFO
Write-Log -Message "  - W365 provisioning will be triggered by the group's provisioning profile" -Level INFO
Write-Log -Message "  - Ensure the '$($targetGroup.DisplayName)' group has licenses and provisioning configured" -Level WARNING

# ============================================================================
# SECTION 6: USER PROVISIONING
# ============================================================================

Write-Log -Message "Beginning user provisioning process..." -Level INFO

# Initialize credential array
$credentialList = @()

# Function to generate strong password
function New-StrongPassword {
    $length = 16
    $charSet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*'
    $password = -join ((1..$length) | ForEach-Object { $charSet[(Get-Random -Maximum $charSet.Length)] })
    
    # Ensure password meets complexity requirements
    if ($password -notmatch '[a-z]') { $password = $password.Substring(0, $length - 1) + 'a' }
    if ($password -notmatch '[A-Z]') { $password = $password.Substring(0, $length - 2) + 'A' + $password.Substring($length - 1) }
    if ($password -notmatch '[0-9]') { $password = $password.Substring(0, $length - 3) + '1' + $password.Substring($length - 2) }
    if ($password -notmatch '[!@#$%^&*]') { $password = $password.Substring(0, $length - 4) + '!' + $password.Substring($length - 3) }
    
    return $password
}

# Create users
for ($i = 1; $i -le $AccountCount; $i++) {
    $displayName = "LabAdmin$i"
    $upn = "LabAdmin$i@$tenantDomain"
    $mailNickname = "LabAdmin$i"
    
    Write-Log -Message "Creating user $i of ${AccountCount}: $upn" -Level INFO
    
    # Generate password
    $initialPassword = New-StrongPassword
    
    try {
        # Create user
        $passwordProfile = @{
            Password                      = $initialPassword
            ForceChangePasswordNextSignIn = $true
        }
        
        $userParams = @{
            AccountEnabled    = $true
            DisplayName       = $displayName
            MailNickname      = $mailNickname
            UserPrincipalName = $upn
            PasswordProfile   = $passwordProfile
        }
        
        $newUser = New-MgUser @userParams -ErrorAction Stop
        Write-Log -Message "User $upn created successfully (Object ID: $($newUser.Id))" -Level SUCCESS
        
        # Add to group (group membership triggers license assignment and W365 provisioning)
        try {
            Start-Sleep -Seconds 2  # Brief delay to ensure user is fully provisioned
            
            $groupMemberParams = @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($newUser.Id)"
            }
            
            New-MgGroupMemberByRef -GroupId $GroupId -BodyParameter $groupMemberParams -ErrorAction Stop
            Write-Log -Message "User $upn added to group $($targetGroup.DisplayName)" -Level SUCCESS
            Write-Log -Message "  Group membership will trigger automatic license assignment and W365 provisioning" -Level INFO
        }
        catch {
            Write-Log -Message "Failed to add $upn to group: $($_.Exception.Message)" -Level ERROR
        }
        
        # Store credentials
        $credentialList += [PSCustomObject]@{
            UPN              = $upn
            DisplayName      = $displayName
            TemporaryPassword = $initialPassword
            ObjectId         = $newUser.Id
        }
        
        Write-Log -Message "User $upn provisioned successfully." -Level SUCCESS
    }
    catch {
        Write-Log -Message "Failed to create user ${upn}: $($_.Exception.Message)" -Level ERROR
        continue
    }
}

# ============================================================================
# SECTION 7: CREDENTIAL XML EXPORT
# ============================================================================

Write-Log -Message "Exporting credentials to XML file..." -Level INFO

$xmlFileName = "W365ClassCredentials-$(Get-Date -Format 'yyyy-MM-dd-HH-mm').xml"
$xmlFilePath = Join-Path -Path $env:USERPROFILE -ChildPath "Documents\$xmlFileName"

try {
    # Create XML structure
    $xmlWriter = New-Object System.Xml.XmlTextWriter($xmlFilePath, $null)
    $xmlWriter.Formatting = 'Indented'
    $xmlWriter.Indentation = 2
    
    $xmlWriter.WriteStartDocument()
    $xmlWriter.WriteStartElement('W365ClassCredentials')
    $xmlWriter.WriteAttributeString('GeneratedDate', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $xmlWriter.WriteAttributeString('TenantDomain', $tenantDomain)
    $xmlWriter.WriteAttributeString('AccountCount', $credentialList.Count.ToString())
    
    foreach ($credential in $credentialList) {
        $xmlWriter.WriteStartElement('User')
        $xmlWriter.WriteElementString('UPN', $credential.UPN)
        $xmlWriter.WriteElementString('DisplayName', $credential.DisplayName)
        $xmlWriter.WriteElementString('TemporaryPassword', $credential.TemporaryPassword)
        $xmlWriter.WriteElementString('ObjectId', $credential.ObjectId)
        $xmlWriter.WriteEndElement()
    }
    
    $xmlWriter.WriteEndElement()
    $xmlWriter.WriteEndDocument()
    $xmlWriter.Flush()
    $xmlWriter.Close()
    
    Write-Log -Message "Credentials exported successfully to: $xmlFilePath" -Level SUCCESS
    Write-Log -Message "WARNING: This file contains sensitive information. Secure it immediately!" -Level WARNING
}
catch {
    Write-Log -Message "Failed to export credentials to XML: $($_.Exception.Message)" -Level ERROR
}

# Also export as CSV for easier viewing
$csvFileName = "W365ClassCredentials-$(Get-Date -Format 'yyyy-MM-dd-HH-mm').csv"
$csvFilePath = Join-Path -Path $env:USERPROFILE -ChildPath "Documents\$csvFileName"

try {
    $credentialList | Export-Csv -Path $csvFilePath -NoTypeInformation -Encoding UTF8
    Write-Log -Message "Credentials also exported to CSV: $csvFilePath" -Level SUCCESS
}
catch {
    Write-Log -Message "Failed to export credentials to CSV: $($_.Exception.Message)" -Level ERROR
}

# ============================================================================
# SECTION 8: CLEANUP AND SUMMARY
# ============================================================================

Write-Log -Message "Disconnecting from Microsoft Graph..." -Level INFO
Disconnect-MgGraph | Out-Null

Write-Log -Message "========================================" -Level INFO
Write-Log -Message "DEPLOYMENT SUMMARY" -Level INFO
Write-Log -Message "========================================" -Level INFO
Write-Log -Message "Total Accounts Requested: $AccountCount" -Level INFO
Write-Log -Message "Accounts Successfully Created: $($credentialList.Count)" -Level INFO
Write-Log -Message "Target Group: $($targetGroup.DisplayName)" -Level INFO
Write-Log -Message "Licensing: Assigned via group-based licensing" -Level INFO
Write-Log -Message "Provisioning: Controlled by group provisioning profile" -Level INFO
Write-Log -Message "NOTE: W365 provisioning may take 15-30 minutes after group membership" -Level INFO
Write-Log -Message "Log File: $script:LogFilePath" -Level INFO
Write-Log -Message "Credentials XML: $xmlFilePath" -Level INFO
Write-Log -Message "Credentials CSV: $csvFilePath" -Level INFO
Write-Log -Message "========================================" -Level INFO
Write-Log -Message "Script execution completed." -Level SUCCESS

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Deployment Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Check the log file for details: $script:LogFilePath" -ForegroundColor Cyan
Write-Host "Credentials saved to: $xmlFilePath" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Green