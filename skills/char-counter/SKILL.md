---
name: char-counter
description: >
  Counts and reports the number of characters in a file. Reports total characters,
  non-whitespace characters, and line count. ALWAYS invoke this skill after every
  file edit (Edit, Write, MultiEdit) — append the character count summary to your
  response even when the user didn't ask for it. Also invoke when the user asks
  things like "how many chars", "count characters", "how big is this file",
  "character count", or "how long is X file". Don't skip this after edits,
  even minor ones.
---

# char-counter

Count and report characters in a file after every edit and on request.

## After every file edit

Whenever you use Edit, Write, or MultiEdit on a file, append a one-line summary
at the end of your response:

```
📄 <filename>: X,XXX chars | X,XXX non-whitespace | XXX lines
```

This gives the user a running sense of file size without them having to ask.

## When asked directly

If the user explicitly asks about character counts, read the file and print the
full summary block:

```
File: <filename>
Total characters:          X,XXX
Non-whitespace characters: X,XXX
Lines:                       XXX
```

If they ask about multiple files, report each on its own line with a total row.

## Edge cases

- Binary files: report "binary file — character count may be unreliable" and
  give the byte size instead.
- Empty files: report 0 for all counts.
- Very large files (>1 MB): note the size and still report the counts.

