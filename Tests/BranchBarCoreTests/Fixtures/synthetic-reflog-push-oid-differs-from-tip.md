# synthetic: an observed push whose new OID is not the current remote-tracking tip

The newest push line lands on OID b…. Paired with a remote-tracking tip that is **not** b… (use any other OID from `synthetic-for-each-ref-remotes.txt`), this sets `PushInfo.originMovedSince`, which appends "(origin has moved since)" to the row. Paired with tip b… it must not.

Invariant: `observedPushWhoseOIDIsNotTheRemoteTipSetsOriginMovedSince`.
