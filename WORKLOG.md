# MacMenuY handoff / current checkpoint (2026-10-29)

## Authoritative latest human requirements

Original vertical/click-first and forced-system-cover requests are superseded:
- No black/cover layer over original menubar. Keep uncontrollable native system items.
- Controllable items fold natively; actual pin/unpin returns to/from original menubar.
- Hover real collector entry ~150ms to show full-width horizontal native shelf below
  formal menubar. Keep open inside entry/shelf; leave ~200ms to collapse.
- Hover does not steal working-app focus. Clear independent layer/border/shadow.
- Opacity default 0.9; style/icon sizes/sort rules/accurate indicators.
- Settings separate and opened deliberately; convenient enable/disable/quit.
- Do all development and actual verification before inviting user to experience.
- User explicitly authorized parallel work and debug hacks. User continues using host
  and requires isolated verification: no more host UI/mouse/test menus.

## Project/build

- Native SwiftUI/AppKit, GPL-3.0 derivative of Ice/Barkeep; NOTICE/LICENSE retained.
- Own bundle ID io.novarock.MacMenuY; internal Xcode target/scheme Ice.
- scripts/build.sh supports MENUY_DERIVED_DATA/MENUY_SWIFT_FLAGS. Release universal
  arm64+x86_64 Developer ID signed. Default is production without MENUY_VERIFY.
- scripts/verify-core.sh consolidates core/geometry/hover/backplate/lifecycle tests.
- MENUY_VERIFY includes debug panel and Guest command interface; production excludes.
- Core source files under Ice/, current app ~14MB. Git initialized, no commit yet.

## Actual host evidence already obtained

- Current host: macOS 26.4.1 / Xcode 26.6 / Apple Silicon, notched 1728x1117pt display.
- Old direct NSWindow.windowNumber cast caused a real trap (proxy may be negative
  or 1<<32). Fixed: ControlItem resolves real hosted ID from unique title.
- 32 real fixture NSStatusItems enumerated without Item-0 collisions.
- Actual hover runtime JSON: before=false, afterEntry=true, insideShelf=true,
  afterLeave=false, frame full-width, opacity=0.9, passed=true.
- Actual F8 badge 3 mirrored as F08•3 and independently confirmed AX unread=3.
- Genuine native F8 pin/unpin: onscreen frame1442 -> hidden frame-3622,
  prefs pin inserted/deleted, error empty. Not a visual proxy.
- Native menu routing first failed before click due strict adjacency during temporary
  reveal. New safe-visible reveal is separate from permanent pin/ordering semantics.
- New source PID routing (host ControlCenter vs source client) + safe reveal produced
  actual fixture menuOpened callbacks for LEFT at timestamp1793255763.544533 and
  RIGHT at1793255973.82157. Source fixturePID85495, windowID10533.
- AXPress fixture calibration also opened real menu even though AX call timed out
  while synchronous NSMenu tracking waited. Do not interpret AXCannotComplete alone
  as no UI effect.
- Opacity0.9 / native and glass styles / 24 and32pt sizes / independent modern native
  settings / rule *Fixture* tested through actual UI. Custom rule persisted/reordered.
- Host multiple native quit tests had remaining=[]; one failed-reveal quit earlier
  showed remaining[10533]. NativeReturnEvidence now uses true original frame/live
  neighbor order to clear only genuinely unmodified/already-restored contexts;
  remaining0 with open menu/failed reveal still must be verified in Guest.
- CUA getAXState after app quit may auto-relaunch WITHOUT CLI args. Avoid using it
  as process-exit evidence; use PID/exit report. Restart test app after inspecting PID.
- User/GUI state can change concurrently; deterministic DEBUG target buttons and
  isolated Guest commands eliminate stale CUA indices / wrong icon selection.

## Important code decisions / fixes

- MenuYMenuCover name is compatibility only: appearance/background sampler, creates
  no NSPanel or bar-cover window; diagnostics() returns[]. Only expanded shelf draws.
- Menubar single CG window is mostly TRANSPARENT! It looked black in image viewer
  but RGBA=0. Opaque native background comes from WindowServer underbelly/Backstop +
  Dock Wallpaper; flatten alpha1 then apply Window.alphaValue=.9.
- Native NSSearchField transparent cell + explicit text colors fixes white-on-white.
- All images now MainActor-published, singleflight capture, prune staleIDs, stable
  native24-height crop across composite/individual paths.
- Confirmed unread requires explicit application AX hint. Visual changes are activity,
  not invented unread. Budget/AX failure preserves prior confirmation + stale marker.
- Generic Item-0 identity always stable AXID or registration slot; migration API applied
  to pins and lastUsed. Exact owner vs source separation retained for Tahoe.
- Native movement checkpoints rollback incomplete permanent pin/unpin during quit.
- AppDelegate terminateLater performs bounded native cleanup + writes exit report.

## Isolated verification in progress

- No MacMenuY/fixture host process should be running; host was cleaned on user request.
- Agent isolated_mac_vm installed official Tart2.41.1 via openai/tools/tart.
- TART_HOME is workspace artifacts/vm/tart-home, not global user VM cache.
- Official ghcr.io/cirruslabs/macos-tahoe-base:latest (2026-10-15 CI image), compressed
 26.4GB /50GB disk. Clone vm name menuy-tahoe, original PID92076; last ~18%,5.6GB.
  Download is slow but live and retries support HTTPRange. Do not restart solely due
  observation timeout. Vanilla only ~9% smaller, losing GuestAgent; keep base.
- scripts/isolated-vm/{clone,run,start-background,exec,status,stop,run-recovery}.sh.
- Tart exec uses local Unix GuestAgent socket; no SSH password required. Headless run
  uses no graphics/audio/clipboard/USB, localhost hardware VNC only, no host GUI.
- Official base template may have SIP disabled and GuestAgent TCC preauthorized.
  Agent will verify csrutil status and prefer official Guest Recovery SIP enable.
  Do not modify host protection or falsely claim VM proves normal host TCC grant path.
- Host vncdotool tools prepared in artifacts/vm-tools/venv for Guest hardware VNC only.
- Agent guest_verification_suite writes MENUY_VERIFY Guest command surface + Tart
  guest-suite.py; triple guard --verification-guest + VirtualMac hardware prevents
  accidental host mouse/UI operation. Commands call same real pipeline, source fixture
  callbacks must prove menuOpened/selection, transport alone is insufficient.

## Required remaining work

- Finish Guest VM download/headless start/access; normal guest TCC via Guest-only UI.
- Build current integrated verification app/fixture, copy only this project's artifacts.
- Guest actual Option click, native menu selection, auto native return, open-menu/failed
  reveal quit remaining0, source/manager relaunch pins, all32 IDs/wrap/search/styles/rules,
  badge3->0/stale semantics, no original bar cover, final normal build behaviour.
- Preserve precise host-vs-Guest/SIP/TCC evidence limits, no broad all-menus claim from
  pure tests or taps.
- Final normal production signed build, verify debug code excluded, install/archive
  locally, clean fixture/test prefs, complete report, then invite experience.
- Goal remains active; do not mark complete while Guest runtime gates are pending.
