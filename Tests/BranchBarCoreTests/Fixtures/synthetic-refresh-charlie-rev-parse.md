# synthetic: `rev-parse --path-format=absolute --git-common-dir --show-toplevel` for a third repo

Packet 3.2 needs three repos with distinct identities so a stable order has a middle element and
the concurrency cap has something to hold back. Two of the three are the recorded pair
(`recorded-branchbar-*`, `recorded-hannah-personal-agent-*`); this file gives the third, a repo at
`/Users/hannahstulberg/code/charlie` that exists only in `InMemoryFileSystem`.

Two absolute paths, common directory first, exactly as the recorded pair prints them. The common
directory is `<path>/.git`, which is also what `RepoScanner` derives when it runs without a
`CommandRunner`, so the scanned `RepoID` and the loaded one agree.
