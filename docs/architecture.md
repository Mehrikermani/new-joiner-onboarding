# Architecture

## Purpose

The solution separates onboarding decision-making from notification orchestration.

- The **PowerShell Runbook** owns eligibility, business rules, state checks, onboarding processing, and the output contract.
- The **Logic App** owns presentation and notification delivery.
- **Azure Table Storage** provides lightweight state needed for repeat-safe scheduled execution.

## Components

| Component | Responsibility |
|---|---|
| Azure Automation | Schedules and executes the PowerShell Runbook |
| PowerShell | Implements onboarding business rules and processing logic |
| Microsoft Graph | Provides user, manager, and directory information |
| Azure Table Storage | Tracks onboarding/notification state |
| Azure Logic Apps | Orchestrates email, IT reporting, and Slack notifications |
| Email | Delivers onboarding and operational messages |
| Slack | Provides an operational activity notification when required |

## Data flow

```text
Configuration
     |
     v
Azure Automation
     |
     +---- Microsoft Graph <----> User / Manager data
     |
     +---- Azure Table Storage <-> Processing state
     |
     v
Structured onboarding JSON
     |
     v
Azure Logic App
     |
     +----> New joiner email
     +----> Manager email
     +----> IT report (when required)
     +----> Slack notification (when required)
```

## Separation of concerns

### Runbook

The Runbook is responsible for deciding **what happened**:

- which users are eligible
- which users were processed
- which users were skipped
- why a user was skipped
- whether a skipped user is newly notification-worthy
- which managers need grouped notifications
- whether the run has meaningful activity

### Logic App

The Logic App is responsible for deciding **how the result is communicated**:

- email formatting
- manager grouping
- IT report rendering
- Slack delivery
- HTML table generation

Keeping these responsibilities separate avoids duplicating onboarding rules inside the notification workflow.

## Notification decision

The notification gate is intentionally based on **new activity**, not simply the total number of skipped users:

```text
Send IT/Slack activity notification when:

    processed users > 0
    OR
    first-time notification-worthy skips > 0
```

Therefore:

| Processed | New notification-worthy skips | Notification |
|---:|---:|---|
| 0 | 0 | No |
| >0 | 0 | Yes |
| 0 | >0 | Yes |
| >0 | >0 | Yes |

This prevents a scheduled run from repeatedly notifying IT just because an old skipped record still exists.

## Integration contract

The Runbook returns structured JSON rather than HTML. The Logic App consumes collections and counts such as:

```text
users
skippedUsers
skippedUsersToNotify
matchedUsersCount
skippedUsersCount
skippedNotifyCount
```

The notification workflow can therefore remain focused on presentation while the Runbook remains the source of truth for business decisions.

## Operational considerations

The portfolio version deliberately uses placeholders for environment-specific resources. A real deployment should inject configuration securely and keep secrets outside source control.

The architecture is intentionally modular so that the notification layer can evolve independently of the onboarding decision logic.
