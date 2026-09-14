<#
.SYNOPSIS
    Sanitized reference Runbook for global new-joiner onboarding.

.DESCRIPTION
    Demonstrates the production decision flow without environment-specific
    identifiers, credentials, webhooks, employee data, or connection IDs.

    Key rules:
      - Country is an eligibility filter.
      - Department is optional except for the Field_Sales job-title rule.
      - Personal email (OtherMails) is required before onboarding.
      - Missing manager information is a warning, not a blocker.
      - Azure Table Storage state prevents duplicate processing and repeated
        missing-email notifications.
      - Slack is required only when a user was processed or a first-time
        missing-email notification must be sent.

    Replace the configuration placeholders and connect the helper functions
    to the target Azure environment before production use.
#>

param(
    [string[]]$Countries = @("BEL","BGR","DEU","DNK","ESP","FRA","GBR","IRL","ITA","LTU","NLD","POL","PRT"),
    [int]$HireDateWindowDays = 2,
    [string]$StorageAccountName = "<storage-account-name>",
    [string]$StorageTableName = "<state-table-name>",
    [bool]$PasswordResetEnabled = $true,
    [bool]$DryRun = $false
)

$AllowedFieldSalesJobTitles = @(
    "Field Sales Territory Manager",
    "Field Sales Area Manager",
    "Field Sales Excellence Lead",
    "Field Sales Regional Sales Manager",
    "Field Sales Trainer"
)

# ---------------------------------------------------------------------
# Production helper functions are intentionally represented as placeholders
# in this public/sanitized reference implementation.
# ---------------------------------------------------------------------
function Get-OnboardingState {
    param([string]$PartitionKey, [string]$RowKey)
    # Replace with Azure Table Storage lookup using managed identity.
    return $null
}

function Set-OnboardingState {
    param(
        [string]$PartitionKey,
        [string]$RowKey,
        [hashtable]$Properties
    )
    # Replace with Azure Table Storage upsert using managed identity.
    return @{ ok = $true }
}

function New-RandomPassword {
    param([int]$Length = 10)

    $lower   = 'abcdefghijkmnopqrstuvwxyz'
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $numbers = '23456789'
    $special = '@#$%&!?'
    $all     = ($lower + $upper + $numbers + $special).ToCharArray()

    do {
        $chars = @()
        $chars += ($lower.ToCharArray()   | Get-Random -Count 1)
        $chars += ($upper.ToCharArray()   | Get-Random -Count 1)
        $chars += ($numbers.ToCharArray() | Get-Random -Count 1)
        $chars += ($special.ToCharArray() | Get-Random -Count 1)

        $remaining = $Length - $chars.Count
        if ($remaining -gt 0) {
            $chars += ($all | Get-Random -Count $remaining)
        }

        $password = -join ($chars | Sort-Object { Get-Random })
    }
    while (
        $password -notmatch '[A-Z]' -or
        $password -notmatch '[a-z]' -or
        $password -notmatch '\d'    -or
        $password -notmatch '[@#$%&*!?]'
    )

    return $password
}

# ---------------------------------------------------------------------
# Fetch users from Microsoft Graph in the production implementation.
# The example below expects the result to contain the documented properties.
# ---------------------------------------------------------------------
$allUsers = @(
    # Get-MgUser -All -Filter "accountEnabled eq true ..." ...
)

$today     = (Get-Date).ToUniversalTime().Date
$startDate = $today
$endDate   = $today.AddDays($HireDateWindowDays)

$matchedUsers        = [System.Collections.Generic.List[object]]::new()
$skippedUsers        = [System.Collections.Generic.List[object]]::new()
$alreadyProcessed    = [System.Collections.Generic.List[object]]::new()
$storageWriteFailure = [System.Collections.Generic.List[object]]::new()

foreach ($user in $allUsers) {

    # Country remains a hard eligibility filter.
    if ($user.Country -notin $Countries) { continue }

    # Field_Sales is the only department-specific exception.
    if ($user.Department -eq "Field_Sales") {
        if (-not $user.JobTitle -or
            $AllowedFieldSalesJobTitles -inotcontains $user.JobTitle.Trim()) {
            continue
        }
    }

    # Hire date must exist and be inside the onboarding window.
    if (-not $user.EmployeeHireDate) { continue }

    $hireDate    = ([datetime]$user.EmployeeHireDate).ToUniversalTime().Date
    $hireDateStr = $hireDate.ToString("yyyy-MM-dd")

    if ($hireDate -lt $startDate -or $hireDate -gt $endDate) { continue }

    $createdDateStr = if ($user.CreatedDateTime) {
        ([datetime]$user.CreatedDateTime).ToString("yyyy-MM-dd")
    } else { "" }

    # -------------------------------------------------------------
    # State check happens BEFORE the personal-email check.
    # This is what prevents repeated IT/Slack alerts.
    # -------------------------------------------------------------
    $partitionKey = $user.Country
    $rowKey       = $user.Id
    $existingRow  = Get-OnboardingState -PartitionKey $partitionKey -RowKey $rowKey

    $processReason = "NewUser"
    $notifyIT      = $true

    if ($existingRow) {
        $storedHireDate = [string]$existingRow.HireDate
        $storedStatus   = [string]$existingRow.Status

        if ($storedStatus -eq "Success" -and $storedHireDate -eq $hireDateStr) {
            $alreadyProcessed.Add([PSCustomObject]@{
                displayName       = $user.DisplayName
                userPrincipalName = $user.UserPrincipalName
                country           = $user.Country
                department        = $user.Department
                hireDate          = $hireDateStr
                processedDate     = $existingRow.ProcessedDateUtc
                skipReason        = "Already processed - hire date unchanged"
            })
            continue
        }
        elseif ($storedStatus -eq "SkippedNoEmail" -and $storedHireDate -eq $hireDateStr) {
            $processReason = "RetryAfterSkip"
            $notifyIT      = $false
        }
        elseif ($storedHireDate -ne $hireDateStr) {
            $processReason = "HireDateChanged"
        }
        elseif ($storedStatus -eq "Failed") {
            $processReason = "RetryAfterFailure"
        }
    }

    # -------------------------------------------------------------
    # Personal email is the blocking attribute.
    # Department is deliberately NOT checked here.
    # -------------------------------------------------------------
    $otherMail = $null
    if ($user.OtherMails -and $user.OtherMails.Count -gt 0) {
        $otherMail = $user.OtherMails[0]
    }

    if (-not $otherMail) {
        $skippedUsers.Add([PSCustomObject]@{
            displayName       = $user.DisplayName
            userPrincipalName = $user.UserPrincipalName
            country           = $user.Country
            department        = $user.Department
            jobTitle          = $user.JobTitle
            missingFields     = "otherMail"
            warningFields     = ""
            skipReason        = "Missing mandatory attribute"
            createdDate       = $createdDateStr
            hireDate          = $hireDateStr
            notifyIT          = $notifyIT
        })

        Set-OnboardingState -PartitionKey $partitionKey -RowKey $rowKey -Properties @{
            UserPrincipalName   = $user.UserPrincipalName
            HireDate            = $hireDateStr
            Status              = "SkippedNoEmail"
            PasswordResetStatus = "N/A"
            SkipReason          = "NoPersonalEmail"
        } | Out-Null

        continue
    }

    # Manager lookup is optional and should populate warnings rather than
    # block the onboarding operation.
    $managerName  = $null
    $managerEmail = $null
    $warnings     = @()

    # Replace with Get-MgUserManager in production.
    if (-not $managerName)  { $warnings += "managerName" }
    if (-not $managerEmail) { $warnings += "managerEmail" }

    # Password reset / onboarding work happens here in production.
    $passwordResetStatus = if ($DryRun) {
        "DryRun-NotReset"
    } elseif (-not $PasswordResetEnabled) {
        "Disabled-NotReset"
    } else {
        "Success"
    }

    $storageResult = Set-OnboardingState -PartitionKey $partitionKey -RowKey $rowKey -Properties @{
        UserPrincipalName   = $user.UserPrincipalName
        HireDate            = $hireDateStr
        Status              = "Success"
        PasswordResetStatus = $passwordResetStatus
        SkipReason          = ""
    }

    if (-not $DryRun -and -not $storageResult.ok) {
        $storageWriteFailure.Add([PSCustomObject]@{
            displayName       = $user.DisplayName
            userPrincipalName = $user.UserPrincipalName
            country           = $user.Country
            department        = $user.Department
            hireDate          = $hireDateStr
            skipReason        = "State write failed"
        })
        continue
    }

    $matchedUsers.Add([PSCustomObject]@{
        displayName         = $user.DisplayName
        userPrincipalName   = $user.UserPrincipalName
        country             = $user.Country
        department          = $user.Department
        jobTitle            = $user.JobTitle
        otherMail           = $otherMail
        managerName         = $managerName
        managerEmail        = $managerEmail
        createdDate         = $createdDateStr
        hireDate            = $hireDateStr
        processReason       = $processReason
        passwordResetStatus = $passwordResetStatus
        warnings            = ($warnings -join ", ")
    })
}

# Only first-time notification-worthy skips go to the IT/Slack report.
$usersToNotify = @(
    $skippedUsers | Where-Object { $_.notifyIT -eq $true }
)

# This diagnostic is precise. Do not test $_.otherMail on skipped records,
# because skipped records do not need to contain an otherMail property.
$missingOtherMail = @(
    $skippedUsers | Where-Object { $_.missingFields -eq "otherMail" }
)

# -------------------------------------------------------------
# IMPORTANT: zero processed + zero new notifications = no Slack.
# -------------------------------------------------------------
$slackMessageRequired = (
    $matchedUsers.Count -gt 0 -or
    $usersToNotify.Count -gt 0
)

$slackDetails = ""

if ($matchedUsers.Count -gt 0) {
    $slackDetails += "`n`nProcessed ($($matchedUsers.Count)):`n"
    foreach ($item in ($matchedUsers | Sort-Object displayName)) {
        $slackDetails += "- $($item.displayName) ($($item.userPrincipalName)) — $($item.country) — Start: $($item.hireDate)`n"
    }
}

if ($usersToNotify.Count -gt 0) {
    $slackDetails += "`n`nAction Required — Missing attributes ($($usersToNotify.Count)):`n"
    foreach ($item in ($usersToNotify | Sort-Object displayName)) {
        $slackDetails += "- $($item.displayName) ($($item.userPrincipalName)) — Missing: $($item.missingFields)`n"
    }
}

$slackMessage = @"
New Joiner Automation Completed

Countries: $($Countries -join ', ')
Hire-date window: $($startDate.ToString('yyyy-MM-dd')) to $($endDate.ToString('yyyy-MM-dd'))
Processed: $($matchedUsers.Count)
Action required (missing attributes): $($usersToNotify.Count)
Already processed (no action): $($alreadyProcessed.Count)
$slackDetails
"@

# Logic App consumes this JSON contract.
[PSCustomObject]@{
    status                   = "success"
    countries                = ($Countries -join ", ")
    hireDateWindowDays       = $HireDateWindowDays
    hireDateWindow            = "$($startDate.ToString('yyyy-MM-dd')) to $($endDate.ToString('yyyy-MM-dd'))"
    matchedUsersCount        = $matchedUsers.Count
    successfulUsersCount     = @($matchedUsers | Where-Object { $_.passwordResetStatus -eq "Success" }).Count
    skippedUsersCount        = $skippedUsers.Count
    skippedNotifyCount       = $usersToNotify.Count
    alreadyProcessedCount    = $alreadyProcessed.Count
    storageWriteFailureCount = $storageWriteFailure.Count
    slackMessageRequired     = $slackMessageRequired
    slackMessage             = $slackMessage
    users                    = @($matchedUsers | Sort-Object displayName)
    skippedUsers             = @($skippedUsers)
    skippedUsersToNotify     = @($usersToNotify)
    alreadyProcessed         = @($alreadyProcessed)
    storageWriteFailures     = @($storageWriteFailure)
    missingOtherMail         = @($missingOtherMail)
} | ConvertTo-Json -Depth 10
