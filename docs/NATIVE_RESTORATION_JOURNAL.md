# Native restoration journal

MacMenuY stores pending movement recovery evidence locally in its own
`UserDefaults` key `MacMenuY.NativeRestorationJournal.v1`. It contains only this
collector's source/target identities, original frames and relative native order.
It never launches a source application. Missing or ambiguous identities remain
pending; corrupt original bytes are retained in the `.invalid` backup key.

## Lifecycle

- Record before temporary reveal or permanent pin/unpin movement.
- Remove the record only after a native return or a committed pin/unpin succeeds.
- Normal quitting invalidates ordinary native work and spends at most the existing
  3-second restoration budget, with bounded event acknowledgement cleanup.
- If restoration remains unconfirmed, retain the journal and display a native
  choice: exit with recovery retained, or one more bounded restoration attempt.
  There is no false 'cancel and continue' after the shutdown lifecycle has stopped.
- On launch, create expanded dividers and source identity discovery first. Spend
  a bounded recovery pass before ordinary folding, pin reconciliation and hover.
- An unresolved source or a source's active popup is not guessed or dismissed.
  The existing error surface explains pending recovery. No failed startup movement
  is automatically replayed in a tight loop during normal work.

## Test-only runtime fault gate

Only a `MENUY_VERIFY` build in an explicitly allowed test environment can use
the following flags: `VirtualMac` with `--verification-guest`, or this exact
`Mac17,6` Host with both `--verification-host --verification-host-model Mac17,6`.
The user has stopped the VM and authorized remaining Host verification.

- `--verification-restoration-fail-once`: skip one native return only after an actual
  fixture item is confirmed outside its original position. It does not fake a move.
- `--verification-restoration-exit-save`: this isolated fault case saves the journal
  and exits without an interactive alert so the external Guest suite can inspect it.

The suite must independently prove original fixture `menuOpened`, actual changed
native frame/order, the nonempty `.exit.json.remaining` and `journalSaved`, then a
fresh collector process with real native frame/order restored and no pending journal.
An app event echo or an empty synthetic report is not that evidence.

## Verification obtained here

`Tests/NativeRestorationJournalTests.swift` passed persistent roundtrip, invalid
write protection, corrupt original evidence retention, unresolved identity safety,
and one-way bounded recovery/termination retry tokens. Full application Swift 5
verification typecheck passed. Real Host fault/restart restoration remains a
mandatory runtime gate managed by the root agent.
