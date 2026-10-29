# MacMenuY verification — 2026-10-29

## Current acceptance scope

- Controllable menu items fold natively into the collector entry. Uncontrollable
  system items remain unchanged. The original menubar MUST NOT be covered by a layer.
- Hover the real collector entry to expand; remain open while over the collector
  or expanded shelf; leave both to collapse. No default click-only or sticky behavior.
- Default expansion is a native-looking, full-width horizontal shelf immediately
  below the formal menu bar. All entries are visible via wrapping/scrolling and search.
- Original icons, badges, menus, right clicks and modifiers are retained.
- Indicator handling distinguishes explicit unread hints from visual activity;
  never invent unread counts from arbitrary icon changes.
- Independent, modern native Settings offers styles, icon size, sort presets and
  wildcard priority rules; opacity defaults to 0.9.
- Easy enable/disable/quit; persisted pins/preferences; clean native restoration.
- Complete actual runtime verification before the user is invited to experience it.

Target: macOS 26.4.1 (25E253), Xcode 26.6, Apple Silicon with a notched display.
This is a SwiftUI/AppKit status application with its own bundle identity,
`io.novarock.MacMenuY`. All runtime processing is local.

## Evidence obtained

- Earlier Release builds for arm64 + x86_64 succeeded; Developer ID signature verified.
- 384 original drawer geometry boundary cases passed. The horizontal shared geometry
  introduced for the latest requirements has its own tests under development.
- Negative/out-of-range NSWindow proxy numbers are rejected. Actual system-hosted
  control IDs are resolved from unique autosave titles instead of unsafe conversions.
- Native fixture created 32 distinct actual NSStatusItems. Real WindowServer/app
  diagnostics enumerated every fixture without repeated Item-0 collisions.
- Earlier native vertical UI rendered 44 hidden items and 3 system items;
  search correctly filtered Fixture-32. This is historical evidence, not acceptance
  of the latest horizontal/system-cover requirements.
- Fixture-32 physically reached the visible native bar, but earlier adjacency checks
  reported an error because AudioVideoModule occupied the protected gap. The backend
  has been corrected; its final runtime regression remains mandatory.
- Capturing only the system 'Menubar' window returns the actual bar background and
  left application menu, with right-side status glyphs absent. This supports an exact
  background presentation layer for the protected status area.
- Normal outside-click dismissal was observed with actual event timestamps and
  foreground application. A separate MENUY_VERIFY build can keep the shelf open
  during CUA tests; final shipping builds exclude that test-only behavior.

## Issues found and handled

1. macOS 26 re-parents status windows to Control Center, collapsing old owner identities.
2. Repeated Item-0 names collided in caches; images and temporary contexts now key
   by real window identity, with source app identity recovered separately via AX.
3. NSStatusItem remote proxy window numbers can exceed UInt32 or be negative;
   direct conversions caused a real crash and were removed.
4. Native drag pickup reflows the bar. Protected gaps and acknowledgements must be
   reconciled against the actual destination, not only event echoes.
5. Legacy smart-rehide and activation/space callbacks interfered with the new drawer.
6. Latest acceptance requires native system-item cover and horizontal layout, not
   the original third-party-only vertical implementation.

## Required remaining gates

- Latest integrated app builds cleanly, including new settings and shared geometry.
- Actual primary bar has the real collector + unavoidable native system items,
  no cover window or black overlay. Genuine pins move back to the original menubar.
- Actual hover-entry intent, safe pointer transition into shelf, leave auto-collapse.
- Horizontal full-width layout: all IDs, image sizes, wrapping, search, styles/opacity.
- Original left/right/Option menus, actual fixture selection and clean temporary return.
- Live native badge change and explicit AX unread hints; suppress false/ignored alerts.
- User priority rules, stable tie ordering, persisted pins including system items.
- Manager/fixture relaunch, new/removed icons, pause/resume/quit native restoration.
- Test without fixtures against actual third-party/system menus.
- Final normal (non-MENUY_VERIFY) signed app, installation and artifact packaging.

Parallel ownership: native_interaction owns menu backend/source resolver/fixture;
settings_notifications owns preference/notification core/settings; shelf_cover owns
horizontal UI/system presentation/shared geometry. Root integrates and performs all
shared desktop CUA validation. Artifacts/ is local evidence and excluded from Git.
