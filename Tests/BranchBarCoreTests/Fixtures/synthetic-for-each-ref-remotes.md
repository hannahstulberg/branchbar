# synthetic: `for-each-ref -- refs/remotes/` rows including the `origin/HEAD` symbolic ref and a second remote

Three U+001F-separated fields per line. Includes `refs/remotes/origin/HEAD`, which the recorded fixture confirms git really prints and which the parser skips (it is a symbolic ref, not a branch), remote-tracking tips for each branch in `synthetic-for-each-ref-heads-mixed.txt`, and a `refs/remotes/upstream/main` row so remote-name splitting cannot be hard-coded to `origin`.

Backs the `originMovedSince` comparison: a branch's observed push OID is checked against the tip in this list.
