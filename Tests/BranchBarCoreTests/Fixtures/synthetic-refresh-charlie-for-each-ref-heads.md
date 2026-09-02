# synthetic: `for-each-ref -- refs/heads` for the third repo, dated older than both recorded repos

Seven U+001F-separated atoms in the frozen order: refname, objectname, committerdate:unix,
upstream:short, upstream:remotename, upstream:track (empty), HEAD (`*`).

One branch, `main`, tracking `origin/main` and in sync. Its committer date is **1788000000**,
older than `recorded-branchbar-for-each-ref-heads.txt` (1788317855) and
`recorded-hannah-personal-agent-for-each-ref-heads.txt` (1788310842), so `Repo.lastActivity`
orders the three repos branchbar, hannah-personal-agent, charlie by activity while their names
order them branchbar, charlie, hannah-personal-agent. The refresh-order tests need those two
orders to disagree.
