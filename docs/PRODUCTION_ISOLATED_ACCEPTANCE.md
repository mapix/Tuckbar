# Independent Guest acceptance

The host runners send input only through an explicit Root supplied CLI connected
to a persistent Guest VNC session. They never run host apps, move the host
pointer, or invoke host Accessibility actions. All Guest interaction coordinates
are Quartz points; the VNC driver maps these to its backing framebuffer pixels.

## Observer and input prerequisites

`Tests/GuestNativeObserver.swift` is a separate, read-only native process. Its
VirtualMac hardware guard runs before any AX/window observation. It records:

- Original source AX identifiers, labels, enabled state and frames.
- Independently queried real CGWindow IDs, host PIDs, frames, alpha and visibility,
  including status windows hosted by Control Center, even when offscreen.
- Actual read-only `cursorQuartz` and each screen's Quartz/AppKit bounds plus
  backing scale, for proving external input coordinate calibration.
- The actual collector AX shelf container, native buttons and original menus.

Compile on the host without launching it:

```sh
xcrun swiftc Tests/GuestNativeObserver.swift -o artifacts/vm-tools/GuestNativeObserver
```

The observer needs its own normal Guest Accessibility and Screen Recording
permission grants. A collector's grant does not authorize another executable.
Root may explicitly run `GuestNativeObserver --request-permissions` in the Guest
to open its standard permission dialogs. Missing observer authorization is a
failed prerequisite; no gate falls back to collector assertions.

The external `--input-driver` is an executable invoked with one JSON argument.
It must return a JSON object with `success: true` only after the requested VNC
input is drained. Supported requests:

```json
{"op":"move","vm":"menuy-tahoe","coordinateSpace":"quartz-points","x":120,"y":80}
{"op":"click","vm":"menuy-tahoe","coordinateSpace":"quartz-points","x":120,"y":80,"button":"right","modifiers":["option"]}
{"op":"key","vm":"menuy-tahoe","coordinateSpace":"quartz-points","key":"Down","modifiers":[]}
{"op":"text","vm":"menuy-tahoe","coordinateSpace":"quartz-points","text":"Fixture-32"}
{"op":"screenshot","vm":"menuy-tahoe","coordinateSpace":"quartz-points","path":"/absolute/host/artifact.png"}
```

Keys used by the suites are `Down`, `Return`, `BackSpace`, and `a`. Screenshot
responses return an existing PNG `path`; missing, stale or invalid artifacts fail.
The Root driver owns VNC authentication and connection lifecycle. Secrets never
enter suite requests, arguments, logs or evidence.

## Verification build suite

The strengthened runner normally stops a prepared collector through its normal
Quit path before installing a fresh executable. `copy_bundle` refuses to
replace a running Guest app; it hashes a staged archive before the directory
swap. Even `--skip-copy` checks the Guest executable against the current Host
build before launch, after fresh launch and after normal termination.

```sh
python3 scripts/isolated-vm/guest-suite.py \
  --vm menuy-tahoe --skip-copy \
  --app /tmp/macmenuy-verify/apps/MacMenuY.app \
  --fixture /tmp/macmenuy-verify/fixture/MenuYFixture.app \
  --host-app build/Verification/Build/Products/Release/MacMenuY.app \
  --observer artifacts/vm-tools/GuestNativeObserver \
  --input-driver artifacts/vm-tools/guest-vnc-driver \
  --restoration-fault
```

`MENUY_VERIFY` commands configure preferences, hold previews and request normal
quit. Menu and hover acceptance use external VNC input. Every left/right/Option
click enters the actual shelf InputView AX button. Fresh original `menuOpened`,
exact button and exact known modifiers are required; real keyboard selection
must produce the fixture's original `selection` callback. Independent source AX
must also observe the actual visible original menu and subsequent frame/order
restoration.

Style gates require actual visible panel AX/WindowServer evidence, all 32 source
images, all actual native buttons, 90% WindowServer alpha, formal-bar separation
and fresh valid PNGs. Enable/disable gates require independently observed source
movement and restoration. Normal quit checks both exit receipts and independent
source positions/order. Removing collector separators can translate an entire
source group; neighbor spacing and order within every pinned/folded group must
remain unchanged.

`--restoration-fault` opens a genuine original menu without selecting, quits with
the Guest-only return failure flags, requires nonempty `remaining` and an actual
persisted journal, then starts a fresh PID. Independent source frames/order and
an independently read empty journal must confirm startup recovery.

## Normal shipping build suite

Build the normal app without `MENUY_VERIFY` in `build/Production`. Stop the
verification collector normally first; leave the original Guest fixture running.
The production runner verifies its executable hash and rejects a current binary
containing the verification command surface before copying it.

```sh
python3 scripts/isolated-vm/production-suite.py \
  --vm menuy-tahoe \
  --app build/Production/Build/Products/Release/MacMenuY.app \
  --observer artifacts/vm-tools/GuestNativeObserver \
  --input-driver artifacts/vm-tools/guest-vnc-driver
```

The production suite writes no collector verification command and invokes no
collector test operation. It exercises actual hover/stay/leave, keyboard search,
left/right/Option menus, real selection, native edit/pin/unpin, Enable/Disable
and Quit buttons. Independent AX/windows and original-client callbacks decide
the result. The app's opt-in read-only `--diagnostics-path` is supplemental
permission/setup and final cleanup evidence.

Production Quit has two independent scenarios: an external click on the actual
Quit button, then a fresh launch with a genuine original menu left active and a
public `NSRunningApplication.terminate` request through `GuestCollectorQuit`. Clicking an entry context menu would close the
source popup before termination, so that action cannot prove active-menu quit.
The public request enters the shipping application's normal termination
handler while the original menu is still active. The Guest-only helper checks
the exact collector bundle identity and private `/tmp/` bundle path; it sends
no pointer/key input and does not use an automation script or debug interface.

## Local validation and runtime boundary

```sh
python3 -m py_compile scripts/isolated-vm/guest-suite.py \
  scripts/isolated-vm/native_evidence.py scripts/isolated-vm/production-suite.py
python3 scripts/isolated-vm/guest-suite.py --self-test
python3 scripts/isolated-vm/production-suite.py --self-test
```

These commands check syntax and concrete false-pass vetoes without contacting
any VM or UI. A runtime pass exists only when the Root executes the suites with
normal Guest permission grants and the saved `summary.json` reports `passed`.
A VirtualMac fixture pass does not cover the host's private applications/accounts
or untested multi-display behavior.
