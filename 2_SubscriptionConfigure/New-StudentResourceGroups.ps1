<#
.SYNOPSIS
    Creates Azure resource groups for Windows 365 lab students.

.DESCRIPTION
    This script provisions resource groups for individual students or batch-creates resource groups 
    for multiple students in a single-subscription multi-student lab environment. Each student receives 
    two resource groups: one for custom image resources and one for Windows 365 spoke network resources.

    Resource Group Naming:
    - Custom Image RG: rg-st{N}-customimage (e.g., rg-st1-customimage)
    - Spoke Network RG: rg-st{N}-spoke (e.g., rg-st1-spoke)

    All resource groups are tagged with:
    - Student: ST{N}
    - Purpose: Lab
    - Environment: Prod

.PARAMETER StudentNumber
    The student number (1-30) for which to create resource groups. Required unless -CreateAllStudents is specified.

.PARAMETER TotalStudents
    Total number of students for batch provisioning. Default is 30. Only used with -CreateAllStudents switch.

.PARAMETER CreateAllStudents
    Switch to create resource groups for all students (1 through TotalStudents) in batch mode.

.PARAMETER Location
    Azure region for resource group creation. Default is "southcentralus".

.EXAMPLE
    .\New-StudentResourceGroups.ps1 -StudentNumber 5
    Creates resource groups for Student 5: rg-st5-customimage and rg-st5-spoke

.EXAMPLE
    .\New-StudentResourceGroups.ps1 -CreateAllStudents -TotalStudents 30
    Creates resource groups for all 30 students (60 resource groups total)

.EXAMPLE
    .\New-StudentResourceGroups.ps1 -StudentNumber 10 -Location "eastus"
    Creates resource groups for Student 10 in East US region

.NOTES
    File Name: New-StudentResourceGroups.ps1
    Author: OpenSpec Automation
    Requires: PowerShell 7.0+, Az.Resources module
    Prerequisites:
    - Azure subscription context must be set
    - User must have permissions to create resource groups
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 30)]
    [int]$StudentNumber,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 30)]
    [int]$TotalStudents = 30,

    [Parameter(Mandatory = $false)]
    [switch]$CreateAllStudents,

    [Parameter(Mandatory = $false)]
    [string]$Location = "southcentralus"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Initialize log file in Documents folder
$documentsFolder = [Environment]::GetFolderPath('MyDocuments')
$timestamp = Get-Date -Format "yyyy-MM-dd-HH-mm"
$logFile = Join-Path $documentsFolder "New-StudentResourceGroups-$timestamp.log"

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
    $logEntry | Out-File -FilePath $logFile -Append -Encoding UTF8
}

function New-StudentResourceGroup {
    param(
        [Parameter(Mandatory = $true)]
        [int]$StudentNum,
        
        [Parameter(Mandatory = $true)]
        [string]$Purpose,
        
        [Parameter(Mandatory = $true)]
        [string]$Region
    )
    
    $rgName = "rg-st$StudentNum-$Purpose"
    $tags = @{
        "Student"     = "ST$StudentNum"
        "Purpose"     = "Lab"
        "Environment" = "Prod"
    }
    
    try {
        # Check if resource group already exists
        $existingRg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
        
        if ($existingRg) {
            Write-LogMessage "  Resource group '$rgName' already exists - skipping" -Level Info
            return $true
        }
        
        # Create resource group
        $null = New-AzResourceGroup -Name $rgName -Location $Region -Tag $tags -ErrorAction Stop
        Write-LogMessage "  ✓ Created resource group: $rgName" -Level Success
        return $true
    }
    catch {
        Write-LogMessage "  ✗ Failed to create resource group '$rgName': $($_.Exception.Message)" -Level Error
        return $false
    }
}

# ============================================================================
# Main Script
# ============================================================================

Write-Host "`n===========================================" -ForegroundColor Cyan
Write-Host " Student Resource Group Provisioning" -ForegroundColor Cyan
Write-Host "===========================================" -ForegroundColor Cyan
Write-LogMessage "Log file: $logFile" -Level Info

# Validate parameters
if (-not $CreateAllStudents -and -not $StudentNumber) {
    Write-LogMessage "ERROR: Either -StudentNumber or -CreateAllStudents must be specified" -Level Error
    Write-Host "`nUsage:" -ForegroundColor Yellow
    Write-Host "  Single student: .\New-StudentResourceGroups.ps1 -StudentNumber 5" -ForegroundColor White
    Write-Host "  All students:   .\New-StudentResourceGroups.ps1 -CreateAllStudents -TotalStudents 30" -ForegroundColor White
    exit 1
}

# Verify Azure context
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context) {
        Write-LogMessage "ERROR: No Azure context found. Please run Connect-AzAccount first." -Level Error
        exit 1
    }
    
    Write-LogMessage "Azure Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -Level Info
    Write-LogMessage "Target Location: $Location" -Level Info
}
catch {
    Write-LogMessage "ERROR: Failed to get Azure context: $($_.Exception.Message)" -Level Error
    exit 1
}

# Determine which students to provision
if ($CreateAllStudents) {
    $students = 1..$TotalStudents
    Write-LogMessage "Batch provisioning for $TotalStudents students (ST1 through ST$TotalStudents)" -Level Info
}
else {
    $students = @($StudentNumber)
    Write-LogMessage "Single-student provisioning for Student $StudentNumber (ST$StudentNumber)" -Level Info
}

# Provision resource groups
$totalRgs = $students.Count * 2  # 2 RGs per student
$currentRg = 0
$successCount = 0
$failureCount = 0

Write-Host "`nProvisioning $totalRgs resource groups..." -ForegroundColor Cyan

foreach ($studentNum in $students) {
    Write-Host "`n  Student $studentNum (ST$studentNum):" -ForegroundColor Yellow
    
    # Create custom image resource group
    $currentRg++
    $percentComplete = [int](($currentRg / $totalRgs) * 100)
    Write-Progress -Activity "Provisioning Resource Groups" -Status "Student $studentNum - Custom Image RG ($currentRg of $totalRgs)" -PercentComplete $percentComplete
    
    if (New-StudentResourceGroup -StudentNum $studentNum -Purpose "customimage" -Region $Location) {
        $successCount++
    }
    else {
        $failureCount++
    }
    
    # Create spoke network resource group
    $currentRg++
    $percentComplete = [int](($currentRg / $totalRgs) * 100)
    Write-Progress -Activity "Provisioning Resource Groups" -Status "Student $studentNum - Spoke RG ($currentRg of $totalRgs)" -PercentComplete $percentComplete
    
    if (New-StudentResourceGroup -StudentNum $studentNum -Purpose "spoke" -Region $Location) {
        $successCount++
    }
    else {
        $failureCount++
    }
}

Write-Progress -Activity "Provisioning Resource Groups" -Completed

# Summary
Write-Host "`n===========================================" -ForegroundColor Cyan
Write-Host " Provisioning Summary" -ForegroundColor Cyan
Write-Host "===========================================" -ForegroundColor Cyan
Write-Host "  Students Processed: $($students.Count)" -ForegroundColor White
Write-Host "  Resource Groups Created/Verified: $successCount" -ForegroundColor Green
if ($failureCount -gt 0) {
    Write-Host "  Failures: $failureCount" -ForegroundColor Red
}
Write-Host "  Log File: $logFile" -ForegroundColor Cyan
Write-Host "===========================================" -ForegroundColor Cyan

if ($failureCount -gt 0) {
    Write-LogMessage "Provisioning completed with $failureCount failure(s)" -Level Warning
    exit 1
}
else {
    Write-LogMessage "Provisioning completed successfully" -Level Success
    exit 0
}
