<#[
.SYNOPSIS
    Sanitized New-Joiner Onboarding Runbook.

.DESCRIPTION
    Portfolio-ready implementation based on the production workflow supplied
    for this project. Environment-specific identifiers are replaced with
    configuration placeholders.

    Key rules:
      - Country is a hard eligibility filter.
      - Hire date must exist and be inside the configured window.
      - Department is optional.
      - Field_Sales is processed only for approved job titles.
      - Personal email (OtherMails) is mandatory.
      - Missing manager information is a warning, not a blocker.
      - Azure Table Storage state prevents duplicate processing and repeated
        missing-email notifications.
      - Slack is required only when users were processed or first-time
        notification-worthy skips exist.

.NOTES
    Replace configuration placeholders before use in a real environment.
    Logic App consumes the final JSON contract, including skippedNotifyCount
    and skippedUsersToNotify.
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
    "Head of Field Sales",
    "Field Sales Excellence Lead",
    "Field Sales Regional Sales Manager",
    "Field Sales Trainer"
)

function Normalize-StringArray {
    param([string[]]$Value)
    if ($Value.Count -eq 1 -and $Value[0] -is [string]) {
        if ($Value[0] -match ',') { return ($Value[0] -split '\s*,\s*') | Where-Object { $_.Trim() } }
        if ($Value[0] -match '\s') { return ($Value[0] -split '\s+') | Where-Object { $_.Trim() } }
    }
    return $Value | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function New-RandomPassword {
    param([int]$Length = 10)
    $lower='abcdefghijkmnopqrstuvwxyz'; $upper='ABCDEFGHJKLMNPQRSTUVWXYZ'; $numbers='23456789'; $special='@#$%&!?'
    $all=($lower+$upper+$numbers+$special).ToCharArray()
    do {
        $chars=@()
        $chars += $lower.ToCharArray() | Get-Random -Count 1
        $chars += $upper.ToCharArray() | Get-Random -Count 1
        $chars += $numbers.ToCharArray() | Get-Random -Count 1
        $chars += $special.ToCharArray() | Get-Random -Count 1
        $remaining=$Length-$chars.Count
        if($remaining -gt 0){ $chars += $all | Get-Random -Count $remaining }
        $password=-join($chars | Sort-Object { Get-Random })
    } while($password -notmatch '[A-Z]' -or $password -notmatch '[a-z]' -or $password -notmatch '\d' -or $password -notmatch '[@#$%&*!?]')
    $password
}

function ConvertFrom-SecureToken {
    param([Parameter(Mandatory)]$Token)
    if ($Token -is [System.Security.SecureString]) {
        $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    [string]$Token
}

$script:StorageAvailable=$false

function Initialize-Storage {
    try {
        $token=Get-AzAccessToken -ResourceUrl "https://storage.azure.com"
        $plain=ConvertFrom-SecureToken -Token $token.Token
        if([string]::IsNullOrWhiteSpace($plain)){ throw "Storage access token was empty." }
        $script:StorageAvailable=$true
        Write-Verbose "[Storage] Managed-identity access is available." -Verbose
    } catch {
        $script:StorageAvailable=$false
        Write-Verbose "[Storage] Initialization failed: $($_.Exception.Message)" -Verbose
    }
}

function Get-StorageHeaders {
    param([string]$ContentType="")
    $token=Get-AzAccessToken -ResourceUrl "https://storage.azure.com"
    $plain=ConvertFrom-SecureToken -Token $token.Token
    $headers=@{ Authorization="Bearer $plain"; Accept="application/json;odata=nometadata"; "x-ms-version"="2019-02-02" }
    if($ContentType){$headers["Content-Type"]=$ContentType}
    $headers
}

function Get-TableRow {
    param([string]$StorageAccount,[string]$TableName,[string]$PartitionKey,[string]$RowKey)
    if(-not $script:StorageAvailable){return $null}
    $pk=[Uri]::EscapeDataString($PartitionKey); $rk=[Uri]::EscapeDataString($RowKey)
    $uri="https://$StorageAccount.table.core.windows.net/$TableName(PartitionKey='$pk',RowKey='$rk')"
    try { Invoke-RestMethod -Uri $uri -Method GET -Headers (Get-StorageHeaders) -ErrorAction Stop }
    catch {
        $status=$null; try{$status=[int]$_.Exception.Response.StatusCode}catch{}
        if($status -eq 404){return $null}
        Write-Verbose "[Storage] GET failed for $PartitionKey/$RowKey: $($_.Exception.Message)" -Verbose
        $null
    }
}

function Set-TableRow {
    param([string]$StorageAccount,[string]$TableName,[string]$PartitionKey,[string]$RowKey,[hashtable]$Properties,[bool]$DryRun)
    $pk=[Uri]::EscapeDataString($PartitionKey); $rk=[Uri]::EscapeDataString($RowKey)
    $uri="https://$StorageAccount.table.core.windows.net/$TableName(PartitionKey='$pk',RowKey='$rk')"
    if(-not $script:StorageAvailable){return @{ok=$false;error="Storage not available";body=$null;uri=$uri}}
    if($DryRun){return @{ok=$true;error="";body=$null;uri=$uri}}
    try {
        $body=@{PartitionKey=$PartitionKey;RowKey=$RowKey}; foreach($key in $Properties.Keys){$body[$key]=$Properties[$key]}
        Invoke-RestMethod -Uri $uri -Method PUT -Headers (Get-StorageHeaders -ContentType "application/json") -Body ($body|ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null
        @{ok=$true;error="";body=$null;uri=$uri}
    } catch {
        @{ok=$false;error=$_.Exception.Message;body=$null;uri=$uri}
    }
}

$Countries=Normalize-StringArray -Value $Countries
$ErrorActionPreference='Stop'
$RunId=[guid]::NewGuid().ToString()

try { Connect-MgGraph -Identity -NoWelcome }
catch {
    [PSCustomObject]@{status='error';runId=$RunId;error="Graph connection failed: $($_.Exception.Message)"}|ConvertTo-Json -Depth 10
    exit
}

try { Connect-AzAccount -Identity | Out-Null; Initialize-Storage }
catch { $script:StorageAvailable=$false; Write-Verbose "Azure connection failed: $($_.Exception.Message)" -Verbose }

$today=(Get-Date).ToUniversalTime().Date
$startDate=$today
$endDate=$today.AddDays($HireDateWindowDays)

$graphProperties=@('Id','DisplayName','UserPrincipalName','Department','Country','JobTitle','OtherMails','EmployeeHireDate','CreatedDateTime','AccountEnabled') -join ','
$allUsers=[System.Collections.Generic.List[object]]::new()
$chunkSize=10

for($i=0;$i -lt $Countries.Count;$i+=$chunkSize){
    $chunk=$Countries[$i..[math]::Min($i+$chunkSize-1,$Countries.Count-1)]
    $countryClause="country in ("+(($chunk|ForEach-Object{"'$_'"})-join ',')+")"
    try {
        $chunkUsers=@(Get-MgUser -All -Filter "accountEnabled eq true and $countryClause" -Property $graphProperties -ConsistencyLevel eventual -ErrorAction Stop)
        $allUsers.AddRange($chunkUsers)
    } catch {
        Write-Verbose "[Graph] Country-filtered query failed; using account-enabled fallback." -Verbose
        $fallback=@(Get-MgUser -All -Filter 'accountEnabled eq true' -Property $graphProperties -ErrorAction Stop)
        $allUsers.AddRange($fallback); break
    }
}

$matchedUsers=[System.Collections.Generic.List[object]]::new()
$skippedUsers=[System.Collections.Generic.List[object]]::new()
$alreadyProcessed=[System.Collections.Generic.List[object]]::new()
$storageWriteFailure=[System.Collections.Generic.List[object]]::new()

foreach($user in $allUsers){
    if($user.Country -notin $Countries){continue}
    if($user.Department -eq 'Field_Sales' -and (-not $user.JobTitle -or $AllowedFieldSalesJobTitles -inotcontains $user.JobTitle.Trim())){continue}
    if(-not $user.EmployeeHireDate){continue}

    $hireDate=([datetime]$user.EmployeeHireDate).ToUniversalTime().Date
    $hireDateStr=$hireDate.ToString('yyyy-MM-dd')
    if($hireDate -lt $startDate -or $hireDate -gt $endDate){continue}

    $createdDateStr=if($user.CreatedDateTime){([datetime]$user.CreatedDateTime).ToString('yyyy-MM-dd')}else{''}
    $partitionKey=$user.Country; $rowKey=$user.Id
    $existingRow=Get-TableRow -StorageAccount $StorageAccountName -TableName $StorageTableName -PartitionKey $partitionKey -RowKey $rowKey
    $processReason='NewUser'; $notifyIT=$true

    if($existingRow){
        $storedHireDate=[string]$existingRow.HireDate; $storedStatus=[string]$existingRow.Status
        if($storedStatus -eq 'Success' -and $storedHireDate -eq $hireDateStr){
            $alreadyProcessed.Add([PSCustomObject]@{displayName=$user.DisplayName;userPrincipalName=$user.UserPrincipalName;country=$user.Country;department=$user.Department;hireDate=$hireDateStr;processedDate=$existingRow.ProcessedDateUtc;skipReason='Already processed - hire date unchanged'})
            continue
        }
        elseif($storedStatus -eq 'SkippedNoEmail' -and $storedHireDate -eq $hireDateStr){$processReason='RetryAfterSkip';$notifyIT=$false}
        elseif($storedHireDate -ne $hireDateStr){$processReason='HireDateChanged'}
        elseif($storedStatus -eq 'Failed'){$processReason='RetryAfterFailure'}
    }

    $otherMail=$null
    if($user.OtherMails -and $user.OtherMails.Count -gt 0){$otherMail=$user.OtherMails[0]}
    if(-not $otherMail){
        $skippedUsers.Add([PSCustomObject]@{displayName=$user.DisplayName;userPrincipalName=$user.UserPrincipalName;country=$user.Country;department=$user.Department;jobTitle=$user.JobTitle;missingFields='otherMail';warningFields='';skipReason='Missing mandatory attribute';createdDate=$createdDateStr;hireDate=$hireDateStr;notifyIT=$notifyIT})
        Set-TableRow -StorageAccount $StorageAccountName -TableName $StorageTableName -PartitionKey $partitionKey -RowKey $rowKey -DryRun $DryRun -Properties @{UserPrincipalName=$user.UserPrincipalName;HireDate=$hireDateStr;Status='SkippedNoEmail';PasswordResetStatus='N/A';SkipReason='NoPersonalEmail';ProcessedDateUtc=(Get-Date).ToUniversalTime().ToString('o');RunId=$RunId}|Out-Null
        continue
    }

    $managerName=$null;$managerEmail=$null
    try{$manager=Get-MgUserManager -UserId $user.Id -ErrorAction Stop;if($manager){$managerName=$manager.AdditionalProperties.displayName;$managerEmail=$manager.AdditionalProperties.userPrincipalName}}catch{}
    $warnings=@();if(-not $managerName){$warnings+='managerName'};if(-not $managerEmail){$warnings+='managerEmail'}

    $password=$null;$passwordResetStatus='NotStarted';$passwordError=$null
    if(-not $PasswordResetEnabled -or $DryRun){$passwordResetStatus=if($DryRun){'DryRun-NotReset'}else{'Disabled-NotReset'}}
    else{
        try{$password=New-RandomPassword;Update-MgUser -UserId $user.Id -PasswordProfile @{Password=$password;ForceChangePasswordNextSignIn=$true} -ErrorAction Stop;$passwordResetStatus='Success'}
        catch{$passwordResetStatus='Failed';$passwordError=$_.Exception.Message;$password=$null
            $failedWrite=Set-TableRow -StorageAccount $StorageAccountName -TableName $StorageTableName -PartitionKey $partitionKey -RowKey $rowKey -DryRun $DryRun -Properties @{UserPrincipalName=$user.UserPrincipalName;HireDate=$hireDateStr;Status='Failed';PasswordResetStatus='Failed';SkipReason="PasswordResetFailed: $passwordError";ProcessedDateUtc=(Get-Date).ToUniversalTime().ToString('o');RunId=$RunId}
            $skippedUsers.Add([PSCustomObject]@{displayName=$user.DisplayName;userPrincipalName=$user.UserPrincipalName;country=$user.Country;department=$user.Department;jobTitle=$user.JobTitle;missingFields='';warningFields=($warnings -join ', ');skipReason='Password reset failed';errorMessage=$passwordError;createdDate=$createdDateStr;hireDate=$hireDateStr;notifyIT=$true;storageWriteStatus=if($failedWrite.ok){'Success'}else{'Failed'}})
            continue
        }
    }

    $storageWriteResult=Set-TableRow -StorageAccount $StorageAccountName -TableName $StorageTableName -PartitionKey $partitionKey -RowKey $rowKey -DryRun $DryRun -Properties @{UserPrincipalName=$user.UserPrincipalName;HireDate=$hireDateStr;Status='Success';PasswordResetStatus=$passwordResetStatus;SkipReason='';ProcessedDateUtc=(Get-Date).ToUniversalTime().ToString('o');RunId=$RunId}
    if(-not $DryRun -and -not $storageWriteResult.ok){
        $storageWriteFailure.Add([PSCustomObject]@{displayName=$user.DisplayName;userPrincipalName=$user.UserPrincipalName;country=$user.Country;department=$user.Department;hireDate=$hireDateStr;skipReason='Password reset succeeded but storage write failed';errorMessage=$storageWriteResult.error})
        continue
    }

    $matchedUsers.Add([PSCustomObject]@{displayName=$user.DisplayName;userPrincipalName=$user.UserPrincipalName;country=$user.Country;department=$user.Department;jobTitle=$user.JobTitle;otherMail=$otherMail;managerName=$managerName;managerEmail=$managerEmail;createdDate=$createdDateStr;hireDate=$hireDateStr;processReason=$processReason;password=$password;passwordResetStatus=$passwordResetStatus;warnings=($warnings -join ', ')})
}

$usersToNotify=@($skippedUsers|Where-Object{$_.notifyIT -eq $true})
$missingOtherMail=@($skippedUsers|Where-Object{$_.missingFields -eq 'otherMail'})
$managerGroups=@($matchedUsers|Where-Object{-not [string]::IsNullOrWhiteSpace($_.managerEmail)}|Group-Object{$_.managerEmail.ToLower().Trim()}|ForEach-Object{[PSCustomObject]@{managerEmail=$_.Name;managerName=$_.Group[0].managerName;users=@($_.Group|Sort-Object displayName|Select-Object displayName,userPrincipalName,department,country,jobTitle,hireDate)}})
$successfulUsers=@($matchedUsers|Where-Object{$_.passwordResetStatus -eq 'Success'})
$countryStats=@($matchedUsers|Group-Object country|ForEach-Object{[PSCustomObject]@{country=$_.Name;count=$_.Count}})

# Critical notification gate: no processed users and no first-time notification = no Slack.
$slackMessageRequired=($matchedUsers.Count -gt 0 -or $usersToNotify.Count -gt 0)
$slackDetails=''
if($matchedUsers.Count -gt 0){$slackDetails+="`n`nProcessed ($($matchedUsers.Count)):`n";foreach($item in($matchedUsers|Sort-Object displayName)){$slackDetails+="- $($item.displayName) ($($item.userPrincipalName)) — $($item.country) — Start: $($item.hireDate)`n"}}
if($usersToNotify.Count -gt 0){$slackDetails+="`n`nAction Required — Missing attributes ($($usersToNotify.Count)):`n";foreach($item in($usersToNotify|Sort-Object displayName)){$slackDetails+="- $($item.displayName) ($($item.userPrincipalName)) — Missing: $($item.missingFields)`n"}}
$slackMessage=@"
New Joiner Automation Completed

Countries: $($Countries -join ', ')
Hire-date window: $($startDate.ToString('yyyy-MM-dd')) to $($endDate.ToString('yyyy-MM-dd'))
Processed: $($matchedUsers.Count)
Action required (missing attributes): $($usersToNotify.Count)
Already processed (no action): $($alreadyProcessed.Count)
$slackDetails
"@

[PSCustomObject]@{
    status='success';runId=$RunId;countries=($Countries -join ', ')
    departmentRule='All departments except Field_Sales. Field_Sales requires an approved job title.'
    hireDateWindowDays=$HireDateWindowDays
    hireDateWindow="$($startDate.ToString('yyyy-MM-dd')) to $($endDate.ToString('yyyy-MM-dd'))"
    passwordResetEnabled=$PasswordResetEnabled;dryRun=$DryRun
    storageAvailable=$script:StorageAvailable
    storageAccountConfigured=$StorageAccountName;storageTableConfigured=$StorageTableName
    totalUsersFound=$allUsers.Count;matchedUsersCount=$matchedUsers.Count
    successfulUsersCount=$successfulUsers.Count;skippedUsersCount=$skippedUsers.Count
    skippedNotifyCount=$usersToNotify.Count;alreadyProcessedCount=$alreadyProcessed.Count
    storageWriteFailureCount=$storageWriteFailure.Count;managerGroupsCount=$managerGroups.Count
    slackMessageRequired=$slackMessageRequired;slackMessage=$slackMessage
    users=@($matchedUsers|Sort-Object displayName);skippedUsers=@($skippedUsers)
    skippedUsersToNotify=@($usersToNotify);alreadyProcessed=@($alreadyProcessed)
    storageWriteFailures=@($storageWriteFailure);managerGroups=@($managerGroups)
    countryStats=@($countryStats)
    missingManager=@($matchedUsers|Where-Object{-not $_.managerEmail})
    missingOtherMail=@($missingOtherMail)
}|ConvertTo-Json -Depth 10
