# synthetic: a reflog file this clone only ever fetched into, so there is no push to observe

Every line is `fetch` or `pull`. Models the branch that someone pushed **from another machine**: this clone saw the ref move, but never saw a push. The reader must return no observation and the label falls back to "Last push unknown · newest commit dated …", never a fabricated push date.

Invariants: `reflogFileWithOnlyFetchLinesFallsBack`, `pushFromAnotherMachineYieldsNoObservationNotAFakeDate`, `fallbackLabelDoesNotClaimGitHubObservedTheBranch`.
