# synthetic: a GitHub Enterprise remote URL

`https://github.nytimes.com/newsroom/interactive-tooling.git`. PLAN.md §2 does not rule out GHE at NYT, and §5 derives the host from the remote URL, so the slug must keep the host and the auth preflight must run `gh auth status --hostname github.nytimes.com`.

Invariant: `enterpriseHostRemoteResolvesSlugAndAuthPreflightPerHost`.
