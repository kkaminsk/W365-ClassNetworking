<#
.SYNOPSIS
    Creates a snapshot of a selected Windows 365 Cloud PC.

.DESCRIPTION
    This script authenticates to Microsoft Graph and allows administrators to
    interactively select a Cloud PC from their tenant to create a snapshot.
    Snapshots provide point-in-time backups for disaster recovery or before
    making configuration changes.
    
    The script:
    - Authenticates to Microsoft Graph with CloudPC.ReadWrite.All permission
    - Lists all Cloud PCs in the tenant
    - Prompts for interactive selection
    - Creates a snapshot via the Graph API
    - Provides detailed logging and error handling

.EXAMPLE
    .\Set-CloudPCSnapshot.ps1
    
    Runs the script interactively, prompting for Cloud PC selection and creating a snapshot.

.NOTES
    File Name      : Set-CloudPCSnapshot.ps1
    Prerequisite   : PowerShell 7+, Microsoft.Graph module
    Required Roles : Intune Administrator or Global Administrator
    Required Perms : CloudPC.ReadWrite.All (Microsoft Graph)
    Author         : Auto-generated from OpenSpec proposal
    Date           : 2025-10-17
#>

#Requires -Version 7.0

# ============================================================================
# SECTION 1: ERROR HANDLING CONFIGURATION
# ============================================================================

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ============================================================================
# SECTION 2: LOGGING SETUP
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
    if ($script:LogFilePath) {
        Add-Content -Path $script:LogFilePath -Value $logEntry
    }
}

# Initialize log file
$logFileName = "CloudPCSnapshot-$(Get-Date -Format 'yyyy-MM-dd-HH-mm').log"
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
# SECTION 3: MODULE VERIFICATION AND IMPORT
# ============================================================================

Write-Log -Message "Verifying PowerShell version..." -Level INFO
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Log -Message "PowerShell 7 or newer is required. Current version: $($PSVersionTable.PSVersion)" -Level ERROR
    exit 1
}
Write-Log -Message "PowerShell version $($PSVersionTable.PSVersion) confirmed." -Level SUCCESS

Write-Log -Message "Checking for Microsoft.Graph modules..." -Level INFO

# Check for required modules
$requiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.DeviceManagement'
)

$missingModules = @()
foreach ($moduleName in $requiredModules) {
    $module = Get-Module -ListAvailable -Name $moduleName
    if (-not $module) {
        $missingModules += $moduleName
    }
}

# Install missing modules
if ($missingModules.Count -gt 0) {
    Write-Log -Message "Missing modules: $($missingModules -join ', '). Installing..." -Level WARNING
    try {
        foreach ($moduleName in $missingModules) {
            Write-Log -Message "Installing $moduleName..." -Level INFO
            Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
        }
        Write-Log -Message "All required modules installed successfully." -Level SUCCESS
    }
    catch {
        Write-Log -Message "Failed to install required modules: $($_.Exception.Message)" -Level ERROR
        exit 1
    }
}

# Import modules
Write-Log -Message "Importing Microsoft.Graph modules..." -Level INFO
try {
    foreach ($moduleName in $requiredModules) {
        # Check if module is already loaded
        $loadedModule = Get-Module -Name $moduleName
        if (-not $loadedModule) {
            Import-Module $moduleName -Force -ErrorAction Stop
            Write-Log -Message "Imported $moduleName" -Level INFO
        }
        else {
            Write-Log -Message "$moduleName already loaded (version $($loadedModule.Version))" -Level INFO
        }
    }
    Write-Log -Message "All required modules are available." -Level SUCCESS
}
catch {
    # If import fails due to version conflict, try to continue if cmdlets are available
    Write-Log -Message "Module import warning: $($_.Exception.Message)" -Level WARNING
    Write-Log -Message "Attempting to continue with loaded modules..." -Level INFO
    
    # Verify critical cmdlets are available
    $criticalCmdlets = @('Connect-MgGraph', 'Invoke-MgGraphRequest', 'Get-MgContext')
    $missingCmdlets = @()
    foreach ($cmdlet in $criticalCmdlets) {
        if (-not (Get-Command $cmdlet -ErrorAction SilentlyContinue)) {
            $missingCmdlets += $cmdlet
        }
    }
    
    if ($missingCmdlets.Count -gt 0) {
        Write-Log -Message "Critical cmdlets not available: $($missingCmdlets -join ', ')" -Level ERROR
        Write-Log -Message "Please close PowerShell and start a fresh session, then run this script again." -Level ERROR
        exit 1
    }
    
    Write-Log -Message "Required cmdlets are available. Continuing..." -Level SUCCESS
}

# ============================================================================
# SECTION 4: GRAPH AUTHENTICATION
# ============================================================================

Write-Log -Message "Connecting to Microsoft Graph..." -Level INFO
try {
    # Connect with required scope
    $null = Connect-MgGraph -Scopes "CloudPC.ReadWrite.All" -NoWelcome -ErrorAction Stop
    
    # Get context to verify connection
    $context = Get-MgContext
    if ($null -eq $context) {
        Write-Log -Message "Failed to establish Graph connection." -Level ERROR
        exit 1
    }
    
    Write-Log -Message "Connected to Microsoft Graph successfully." -Level SUCCESS
    Write-Log -Message "Tenant: $($context.TenantId)" -Level INFO
    Write-Log -Message "Account: $($context.Account)" -Level INFO
    Write-Log -Message "Scopes: $($context.Scopes -join ', ')" -Level INFO
}
catch {
    Write-Log -Message "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -Level ERROR
    Write-Log -Message "Please ensure you have the CloudPC.ReadWrite.All permission." -Level ERROR
    exit 1
}

# ============================================================================
# SECTION 5: RETRIEVE CLOUD PCs
# ============================================================================

Write-Log -Message "Retrieving Cloud PCs from tenant..." -Level INFO
try {
    # Use beta endpoint to get additional properties like status
    $uri = "https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/cloudPCs"
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    
    $cloudPCs = @()
    if ($response.value) {
        $cloudPCs += $response.value
    }
    
    # Handle pagination if needed
    while ($response.PSObject.Properties.Name -contains '@odata.nextLink') {
        Write-Log -Message "Retrieving next page of Cloud PCs..." -Level INFO
        $response = Invoke-MgGraphRequest -Method GET -Uri $response.'@odata.nextLink' -ErrorAction Stop
        if ($response.value) {
            $cloudPCs += $response.value
        }
    }
    
    if ($cloudPCs.Count -eq 0) {
        Write-Log -Message "No Cloud PCs found in tenant." -Level INFO
        Write-Host "`nNo Cloud PCs found in this tenant." -ForegroundColor Yellow
        Write-Log -Message "Script completed. Log file: $script:LogFilePath" -Level INFO
        exit 0
    }
    
    Write-Log -Message "Retrieved $($cloudPCs.Count) Cloud PC(s)." -Level SUCCESS
}
catch {
    Write-Log -Message "Failed to retrieve Cloud PCs: $($_.Exception.Message)" -Level ERROR
    if ($_.Exception.Message -match "403|Forbidden") {
        Write-Log -Message "Permission denied. Ensure you have CloudPC.ReadWrite.All or CloudPC.Read.All permission." -Level ERROR
    }
    exit 1
}

# ============================================================================
# SECTION 6: DISPLAY CLOUD PCs AND PROMPT FOR SELECTION
# ============================================================================

# Sort Cloud PCs by display name (if property exists)
if ($cloudPCs[0].PSObject.Properties['displayName']) {
    $cloudPCs = $cloudPCs | Sort-Object -Property displayName
}
elseif ($cloudPCs[0].PSObject.Properties['managedDeviceName']) {
    $cloudPCs = $cloudPCs | Sort-Object -Property managedDeviceName
}
elseif ($cloudPCs[0].PSObject.Properties['id']) {
    $cloudPCs = $cloudPCs | Sort-Object -Property id
}

# Helper function to safely get property from hashtable or object
function Get-SafeProperty {
    param($obj, [string[]]$propertyNames, $default = "N/A")
    
    foreach ($propName in $propertyNames) {
        if ($obj -is [hashtable] -or $obj -is [System.Collections.IDictionary]) {
            if ($obj.ContainsKey($propName) -and $obj[$propName]) {
                return $obj[$propName]
            }
        }
        elseif ($obj.PSObject.Properties[$propName] -and $obj.$propName) {
            return $obj.$propName
        }
    }
    return $default
}

# Display Cloud PCs
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Available Cloud PCs" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

for ($i = 0; $i -lt $cloudPCs.Count; $i++) {
    $pc = $cloudPCs[$i]
    
    # Get device name (managedDeviceName is the computer name)
    $deviceName = Get-SafeProperty $pc @('managedDeviceName', 'deviceName', 'computerName') "N/A"
    
    # Get display name (friendly name from provisioning policy)
    $displayName = Get-SafeProperty $pc @('displayName') ""
    
    # Get user
    $userPrincipalName = Get-SafeProperty $pc @('userPrincipalName', 'user') "Unassigned"
    
    # Get status (beta endpoint should have this)
    $status = Get-SafeProperty $pc @('status', 'statusDetails', 'provisioningState', 'state') ""
    
    # Display device name
    Write-Host "[$($i + 1)] $deviceName" -ForegroundColor White
    
    # Show display name if different from device name
    if ($displayName -and $displayName -ne $deviceName) {
        Write-Host "    Display Name: $displayName" -ForegroundColor Gray
    }
    
    # Build info line
    $infoLine = "    User: $userPrincipalName"
    if ($status) {
        $infoLine += " | Status: $status"
    }
    Write-Host $infoLine -ForegroundColor Gray
}

Write-Host "========================================`n" -ForegroundColor Cyan

# Prompt for selection
$maxRetries = 3
$retryCount = 0
$selectedPC = $null

while ($retryCount -lt $maxRetries -and $null -eq $selectedPC) {
    Write-Log -Message "Prompting user for Cloud PC selection..." -Level INPUT
    $selection = Read-Host "Enter the number of the Cloud PC to snapshot (or Q to quit)"
    
    # Handle quit
    if ($selection -eq 'Q' -or $selection -eq 'q' -or $selection -eq '0') {
        Write-Log -Message "Operation cancelled by user." -Level INFO
        Write-Host "`nOperation cancelled." -ForegroundColor Yellow
        exit 0
    }
    
    # Validate numeric input
    $selectionNum = 0
    if ([int]::TryParse($selection, [ref]$selectionNum)) {
        if ($selectionNum -ge 1 -and $selectionNum -le $cloudPCs.Count) {
            $selectedPC = $cloudPCs[$selectionNum - 1]
            Write-Log -Message "User selected Cloud PC #${selectionNum}: $($selectedPC.displayName) (ID: $($selectedPC.id))" -Level INFO
        }
        else {
            Write-Host "Invalid selection. Please enter a number between 1 and $($cloudPCs.Count)." -ForegroundColor Red
            $retryCount++
        }
    }
    else {
        Write-Host "Invalid input. Please enter a number." -ForegroundColor Red
        $retryCount++
    }
}

# Check if selection was successful
if ($null -eq $selectedPC) {
    Write-Log -Message "Maximum retry attempts reached. Exiting." -Level ERROR
    Write-Host "`nMaximum retry attempts reached. Exiting." -ForegroundColor Red
    exit 1
}

# Display selection confirmation
$deviceName = Get-SafeProperty $selectedPC @('managedDeviceName', 'deviceName', 'displayName', 'computerName') "N/A"
$userPrincipalName = Get-SafeProperty $selectedPC @('userPrincipalName', 'user') "Unassigned"

Write-Host "`nSelected: $deviceName (User: $userPrincipalName)" -ForegroundColor Green
Write-Log -Message "Confirmed selection: $deviceName" -Level SUCCESS

# ============================================================================
# SECTION 7: CREATE SNAPSHOT
# ============================================================================

Write-Log -Message "Creating snapshot for Cloud PC: $deviceName (ID: $($selectedPC.id))" -Level INFO
Write-Host "`nCreating snapshot..." -ForegroundColor Cyan

try {
    # Call the createSnapshot API endpoint (using beta to match retrieval endpoint)
    $uri = "https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/cloudPCs/$($selectedPC.id)/createSnapshot"
    $response = Invoke-MgGraphRequest -Method POST -Uri $uri -ErrorAction Stop
    
    # Success - API returns 204 No Content
    Write-Log -Message "Snapshot created successfully for $deviceName" -Level SUCCESS
    Write-Host "`nSUCCESS: Snapshot created for $deviceName" -ForegroundColor Green
    Write-Host "The snapshot operation has been initiated. It may take several minutes to complete." -ForegroundColor White
}
catch {
    $errorMessage = $_.Exception.Message
    Write-Log -Message "Failed to create snapshot: $errorMessage" -Level ERROR
    
    # Parse specific error codes
    if ($errorMessage -match "409|Conflict") {
        Write-Host "`nERROR: A snapshot is already in progress for this Cloud PC." -ForegroundColor Red
        Write-Host "Please wait for the current snapshot to complete before creating a new one." -ForegroundColor Yellow
        Write-Log -Message "Snapshot conflict: operation already in progress." -Level ERROR
    }
    elseif ($errorMessage -match "403|Forbidden") {
        Write-Host "`nERROR: Insufficient permissions." -ForegroundColor Red
        Write-Host "Required permission: CloudPC.ReadWrite.All" -ForegroundColor Yellow
        Write-Host "Please contact your administrator to grant this permission." -ForegroundColor Yellow
        Write-Log -Message "Permission denied: CloudPC.ReadWrite.All required." -Level ERROR
    }
    elseif ($errorMessage -match "404|Not Found") {
        Write-Host "`nERROR: Cloud PC not found." -ForegroundColor Red
        Write-Host "The Cloud PC may have been deleted or is no longer available." -ForegroundColor Yellow
        Write-Log -Message "Cloud PC not found (404): $($selectedPC.id)" -Level ERROR
    }
    else {
        Write-Host "`nERROR: Failed to create snapshot." -ForegroundColor Red
        Write-Host "Error: $errorMessage" -ForegroundColor Yellow
        Write-Log -Message "Snapshot creation failed with error: $errorMessage" -Level ERROR
    }
    
    exit 1
}

# ============================================================================
# SECTION 8: COMPLETION
# ============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Snapshot Operation Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Cloud PC: $deviceName" -ForegroundColor White
Write-Host "User: $userPrincipalName" -ForegroundColor White
Write-Host "Log file: $script:LogFilePath" -ForegroundColor Gray
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Log -Message "Script completed successfully." -Level SUCCESS
Write-Log -Message "Log file location: $script:LogFilePath" -Level INFO

exit 0
