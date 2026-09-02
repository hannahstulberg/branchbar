# synthetic: `for-each-ref -- refs/remotes/` for the third repo

One row, `refs/remotes/origin/main`, whose object name and committer date match the branch tip in
`synthetic-refresh-charlie-for-each-ref-heads.txt`. Three U+001F-separated fields: refname,
objectname, committerdate:unix.

Matching tips keep `originMovedSince` false for this repo, so a refresh test that fails is failing
about the refresh and not about a push observation.
