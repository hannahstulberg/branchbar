# synthetic: a reflog file mixing pushes and fetches, where the newest usable line is a push

Lines oldest-first, as git writes them: a creating push (all-zero **old** OID, which is a creation and not a deletion), a fetch fast-forward, then a newer push. Walking newest-first, the first `update by push` line is the last one and its timestamp is 1788200000.

Invariant: `reflogPushBeatsTipCommitDate`.
