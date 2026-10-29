# Attribution and license

MacMenuY is a GPL-3.0 derivative of [Ice](https://github.com/jordanbaird/Ice),
Copyright Jordan Baird and contributors. Baseline commit:
`11edd39115f3f43a83ae114b5348df6a0e1741cf`.
The original source headers, resources, acknowledgements and license are retained.

MacMenuY adds a hover-driven, full-width horizontal searchable shelf, native
pin/unpin controls, persistent ordering and appearance settings, indicator
activity and explicit unread hints, bounded restoration with a local recovery
journal, and local diagnostics. It does not cover the original menu bar; system
items that macOS does not allow moving remain unchanged. Earlier vertical and
visual-cover experiments are superseded. It uses its own bundle identity and
has no update feed.

Dependencies retain their respective licenses in the Xcode package checkouts.
Distributed source includes LICENSE and this notice.

Tahoe drag/reflow and per-window image handling derived from
[BozhengLong/Barkeep](https://github.com/BozhengLong/Barkeep), GPL-3.0.
Source-process resolution design references
[leonardovida/icey](https://github.com/leonardovida/icey), GPL-3.0,
MenuBarItemService/SourcePIDCache.swift.
