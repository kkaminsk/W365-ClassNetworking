#Requires -Version 7.0
<#
.SYNOPSIS
    Creates Intune scope tags for each student and assigns them to administrator accounts.

.DESCRIPTION
    This script automates the creation of Intune scope tags (ST1, ST2, ST3, etc.) 
    for managing student-specific Windows 365 Cloud PCs. Each scope tag enables a
    student administrator (admin1@, admin2@, etc.) to manage their corresponding
    student's Cloud PC (W365Student1, W365Student2, etc.).
    
    Scope tag and account mapping:
    - ST1: admin1@ manages W365Student1@bighatgrouptraining.ca
    - ST2: admin2@ manages W365Student2@bighatgrouptraining.ca
    - ST3: admin3@ manages W365Student3@bighatgrouptraining.ca
    - etc.
    
    The script:
    - Connects to Microsoft Graph with Intune permissions
    - Creates scope tags (ST1, ST2, ST3, etc.)
    - Verifies administrator accounts exist
    - Exports scope tag mappings to CSV for documentation

.PARAMETER StudentCount
    Number of scope tags to create (should match number of student accounts)

.PARAMETER AdminUPNs
    Array of administrator UPNs to assign scope tags to.
    Leave empty to auto-assign to student admins (admin1@, admin2@, etc.)
    Default: empty (auto-assign to student admins)

.PARAMETER TenantId
    Optional Azure AD tenant ID to target

.PARAMETER SkipTagCreation
    Skip scope tag creation (useful for re-assigning existing tags)

.EXAMPLE
    .\2_ScopeTags.ps1
    Interactive mode: prompts for student count and creates/assigns scope tags

.EXAMPLE
    .\2_ScopeTags.ps1 -StudentCount 25 -AdminUPNs "admin@bighatgrouptraining.ca","instructor@bighatgrouptraining.ca"
    Creates 25 scope tags and assigns to both admin accounts

.EXAMPLE
    .\2_ScopeTags.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -StudentCount 20
    Creates scope tags in specific tenant

.NOTES
    Requires:
    - PowerShell 7.0 or newer
    - Microsoft.Graph.Authentication module
    - Microsoft.Graph.DeviceManagement module
    - Intune Administrator or Global Administrator role
    
    Scope tags enable role-based access control (RBAC) in Intune, allowing
    administrators to manage specific Cloud PCs assigned to individual students.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$StudentCount,

    [Parameter(Mandatory = $false)]
    [string[]]$AdminUPNs = @(),

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [switch]$SkipTagCreation
)

$ErrorActionPreference = "Stop"

# Initialize log and CSV files in Documents folder
$documentsFolder = [Environment]::GetFolderPath('MyDocuments')
$timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
$logFile = Join-Path $documentsFolder "ScopeTags-$timestamp.log"
$csvFile = Join-Path $documentsFolder "ScopeTags-$timestamp.csv"

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

# ============================================================================
# Main Script
# ============================================================================

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Intune Scope Tag Management" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Log file: $logFile" -ForegroundColor Gray
Write-Host "CSV file: $csvFile" -ForegroundColor Gray

"" | Out-File -FilePath $logFile -Encoding UTF8
"==========================================" | Out-File -FilePath $logFile -Append -Encoding UTF8
"Intune Scope Tag Management" | Out-File -FilePath $logFile -Append -Encoding UTF8
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
Write-Host "`n[1/5] Checking required modules..." -ForegroundColor Yellow

$requiredModules = @(
    @{ Name = "Microsoft.Graph.Authentication"; Description = "Microsoft Graph authentication" },
    @{ Name = "Microsoft.Graph.DeviceManagement"; Description = "Intune device management" },
    @{ Name = "Microsoft.Graph.Users"; Description = "Microsoft Graph user management" }
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module.Name)) {
        Write-LogMessage "ERROR: Module '$($module.Name)' is not installed." -Level Error
        Write-Host "Install it with: Install-Module -Name $($module.Name) -Repository PSGallery -Force" -ForegroundColor Yellow
        exit 1
    }
    Write-LogMessage "$($module.Description): $($module.Name) installed" -Level Success
}

# Step 3: Get student count if not provided
if (-not $StudentCount) {
    Write-Host "`n[2/5] Student count configuration..." -ForegroundColor Yellow
    
    do {
        $studentCountInput = Read-Host "`nEnter the number of student scope tags to create (1-100)"
        $valid = [int]::TryParse($studentCountInput, [ref]$null)
        
        if ($valid) {
            $StudentCount = [int]$studentCountInput
            if ($StudentCount -lt 1 -or $StudentCount -gt 100) {
                Write-Host "  ERROR: Student count must be between 1 and 100." -ForegroundColor Red
                $valid = $false
            }
        }
        else {
            Write-Host "  ERROR: Please enter a valid number." -ForegroundColor Red
        }
    } while (-not $valid)
}
else {
    Write-Host "`n[2/5] Using provided student count: $StudentCount" -ForegroundColor Yellow
}

Write-LogMessage "Will create $StudentCount scope tags (ST1-ST$StudentCount)" -Level Info

# Step 4: Connect to Microsoft Graph
Write-Host "`n[3/5] Connecting to Microsoft Graph..." -ForegroundColor Yellow
Write-LogMessage "Connecting to Microsoft Graph with Intune permissions..." -Level Info

try {
    $requiredScopes = @(
        'DeviceManagementRBAC.ReadWrite.All',
        'DeviceManagementConfiguration.ReadWrite.All',
        'User.Read.All'
    )
    
    if ($TenantId) {
        Connect-MgGraph -TenantId $TenantId -Scopes $requiredScopes -NoWelcome -ErrorAction Stop
        Write-LogMessage "Connected to specified tenant: $TenantId" -Level Success
    }
    else {
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome -ErrorAction Stop
        Write-LogMessage "Connected to Microsoft Graph" -Level Success
    }
    
    $context = Get-MgContext
    Write-Host "`n  Account:   $($context.Account)" -ForegroundColor White
    Write-Host "  Tenant ID: $($context.TenantId)" -ForegroundColor White
    Write-LogMessage "Authenticated as: $($context.Account)" -Level Success
}
catch {
    Write-LogMessage "ERROR: Failed to connect to Microsoft Graph" -Level Error
    Write-LogMessage $_.Exception.Message -Level Error
    exit 1
}

# Step 5: Create or verify scope tags
if (-not $SkipTagCreation) {
    Write-Host "`n[4/5] Creating Intune scope tags..." -ForegroundColor Yellow
    Write-LogMessage "Creating scope tags..." -Level Info
    
    $createdTags = @()
    $existingTags = @()
    
    for ($i = 1; $i -le $StudentCount; $i++) {
        $tagName = "ST$i"
        $tagDescription = "Scope tag: admin$i manages W365Student$i"
        
        Write-Host "  Processing scope tag: $tagName" -ForegroundColor Gray
        
        try {
            # Check if scope tag already exists
            $uri = "https://graph.microsoft.com/beta/deviceManagement/roleScopeTags?`$filter=displayName eq '$tagName'"
            $existingTag = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
            
            if ($existingTag.value -and $existingTag.value.Count -gt 0) {
                Write-LogMessage "Scope tag already exists: $tagName (ID: $($existingTag.value[0].id))" -Level Info
                $existingTags += [PSCustomObject]@{
                    Name        = $tagName
                    Description = $existingTag.value[0].description
                    Id          = $existingTag.value[0].id
                    Status      = "Existing"
                }
            }
            else {
                # Create new scope tag
                $body = @{
                    displayName = $tagName
                    description = $tagDescription
                } | ConvertTo-Json
                
                $newTag = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/roleScopeTags" -Body $body -ContentType "application/json" -ErrorAction Stop
                
                Write-LogMessage "Created scope tag: $tagName (ID: $($newTag.id))" -Level Success
                $createdTags += [PSCustomObject]@{
                    Name        = $tagName
                    Description = $tagDescription
                    Id          = $newTag.id
                    Status      = "Created"
                }
                
                Start-Sleep -Milliseconds 500  # Rate limiting
            }
        }
        catch {
            Write-LogMessage "ERROR: Failed to create scope tag $tagName : $($_.Exception.Message)" -Level Error
        }
    }
    
    $allTags = $createdTags + $existingTags
    Write-LogMessage "Scope tag creation complete. Created: $($createdTags.Count), Existing: $($existingTags.Count)" -Level Success
}
else {
    Write-Host "`n[4/5] Skipping scope tag creation (SkipTagCreation flag set)..." -ForegroundColor Yellow
    Write-LogMessage "Scope tag creation skipped per -SkipTagCreation flag" -Level Info
    
    # Retrieve existing scope tags
    Write-LogMessage "Retrieving existing scope tags..." -Level Info
    $allTags = @()
    
    for ($i = 1; $i -le $StudentCount; $i++) {
        $tagName = "ST$i"
        
        try {
            $uri = "https://graph.microsoft.com/beta/deviceManagement/roleScopeTags?`$filter=displayName eq '$tagName'"
            $existingTag = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
            
            if ($existingTag.value -and $existingTag.value.Count -gt 0) {
                $allTags += [PSCustomObject]@{
                    Name        = $tagName
                    Description = $existingTag.value[0].description
                    Id          = $existingTag.value[0].id
                    Status      = "Existing"
                }
            }
        }
        catch {
            Write-LogMessage "WARNING: Could not find scope tag $tagName" -Level Warning
        }
    }
}

# Step 6: Scope tag creation complete
# NOTE: Scope tag assignment is now handled by 4_IntuneCustomRole.ps1
# The custom Intune role assignments include scope tags as part of their configuration
Write-Host "`n[5/5] Scope tag creation complete" -ForegroundColor Yellow
Write-LogMessage "Scope tags created successfully. Assignment will be handled by 4_IntuneCustomRole.ps1" -Level Info
Write-Host "`n  ✔ Created $($allTags.Count) scope tags (ST1-ST$StudentCount)" -ForegroundColor Green
Write-Host "  ➡️  Next: Run 3_AdministrativeUnits.ps1 to create AUs" -ForegroundColor Cyan
Write-Host "  ➡️  Then: Run 4_IntuneCustomRole.ps1 to assign scope tags with custom role" -ForegroundColor Cyan

# Export scope tag mappings to CSV
Write-LogMessage "Exporting scope tag mappings to CSV..." -Level Info

try {
    # Add admin assignments to CSV data
    $csvData = $allTags | Select-Object Name, Description, Id, Status
    $csvData | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
    Write-LogMessage "CSV export complete: $csvFile" -Level Success
}
catch {
    Write-LogMessage "ERROR: Failed to export CSV: $($_.Exception.Message)" -Level Error
}

# Disconnect
Write-LogMessage "Disconnecting from Microsoft Graph..." -Level Info
Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

# Summary
Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host " Scope Tag Configuration Summary" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Student Count:        $StudentCount" -ForegroundColor White
Write-Host " Scope Tags Created:   $($createdTags.Count)" -ForegroundColor White
Write-Host " Scope Tags Existing:  $($existingTags.Count)" -ForegroundColor White
Write-Host " Total Scope Tags:     $($allTags.Count)" -ForegroundColor White
Write-Host " CSV Export:           $csvFile" -ForegroundColor White
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "`n📋 Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Run 3_AdministrativeUnits.ps1:" -ForegroundColor White
Write-Host "     - Creates AU-Student1 through AU-Student30" -ForegroundColor Gray
Write-Host "     - Assigns Groups Administrator role scoped to each AU" -ForegroundColor Gray
Write-Host "  2. Run 4_IntuneCustomRole.ps1:" -ForegroundColor White
Write-Host "     - Creates custom 'Lab Intune Admin' role" -ForegroundColor Gray
Write-Host "     - Creates scoped role assignments with scope tags" -ForegroundColor Gray
Write-Host "     - Links admin groups to user/device groups" -ForegroundColor Gray
Write-Host "  3. Assign scope tags to Cloud PC provisioning policies:" -ForegroundColor White
Write-Host "     - Go to Intune portal > Devices > Windows 365 > Provisioning policies" -ForegroundColor Gray
Write-Host "     - Edit each student-specific policy" -ForegroundColor Gray
Write-Host "     - Add the corresponding scope tag (ST1 for W365Student1, etc.)" -ForegroundColor Gray
Write-Host "`n📝 Admin-to-Student Mapping (via Scope Tags):" -ForegroundColor Cyan
Write-Host "     ST1:  admin1@ manages W365Student1@" -ForegroundColor Gray
Write-Host "     ST2:  admin2@ manages W365Student2@" -ForegroundColor Gray
Write-Host "     ST3:  admin3@ manages W365Student3@" -ForegroundColor Gray
Write-Host "     ...   ..." -ForegroundColor Gray
Write-Host "     ST$StudentCount`:  admin$StudentCount@ manages W365Student$StudentCount@" -ForegroundColor Gray

Write-Host "`n📄 Files created in Documents folder:" -ForegroundColor Cyan
Write-Host "  Log: $logFile" -ForegroundColor Gray
Write-Host "  CSV: $csvFile" -ForegroundColor Gray

Write-Host "`n✓ Scope tag configuration complete!" -ForegroundColor Green
Write-LogMessage "Script execution completed successfully." -Level Success
