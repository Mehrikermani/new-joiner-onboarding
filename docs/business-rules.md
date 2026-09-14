# Onboarding Business Rules

## Eligibility

A user can enter the onboarding flow when:

1. The account is enabled.
2. The country is in the configured country list.
3. A hire date exists.
4. The hire date is inside the configured onboarding window.
5. If the department is `Field_Sales`, the job title is in the approved Field Sales list.

## Optional vs required attributes

| Attribute | Rule |
|---|---|
| Country | Required for eligibility; countryless users are ignored. |
| Department | Optional for normal departments. |
| Hire date | Required. |
| Personal email / `OtherMails` | Required before onboarding can proceed. |
| Manager | Optional warning; absence does not block onboarding. |

## Notification state

Azure Table Storage state prevents repeated missing-email notifications:

- First missing-email detection → notify IT/Slack.
- Same user and same hire date with email still missing → silently skip.
- Email is added → process normally.
- Hire date changes → allow a new processing attempt.

## Zero-activity rule

A run with no newly processed users and no first-time notification-worthy skips must not send a Slack message or IT report.
