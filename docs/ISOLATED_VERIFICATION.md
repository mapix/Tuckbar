# Isolated native macOS verification

This suite is prepared for the independent Tart VirtualMac guest. It does not
launch apps, move a pointer, type keys, or open native menus on the user's host
Mac. The host runner talks only to Tart's local guest-control socket.

## Build and copy

Use a `MENUY_VERIFY` build; the command interface is completely absent from a
normal shipping build. The existing root build script supports:

```sh
MENUY_DERIVED_DATA=build/Verification MENUY_SWIFT_FLAGS=MENUY_VERIFY bash scripts/build.sh
```

`guest-suite.py` copies only the given MacMenuY and fixture application bundles
into the guest's private `/tmp/macmenuy-verify` directory using a tar stream over
`tart exec -i`. No host credentials, user application settings or sessions are
copied. Tart's Guest Agent is required; Cirrus Labs non-vanilla images include it.

```sh
python3 scripts/isolated-vm/guest-suite.py --vm menuy-tahoe --prepare-only
# After granting the two permissions through the guest's normal OS UI:
python3 scripts/isolated-vm/guest-suite.py --vm menuy-tahoe --skip-copy \
  --app /tmp/macmenuy-verify/apps/MacMenuY.app \
  --fixture /tmp/macmenuy-verify/fixture/MenuYFixture.app
```

The scoped Tart home defaults to `artifacts/vm/tart-home`, matching the isolated
VM scripts. The VM must be running and the guest's standard Accessibility and
Screen Recording permission flow must already be completed. The suite does not
alter host or guest TCC databases, SIP, security policy or passwords.

## Guest-only command surface

All three conditions are required before a command is consumed:

1. Compile condition `MENUY_VERIFY`.
2. Launch argument `--verification-guest`.
3. Native `hw.model` starts with `VirtualMac`.

Launch arguments (the runner supplies these):

```
--verification-command-file /tmp/macmenuy-verify/collector-command.json
--verification-result-dir /tmp/macmenuy-verify/results
--verification-fixture-state /tmp/macmenuy-verify/fixture-state.json
--diagnostics-path /tmp/macmenuy-verify/collector-state.json
--evidence-dir /tmp/macmenuy-verify/evidence
```

Commands are limited to 64 KiB. IDs use letters, numbers, `-` and `_`, are bounded
to 80 characters and deduplicated. Processing is single-flight on the app's main
actor; output is written atomically to `results/<id>.json`.

Example:

```json
{"id":"original-option-menu-1","op":"native_menu","index":32,"button":"left","modifiers":["option"],"select":true}
```

Allowed operations:

| Operation | Actual path / evidence |
| --- | --- |
| `snapshot`, `refresh` | Current native window identities, frames, pins, image availability and validated preferences. |
| `hover` | Guest hardware pointer enters the real original NSStatusItem, crosses into the actual shelf, leaves; normal hover controller controls visibility and focus. |
| `preview`, `hide` | Test-only stable display and close for image/style verification. |
| `search` | Actual native NSSearchField string/action, followed by in-process accessibility inspection of shelf item buttons. |
| `native_menu` | Same shipping `ShelfManager.activate`; optional Down/Return is posted only to the validated fixture source PID. |
| `cancel_menu` | Escape posted only to the fixture source PID. |
| `pin` | Same shipping native pin/unpin and physical-frame verification; only fixture indices are targets. |
| `preferences` | Validated opacity/icon size/style/sort/rule setters used by Settings. |
| `acknowledge_activity` | Acknowledges visual changes, not fabricated unread state. |
| `enabled` | Same shipping native folding enable/disable. |
| `quit` | Normal NSApplication termination, including asynchronous native-item restoration. |

No command accepts an arbitrary PID, keyboard key, executable, network URL or
native app target. Original menu and pointer actions are confined to the guest;
keyboard/menu targets must have the fixture's exact bundle identity.

## Acceptance gates

The runner requires independent original-client fixture evidence. A successful
CGEvent tap/barrier or `lastNativeAction=completed` cannot satisfy a menu gate.
For each left/right/Option test it checks fresh `menuOpened`, correct button and
modifier callbacks; selection requires the original NSMenu's `selection`
callback, not a direct delegate invocation.

The suite checks:

- VirtualMac identity and guest-native permissions.
- Every original fixture window has a unique real ID; no status-item cover window.
- Real hover intent, movement into shelf, leave collapse and unchanged work-app focus.
- Native search reduces the visible item button set to one.
- Original left/right/Option menu + real keyboard selection + temporary icon return.
- Genuine pin/unpin, manager relaunch and source fixture process/window relaunch.
- Added/removed source status items.
- Original native badge `3` and explicit AX unread `3`, then explicit clearing to `0`.
- User priority rules and native/glass/compact styles at different icon sizes.
- Actual full-width window remains below the formal menubar with opacity `0.9`.
- Enable/disable and normal termination while an original menu is genuinely active.
- `diagnostics.exit.json.remaining == []` after the real process exits.

The runner resets only its private guest command/result files before restarting
an app, so an old quit command or old exit report cannot create a false pass.
Screenshots and all command/client evidence are saved under
`artifacts/isolated-native`.

## Verification limits

The interface and runner have been prepared/type checked without invoking host
UI. Passing source tests is not a VM runtime pass. Guest native permissions, a
running VM and the actual suite results still must be verified by the root.

`MENUY_VERIFY` directly invokes the shipping paths but remains a test build.
The final non-verification application requires a separate guest launch/UI check
to confirm default hover behavior, no test surface and normal native restoration.
A VirtualMac suite does not assert that every private account/application state
on the physical host was tested, nor prove multi-display menu interaction from
pure geometry tests alone.
