# Native interaction verification support

Backend scope (2026-10-29): a recorded native event echo is not proof that a
menu opened. Use the fixture's original-client callbacks and actual UI inspection.

## Fixture

Signed app: `build/native-interaction/MenuYFixture.app`.

Start through the normal macOS app launcher with arguments:

```
--count 32
--output /Users/mac/workspaces/MacMenuY/artifacts/fixture-native-state.json
--command-file /Users/mac/workspaces/MacMenuY/artifacts/fixture-command.json
```

The command file is opt-in and controls only the fixture's own native NSStatusItems.
Each unique JSON file value is consumed once; use a new `id` to repeat a command.

```json
{"id":"badge-1","op":"set_badge","index":32,"unreadCount":3}
```

Other commands: `clear_badge` with `index`, `add`, `remove`, and `reset_evidence`.
`set_badge` changes the original status button title and its Accessibility help
(`3 unread notifications`). It does not set a mock MenuY indicator.

Evidence JSON contains `badges`, `commands`, and `opens`. `opens` records the
original client action's `index`, `button`, `modifiers`, `clickCount`, plus actual
`menuOpened`, `menuClosed`, and `selection` delegate/action callbacks. `openMenus`
tracks the currently open native menus. The `Record selection` menu item also
has the native menu keyboard equivalent `p`.

## Static checks completed

- Fixture compiled and its Developer ID signature verified.
- Entire app passed an independent `swiftc -typecheck` against the resolved
  Xcode package modules (`artifacts/native-interaction/typecheck.log`).
- NativeInteractionPolicyTests passed: Caps Lock, notch bounds, inactive accessory
  popovers, regular app-window return, and shared outer .app helper membership.

## Runtime acceptance still required

Actual left/right/Option click callbacks, native menu selection, and temporary
item restoration require the primary agent's on-device UI run. The backend's
new retry/acknowledgement handling is not accepted solely from static tests.

The bridge separates the Command modifier used for an automatic pickup from
captured modifiers applied to the final original-app click. Return context is
recorded before pickup; a failed move/click still receives a return attempt.
Menu interfaces are retained by actual visible popup/window state, including
same-app helper processes; opening a standard app window does not hold an icon
visible forever. If a neighboring return target quits, the section divider is
used as a fallback.

## Final termination and movement transaction APIs

`prepareForTermination(timeout: 3)` is irreversible: it rejects new native
operations, invalidates old event callbacks, stops its timers and balances only
this app's synthesized mouse input/cursor leases. It returns
`NativeRestorationReport(restoredCount, remainingWindowIDs, elapsed, completed)`.
The work budget is capped at three seconds, with up to 250 ms for an in-flight
acknowledgement to unwind; a synchronous stalled macOS API is outside that
clock bound. `restoreTemporaryItems(force: true, timeout: 3)` invokes the same
path. The root uses `NSApplication.TerminateReply.terminateLater` and replies
only after inspecting/saving this report. A passing runtime gate requires
`remainingWindowIDs == []`; type checking does not establish that fact.

Before a permanent pin/unpin movement:

1. `registerMovementRollback(for: item)` returns `NativeMovementCheckpoint`.
2. Run the actual native move and verify the desired physical side/visibility.
3. Check `canCommitMovement(checkpoint)`; it is false once `isShuttingDown`.
4. Persist the verified pin choice, then `commitMovement(checkpoint)`.
5. On error call `requestMovementRollback(checkpoint)`; the return timer retries.

Pending transactions do not get returned by normal timers while persistence is
in flight. Termination restores all uncommitted transactions. Registering a
transaction takes over an existing temporary-menu return position, so quitting
between a menu reveal and its permanent pin still knows the original position.

## Generic item identity

Generic `Item-0` titles prefer a unique, non-`_NS`/`_AX` AXIdentifier. Otherwise
they always use a registration `identitySlot`, including a single-item app.
Existing live windows retain their slot; adding/removing siblings does not
renumber them. New slots are allocated monotonically while that source app
runs. A fresh app launch assigns fallbacks in CG-window registration order.
An app that changes its own creation order and supplies no meaningful identifier
cannot be semantically disambiguated from generic titles alone.

`MenuBarItem.identityMigrationMap(for: items)` returns unambiguous
`oldKey -> newKey` aliases; `item.legacyIdentityKeys` provides per-item aliases.
The root applies these to pins and the settings agent applies them to recents.
The legacy single-item `bundle:Item-0` maps only to slot zero (or that item's
stable AX ID). Non-generic autosave titles retain their original keys.

Fixture flags `--generic-titles --no-stable-ax` exercise the fallback path;
use `--count 1`, then command `add` to verify a one-to-two item transition.
With `--generic-titles` alone the fixture publishes stable
`fixture.item.{index}` accessibility identifiers.

## Native click routing gate repair

The original session-tap echo gate returned success while the real fixture's
`opens/menuOpened` callbacks remained empty. Source inspection identified these
concrete differences from Icey's macOS 26 click transport:

- Plain click targets the source process, not Control Center's hosted-window owner.
- Private window field `0x33` is a movement hint; plain click leaves it unset.
- Plain mouse down uses a click state, mouse up uses zero, and mouse up is repeated
  twice to avoid a stuck native status-item state.
- A source-PID null-entry/session-delivery/null-exit barrier sequences delivery.

The repaired transport has cancellation/termination epoch guards, exactly-once
completion and cursor/input ownership cleanup. It emits opt-in JSONL beside the
`--diagnostics-path`, with extension `.native-click.jsonl`. Records contain
`source-entry`, `session-delivery`, `source-exit`, `click-dispatched`, target/source
and host PID, CG window fields, click state, modifiers and click point.

These diagnostics describe transport and never claim the original client action
occurred. Runtime acceptance still requires actual fixture `menuOpened/selection`
callbacks and inspection of the real native menu. Static type checking and the
barrier completion regression tests alone do not pass that gate.

## Temporary reveal visibility gate

Precise fixture-F08 evidence showed a reveal could time out before the click
transport ran: no F08 click records and no native menu callback. Permanent
pin/unpin had already reached the expected physical side, so temporary reveal
must not insist on exact adjacency to a particular item across native gaps.

Temporary interaction now uses `revealToClickableArea`: it performs native
pickup/drop, then accepts only a real on-screen click center inside the correct
display's safe menu area (past the notch/application-menu boundary). A native
post-release acknowledgement/adjacency error does not cause another drag once
that visibility predicate is satisfied. This predicate is passed only by the
temporary reveal path; permanent pin/order and termination return destinations
retain their existing ordering validation.

Opt-in records `reveal-start`, `reveal-move-start`, `reveal-move-error`,
`reveal-visible-check`, `reveal-ready` and `reveal-failed` include actual CG frames,
minimum safe x, display bounds and attempt. Runtime acceptance still needs
`reveal-ready` followed by the real original client's `menuOpened/selection`.
A source AXPress calibration returned an API timeout while its actual native
menu opened; API completion alone must not be used to infer whether a menu ran.

## Original-return evidence gate

A context registered before pickup may not represent a changed item. One real
failed-reveal exit report retained a window while that original fixture item was
already hidden; hidden status by itself is not sufficient to clear the report.
Contexts now record the actual original CG frame, on-screen bit, and WindowID
order. A return is unnecessary only when the item is still in the same menu band
and its slot between surviving original neighbors is proven unchanged. If no
original neighbors survive, its exact original rectangle is required. Native
reflow, badge width changes or newly added items do not fabricate an item reorder.
A changed order is rejected even if the recorded rectangle happens to match.

Normal and termination restoration still execute actual native movement for
changed items. If its strict acknowledgement/adjacency throws, a fresh proof of
original placement can confirm success; otherwise the context stays pending.
When a recorded neighbor quits, the nearest surviving original neighbor is used
before a section-divider fallback.

Opt-in `.native-restore.jsonl` beside the diagnostics path records every return
phase with original/actual frames and order, original/actual on-screen state,
frame/order match predicates, checkpoint identity, remaining budget and errors.
Remaining contexts receive an explicit final record instead of silently clearing
an exception. The pure return-evidence regression tests do not replace Guest VM
menu-open/failed-reveal exit tests, which must report no genuine remaining moves.
