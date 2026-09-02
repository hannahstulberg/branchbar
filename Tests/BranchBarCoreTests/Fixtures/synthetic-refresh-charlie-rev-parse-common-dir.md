# synthetic: `rev-parse --path-format=absolute --git-common-dir` for a third repo

The single-path half of `synthetic-refresh-charlie-rev-parse.txt`, split when the codex round-2
review (MAJOR 3) moved repo identity to one invocation per path: `rev-parse` separates its two
paths with a newline, and a directory name may legally contain one, so the combined response
cannot be split back into the two paths that produced it.

One absolute path, the common directory, with the trailing newline git prints. It is
`<path>/.git`, which is also what `RepoScanner` derives when it runs without a `CommandRunner`,
so the scanned `RepoID` and the loaded one agree. Its sibling
`synthetic-refresh-charlie-rev-parse-toplevel.txt` holds the working-tree path.
