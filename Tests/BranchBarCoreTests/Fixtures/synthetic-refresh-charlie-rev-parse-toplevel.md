# synthetic: `rev-parse --path-format=absolute --show-toplevel` for a third repo

The other single-path half of `synthetic-refresh-charlie-rev-parse.txt`, split when the codex
round-2 review (MAJOR 3) moved repo identity to one invocation per path: `rev-parse` separates its
two paths with a newline, and a directory name may legally contain one, so the combined response
cannot be split back into the two paths that produced it.

One absolute path, the working tree of the repo at `/Users/hannahstulberg/code/charlie` that exists
only in `InMemoryFileSystem`, with the trailing newline git prints. Its sibling
`synthetic-refresh-charlie-rev-parse-common-dir.txt` holds the common directory.
