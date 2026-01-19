# **W365 Student Deployment Script Specification**

## **1\. Overview and Goal**

The primary goal of this PowerShell script, tentatively named New-W365ClassStudents.ps1, is to automate the creation of a specified number of student user accounts in a Microsoft 365 tenant and assign them to a target security group (W365 Class). Group membership automatically triggers license assignment via group-based licensing and Windows 365 provisioning via the group's assigned provisioning profile. The script maintains robust logging and generates a structured credential file for easy distribution.

## **1.1 Tenant Bootstrap (Prerequisite)**

**Before running student deployment scripts**, operators must first bootstrap the tenant with the standardized administrator account and Azure RBAC permissions.

Run the **SubscriptionConfigure** script to:
- Create the `bhgadminXX@bhgclassXX.xyz` administrator account
- Assign Intune Administrator directory role
- Configure Azure RBAC for Custom Image and W365 deployments
- Register required resource providers

```powershell
cd SubscriptionConfigure
.\SubscriptionConfigure.ps1
```

See [SubscriptionConfigure/README.md](../SubscriptionConfigure/README.md) for detailed usage instructions.

Once the administrator account is provisioned and permissions are configured, sign in as `bhgadminXX@bhgclassXX.xyz` to proceed with infrastructure and student deployments.

## **2\. Prerequisites and Environment**

| Requirement | Details |
| :---- | :---- |
| **Execution Environment** | **PowerShell 7** (Mandatory) or newer. |
| **Required Modules** | **Microsoft.Graph** (for user/group/license management). The script must ensure these modules are installed and imported. |
| **Permissions** | Global Administrator or User Administrator role in Azure AD/Microsoft 365 to create users, assign licenses, and manage group membership. |
| **Connectivity** | Active internet connection to connect to Microsoft Graph services. |
| **Licensing** | The administrator has configured group-based licensing on the W365 Class group with the appropriate licenses (Entra ID P1, Intune P1, and W365 license). The script does NOT assign licenses directly - this is handled automatically when users are added to the group. |
| **Provisioning Profile** | The correct provisioning profile is assigned to the W365 Class group, which controls the deployment location and Cloud PC configuration. |
| **User Settings** | The correct user settings are assigned to the W365 Class group. |

## **3\. Configuration & User Input**

The script must prompt the administrator for the following information:

| Input | Description | Validation/Constraint |
| :---- | :---- | :---- |
| **Number of Accounts ($AccountCount)** | The total number of student accounts to create. | Must be a positive integer **between 1 and 40** (inclusive). |
| **W365 Class Group ID ($GroupId)** | The Azure AD Object ID of the existing security group (e.g., "W365 Class") where the new users will be assigned. Group membership automatically triggers license assignment and W365 provisioning based on the group's configured policies. | Must be a valid GUID string. |

## **4\. Core Functionality and Logic**

### **4.1. Logging Setup**

1. The script must immediately define the log file path.  
   * **Location:** The user's Documents folder (e.g., $env:USERPROFILE\\Documents).  
   * **Naming Convention:** W365ClassDeploy-YYYY-MM-DD-HH-MM.log (e.g., W365ClassDeploy-2025-10-13-14-36.log).  
2. All actions, including module loading, connection status, inputs, validation results, account creations, license assignments, and group assignments, **MUST** be written to this log file.

### **4.2. Connection and Authentication**

1. Connect to the Microsoft Graph service using **delegated permissions** or the appropriate application permissions.  
2. Log the connection success or failure.

### **4.3. Input Validation**

1. Validate that the $AccountCount is a number greater than 0 and less than or equal to 40\. If invalid, prompt the user again or terminate gracefully.  
2. Validate that the $GroupId is provided and is a valid GUID format.  
3. Verify that the group exists and is accessible.

### **4.4. Group-Based Licensing**

1. The script does NOT perform license availability checks or direct license assignment.  
2. Licenses are automatically assigned when users are added to the W365 Class group via group-based licensing.  
3. The administrator is responsible for ensuring the group has sufficient licenses configured before running the script.  
4. Log a reminder that group-based licensing will handle license assignment automatically.

### **4.5. User Provisioning and Naming**

1. The script will initialize an array or list to hold the credentials of the newly created users.  
2. Iterate from 1 up to $AccountCount.  
3. For each iteration, construct the User Principal Name (UPN) and Display Name.  
   * **Display Name:** Student XX  
   * **User Principal Name:** StudentXX@\<TenantDomain\>  
   * **Zero Padding:** The number (XX) **MUST** be zero-padded to two digits (e.g., 01, 09, 10).  
4. Generate a strong, random initial password for each user.  
5. Create the user account using the Graph API, ensuring **$AccountEnabled is true** and PasswordProfile.ForceChangePasswordNextSignIn is set to $true.  
6. **Do NOT assign licenses directly** - this is handled automatically by group membership.  
7. Add the newly created user to the W365 Class group (see section 4.7).  
8. Log the creation of each user, including their UPN and initial password (with a strong warning about immediately securing the passwords).  
9. **Credential Output:** After all users are created, the script **MUST** export the array of user UPNs and initial passwords to an XML file.

### **4.6. Credential XML Output**

1. **Location:** The user's Documents folder (e.g., $env:USERPROFILE\\Documents).  
2. **Naming Convention:** W365ClassCredentials-YYYY-MM-DD-HH-MM.xml.  
3. **Content:** The XML file must contain a root element (W365ClassCredentials) and a list of user elements (User), each with the UPN and TemporaryPassword.  
4. **Logging:** Log the successful creation and path of the XML file.

### **4.7. Group Membership**

1. After successful user creation, add the new user's Object ID to the group specified by $GroupId.  
2. Group membership automatically triggers:  
   * License assignment (via group-based licensing)  
   * Windows 365 provisioning (via provisioning profile assigned to the group)  
   * User settings application  
3. Log the group assignment status for each user.  
4. Log a note that provisioning may take several minutes after group membership is assigned.

## **5\. Logging Specification**

The log file content must follow this format:

| Log Entry Type | Format Example |
| :---- | :---- |
| **Timestamp** | \[YYYY-MM-DD HH:MM:SS\] |
| **INFO** | \[INFO\] Connecting to Microsoft Graph... |
| **USER INPUT** | \[INPUT\] Administrator requested 15 accounts. |
| **SUCCESS** | \[SUCCESS\] User Student05 created and licensed successfully. |
| **WARNING** | \[WARNING\] Only 12 licenses available for ENTERPRISEPACK. Needed 15\. |
| **ERROR** | \[ERROR\] Failed to add user Student11 to group: Resource not found. |

## **6\. Error Handling**

* The script must use try/catch/finally blocks around critical operations (Graph connection, user creation, licensing, group assignment, XML output).  
* Any error encountered must be logged with the \[ERROR\] prefix, including the specific exception message.  
* The script should continue to the next user upon a non-fatal error (e.g., group assignment failure for one user) but should terminate on fatal errors (e.g., license shortage or connection failure).

## **7\. Next Steps**

Before deployment, the administrator needs to confirm:

* The **Group ID** (GUID) of the "W365 Class" group.  
* The W365 Class group has **group-based licensing** configured with the required licenses (Entra ID P1, Intune P1, Windows 365).  
* The W365 Class group has a **provisioning profile** assigned that defines the deployment location and Cloud PC configuration.  
* The W365 Class group has the appropriate **user settings** assigned.  
* The script will automatically retrieve the tenant domain from the connected Microsoft 365 tenant.  
* The XML file (W365ClassCredentials-YYYY-MM-DD-HH-MM.xml) containing temporary passwords will be generated in the **Documents** folder.