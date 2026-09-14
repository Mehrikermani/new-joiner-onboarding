# Logic App Select Fix

The `Select` actions are used to turn onboarding records into HTML table rows.

## The failure mode

If Select is configured in normal object-map mode, the output can become:

```json
[
  {"": "<tr>...</tr>"}
]
```

Joining that array produces the unwanted JSON wrapper in the email.

## Correct mode

Use **text mode** for both actions.

### `Select_Processed_Rows`

```text
From:
@body('Parse_JSON')?['users']

Text value:
@{concat(...)}
```

### `Select_Skipped_Rows`

```text
From:
@body('Parse_JSON')?['skippedUsersToNotify']

Text value:
@{concat(...)}
```

The `concat()` is responsible for generating one HTML string per input record. It does not need to be replaced with another HTML-building expression.

## Join

After the Select actions return strings, these expressions are correct:

```text
join(body('Select_Processed_Rows'), '')
```

```text
join(body('Select_Skipped_Rows'), '')
```

The expected Select output is an array of strings, for example:

```json
[
  "<tr>...</tr>",
  "<tr>...</tr>"
]
```

Azure Logic Apps documentation explicitly supports text mode/code view for creating a string array from an object array.
