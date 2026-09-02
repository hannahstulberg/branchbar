# synthetic: `gh auth status` output for a host whose stored token is rejected

Ends with `HTTP 401: Bad credentials`. PLAN.md §3: an auth failure short-circuits `gh pr list` for **every** repo on that host, and each branch renders `unavailable` with the `ghNotAuthenticated(host)` copy and its one action.

Invariants: `authStatusFailureShortCircuitsPRListForAllReposOnThatHost`, `ghMissingMakesEveryBranchUnavailableWithoutThrowing`.
