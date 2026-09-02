# synthetic: `for-each-ref -- refs/heads` output carrying a truncated row and blank lines between good rows

Five lines: a well-formed row for `main` (seven U+001F fields), a blank line, a **truncated** row
for `truncated` that carries only four fields, another blank line, and a well-formed row for
`second`. The file ends with a trailing newline, the way git's output does.

Real git never prints a short row, but a partially written file, a truncated pipe read, or a
future format edit can, and PLAN.md §5 freezes the field count at seven. The
`ForEachRefParser.parseBranches` OWNER comment splits that case in two: blank lines are **ignored**,
and a line whose field count is not seven **throws** — a recoverable Swift error, never a trap that
takes the whole refresh down with it.

Invariant: `malformedLineIsSkippedNotFatal`. The test parses the fixture with the four-field row
filtered out to prove blank lines are skipped, and parses it whole to prove the short row throws.
