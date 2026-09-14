# Notification Flow Fixes

## Change 1 — Runbook: department is optional

The Runbook no longer uses a general `country + department` mandatory block.

Country remains a hard eligibility filter, and `Field_Sales` remains a special department rule based on approved job titles.

A normal user with a valid country and hire date can therefore be processed even when `Department` is empty.

The blocking attribute for onboarding is the personal email (`OtherMails`).

## Change 2 — Logic App: Select actions

The affected actions are:

- `Select_Processed_Rows`
- `Select_Skipped_Rows`

The `concat()` expression itself is not the problem. The important part is the **Select output mode**.

These actions must use **text mode**, so code view should contain a string expression:

```json
"select": "@{concat(...)}"
```

They should not be configured as an object map that creates records such as:

```json
{"": "<tr>...</tr>"}
```

The report then safely uses:

```text
join(body('Select_Processed_Rows'), '')
join(body('Select_Skipped_Rows'), '')
```

The processed source is:

```text
body('Parse_JSON')?['users']
```

The skipped source is:

```text
body('Parse_JSON')?['skippedUsersToNotify']
```

## Change 3 — `missingOtherMail`

Do not use:

```powershell
@($skippedUsers | Where-Object { -not $_.otherMail })
```

Skipped records do not need to contain an `otherMail` property, so that test can incorrectly classify unrelated skipped records.

Use:

```powershell
missingOtherMail = @(
    $skippedUsers | Where-Object { $_.missingFields -eq "otherMail" }
)
```

If the Logic App does not consume this field, removing it from the output is even cleaner.

## Slack gate — most important rule

The Runbook uses:

```powershell
$slackMessageRequired = (
    $matchedUsers.Count -gt 0 -or
    $usersToNotify.Count -gt 0
)
```

The Logic App uses the equivalent condition:

```text
matchedUsersCount > 0 OR skippedNotifyCount > 0
```

This means:

| Processed | New notification-worthy skip | Slack? |
|---:|---:|---|
| 0 | 0 | No |
| >0 | 0 | Yes |
| 0 | >0 | Yes |
| >0 | >0 | Yes |
| 0 | 0, but previously notified skips exist | No |

`skippedUsersCount` must not be used as the Slack/IT gate because it includes records that may already have been notified.

## Why this fixes the original department issue

A user with a valid country and hire date but no department now reaches the personal-email check. If the personal email is missing, the record contains:

```text
missingFields = "otherMail"
```

so the Slack/IT report identifies the actual missing attribute instead of reporting `department`.
