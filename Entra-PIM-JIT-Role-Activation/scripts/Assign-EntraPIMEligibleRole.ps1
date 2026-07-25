<#
.SYNOPSIS
Creates a time-limited Microsoft Entra PIM eligible role assignment.

.EXAMPLE
./Assign-EntraPIMEligibleRole.ps1 `
  -UserObjectId "00000000-0000-0000-0000-000000000000" `
  -RoleName "Helpdesk Administrator" `
  -DurationDays 30
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$UserObjectId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RoleName = "Helpdesk Administrator",

    [Parameter()]
    [ValidateRange(1, 365)]
    [int]$DurationDays = 30,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Justification = "Temporary eligible role assignment for IAM/PIM lab"
)

$ErrorActionPreference = "Stop"
$TenantId = "55c6fb01-af94-45ba-8b1b-44fc400a6a47"

Write-Host "`nMicrosoft Entra PIM Eligible Role Assignment" -ForegroundColor Cyan
Write-Host "Tenant: $TenantId"

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "`nInstalling Microsoft.Graph.Authentication..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
}

Import-Module Microsoft.Graph.Authentication

Write-Host "`nConnecting to Microsoft Graph..." -ForegroundColor Yellow
Connect-MgGraph `
    -TenantId $TenantId `
    -Scopes "RoleManagement.ReadWrite.Directory","Directory.Read.All" `
    -NoWelcome

$context = Get-MgContext
if (-not $context -or $context.TenantId -ne $TenantId) {
    throw "The Microsoft Graph connection is not using the expected tenant."
}

# Confirm that the supplied object ID belongs to a real user.
$userUri = "https://graph.microsoft.com/v1.0/users/$UserObjectId?`$select=id,displayName,userPrincipalName"
$user = Invoke-MgGraphRequest -Method GET -Uri $userUri

# Locate the exact Entra directory-role definition.
$escapedRoleName = $RoleName.Replace("'", "''")
$roleFilter = [uri]::EscapeDataString("displayName eq '$escapedRoleName'")
$roleUri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=$roleFilter&`$select=id,displayName"
$roleResponse = Invoke-MgGraphRequest -Method GET -Uri $roleUri

if ($roleResponse.value.Count -eq 0) {
    throw "No Microsoft Entra role named '$RoleName' was found."
}

if ($roleResponse.value.Count -gt 1) {
    throw "More than one role named '$RoleName' was found. No assignment was made."
}

$role = $roleResponse.value[0]

# Stop if the same user already has this eligible role at tenant scope.
$eligibilityFilter = [uri]::EscapeDataString(
    "principalId eq '$UserObjectId' and roleDefinitionId eq '$($role.id)' and directoryScopeId eq '/'"
)
$existingUri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances?`$filter=$eligibilityFilter"
$existing = Invoke-MgGraphRequest -Method GET -Uri $existingUri

if ($existing.value.Count -gt 0) {
    Write-Host "`nNo change was made." -ForegroundColor Yellow
    Write-Host "$($user.displayName) is already eligible for $($role.displayName)."
    Disconnect-MgGraph | Out-Null
    exit 0
}

$startTime = (Get-Date).ToUniversalTime()
$endTime = $startTime.AddDays($DurationDays)

Write-Host "`nAssignment summary" -ForegroundColor Cyan
Write-Host "User:          $($user.displayName)"
Write-Host "Email:         $($user.userPrincipalName)"
Write-Host "Role:          $($role.displayName)"
Write-Host "Access type:   Eligible (activation required)"
Write-Host "Scope:         Entire tenant"
Write-Host "Starts (UTC):  $($startTime.ToString('u'))"
Write-Host "Expires (UTC): $($endTime.ToString('u'))"

$confirmation = Read-Host "`nType ASSIGN to submit this PIM request"
if ($confirmation -cne "ASSIGN") {
    Write-Host "Cancelled. No assignment was made." -ForegroundColor Yellow
    Disconnect-MgGraph | Out-Null
    exit 0
}

$body = @{
    action           = "adminAssign"
    principalId      = $UserObjectId
    roleDefinitionId = $role.id
    directoryScopeId = "/"
    justification    = $Justification
    scheduleInfo     = @{
        startDateTime = $startTime.ToString("o")
        expiration    = @{
            type        = "afterDateTime"
            endDateTime = $endTime.ToString("o")
        }
    }
} | ConvertTo-Json -Depth 5

$requestUri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleRequests"
$result = Invoke-MgGraphRequest `
    -Method POST `
    -Uri $requestUri `
    -Body $body `
    -ContentType "application/json"

Write-Host "`nPIM request submitted successfully." -ForegroundColor Green
Write-Host "Request ID: $($result.id)"
Write-Host "Status:     $($result.status)"
Write-Host "`nVerify it in: Entra admin center > ID Governance > Privileged Identity Management > Microsoft Entra roles > Assignments > Eligible assignments"

Disconnect-MgGraph | Out-Null
