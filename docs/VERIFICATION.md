# MacMenuY verification — 2026-10-29

> 当前交接状态以 [RESIDUAL_HANDOFF.md](RESIDUAL_HANDOFF.md) 为准。用户已要求关闭虚拟机并转回本机验证；下文部分表格是历史样本，不能证明当前版本整体验收完成。真实右键修饰键及菜单选择仍未完成定位，正式交付门仍未通过。

## Latest human acceptance scope

- Native folding of controllable status items, with genuine native pin/unpin.
- Uncontrollable system items remain unchanged. No layer covers the original menubar.
- Hover the real collector entry to open a full-width horizontal shelf immediately
  below the formal bar; keep open within entry/shelf and collapse when leaving both.
- Hover does not activate or steal keyboard focus from the working application.
- Original icons/text/badges, native left/right/modifier menus and quick search.
- Independent modern Settings: native/glass/compact styles, icon sizes, opacity 0.9,
  stable sorting presets and wildcard priority rules.
- Accurate unified reminders: explicit unread hints versus visual icon activity;
  unavailable observations retain prior confirmation rather than inventing zero.
- Easy enable/disable/quit, persisted pins/preferences and bounded native restoration.
- Complete actual runtime verification before inviting the user to experience.
- Latest user direction: close the VM and perform remaining verification on the host; coordinate short mouse windows when required.

## Verified host/source evidence

Host: macOS 26.4.1 (25E253), Xcode 26.6, Apple Silicon, notched
1728x1117pt screen. Bundle identity: `io.novarock.MacMenuY`.

| Gate | Evidence | Result |
| --- | --- | --- |
| Production build/signature | Release arm64+x86_64, Developer ID, strict codesign verify | Passed |
| Shipping debug exclusion | No Guest command flags/test panel strings in production Mach-O | Passed |
| 32 distinct real status fixtures | WindowServer IDs and source fixture state | Passed |
| Native hover/stay/leave | `artifacts/runtime/hover-runtime.json`: false → true → true → false, width1728, alpha0.9 | Passed |
| No original-bar cover | Source provider creates no windows; host diagnostics covers=[]; corrected Guest audit queries actual on-screen window overlaps | Host passed; Guest audit pending |
| Genuine native pin/unpin | F8 frame1442 onscreen → frame-3622 hidden; prefs insert/delete; no error | Passed |
| Real original left menu | Fixture `menuOpened:8` timestamp1793255763.544533, matching source click | Passed |
| Real original right menu | Fixture right+`menuOpened:8` timestamp1793255973.82157 | Passed |
| Original unread indicator | F08•3 screenshot + independently read explicit AX unread3 | Passed |
| Independent native Settings | Actual settings UI, 90%, style and32pt selection, custom rule | Passed |
| Rule/settings persistence | Actual relaunch order and pure preferences roundtrip | Passed |
| Quit without pending move | Original process exits, `.exit.json.remaining=[]` | Passed |
| Quit with active/failed native move | Journal and restoration source gates passed; full Host runtime fault/restart gate not completed | Host runtime pending |
| Option and original menu selection | Real right F32 opened; unexpected Command and failed original selection remain | Host runtime pending |
| Final current production application | VM closed; latest non-verification build and complete Host UI gates still required | Pending |

Historical vertical and visual-system-cover prototypes are superseded. Their
screenshots are not acceptance evidence for the latest requested interaction.

## Regressions found and fixed

1. Tahoe hosts all status windows in Control Center: actual source identity recovered
   through bounded AX geometry, independently of host PID.
2. Generic repeated Item-0 names: real window image identity, stable AX/registration
   identity and old pin/recent-use migration.
3. Remote NSWindow proxy numbers exceed UInt32 or are negative: real hosted control
   IDs resolved by unique autosave titles; unsafe conversion removed after a real crash.
4. Temporary reveal now accepts a safe on-screen click center, without confusing
   native spacing gaps with failure. Permanent ordering/pinning keeps its own checks.
5. Plain clicks use the actual source PID and original modifiers; private window field
   0x33 is reserved for native movement. Transport logs never substitute menu callbacks.
6. Incomplete native input/move transactions: bounded shutdown restoration and original
   frame/live-neighbor evidence prevent leftover moves or false restoration passes.
7. Native Menubar single-window capture is mostly transparent. Real background comes
   from native backdrop/wallpaper windows; opaque backplate + independent window alpha
   fixes white-on-white while preserving 90% requested opacity.
8. Image captures are singleflight, off-main CG work and atomic main-actor publication;
   inactive IDs pruned and crop height consistent between composite/individual capture.
9. AX unread failures/time budgets preserve prior confirmation with stale markers.
10. Native hover uses entry edges, grace period, async generation/cancellation and
    no automatic activation. Debug holding is compile-time test-only.

## Historical isolated verification (stopped)

Official Tart macOS Tahoe base image and its VNC proxy have been stopped at the user's request.
Remaining runtime verification is on the host under the user's latest authorization.
Only this project's application and test fixture are copied to the Guest. The runner
uses Tart Guest Agent. Guest screenshots/input and its normal System Settings UI
complete the permission flow without using the host desktop.

Guest: macOS 26.6.2 (25G83), VirtualMac2,1, uid501. SIP and authenticated-root are
enabled, verified through the guest's official `csrutil status` commands after a
guest reboot. The CI template seeds Guest Agent TCC permissions; guest behavioural
passes do not prove a fresh normal user's initial host grant flow. Host security
preferences and input remain untouched. The experimental Tart VNC listener was
stopped after its bind was found to include all interfaces. The later loopback
proxy and VM were also stopped when the user requested Host verification.

Runbook and evidence contract: [ISOLATED_VERIFICATION.md](ISOLATED_VERIFICATION.md).
`MENUY_VERIFY` callbacks must be independently matched to fresh fixture
`menuOpened`, correct buttons/modifiers, native `selection`, and real process exit
with zero remaining restoration windows. A final production build is separate.

## Pure regression gates

`bash scripts/verify-core.sh` covers validated preferences/order/unread (66 checks
plus actual preferences persistence), horizontal geometry (52,209 assertions),
opaque backplate/default alpha, hover state (44 checks), safe window IDs, native
policy/lifecycle/identity, original return evidence and exactly-once event completion.
The complete consolidated script passed in this session. Source typechecks and pure tests do not replace the
pending real Host gates above. Actual multi-monitor menu interaction is not proven
by pure geometry tests; current host runtime scope is its single display.
