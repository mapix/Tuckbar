#!/usr/bin/env python3
"""Read-only Host native acceptance, with explicit guarded normal Quit support.

Root owns CUA input. This harness never clicks, types, posts CGEvent, invokes AX
press, launches apps, or sends collector verification commands. mark-menu is a
checkpoint before Root's real CUA shelf InputView click; verify-open/selection
check fresh original fixture callbacks and independent native window evidence.
"""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import uuid

WORKSPACE = Path(__file__).resolve().parents[1]
MODEL = "Mac17,6"
COLLECTOR = "io.novarock.MacMenuY"
FIXTURE = "io.novarock.MacMenuY.Fixture"
ALLOWED_APPS = {str((WORKSPACE / ("build/" + name + "/Build/Products/Release/MacMenuY.app")).resolve()) for name in ["Verification", "DerivedData", "Production"]}
FIXTURE_PATH = WORKSPACE / "build/native-interaction/MenuYFixture.app"
MODS = {"option", "command", "control", "shift", "capsLock"}
PNG = b"\x89PNG\r\n\x1a\n"


class AcceptanceError(RuntimeError): pass


def exact_modifiers(actual, expected):
    return isinstance(actual, list) and set(actual) <= MODS and set(expected) <= MODS and set(actual) == set(expected)


def native_mouse_click_matches(click, button, modifiers):
    # AX lazy menu evaluation can emit menu delegates with MouseMoved (type 5).
    # A CUA mouse acceptance gate requires the original real down/up event and
    # matching raw CG mouse-button number as well as the named callback fields.
    types = {"left": {1, 2}, "right": {3, 4}}
    numbers = {"left": 0, "right": 1}
    return (click.get("button") == button and click.get("eventType") in types[button]
            and click.get("buttonNumber") == numbers[button]
            and exact_modifiers(click.get("modifiers", []), modifiers))


def label(node): return str(node.get("AXDescription") or node.get("AXTitle") or "")


def fixture_button_index(node, source):
    """Bind InputView's real CGWindow ID to independently checked fixture rows.

    All fixture display names may be identical. Text/title/source AX extras
    cannot establish the numeric source identity used for real CUA clicking.
    """
    match = re.fullmatch(r"menuy\.item\.(\d+)", str(node.get("AXIdentifier", "")))
    if not match: return None
    ident = int(match.group(1))
    found = [int(index) for index, row in source.items() if row.get("windowID") == ident]
    if len(found) > 1: raise AcceptanceError("Actual InputView CGWindow ID maps to multiple fixture indices")
    return found[0] if found else None


def frames_close(a, b, tolerance=2):
    return all(abs(float(a.get(k, -999999)) - float(b.get(k, 999999))) <= tolerance for k in ["x", "y", "width", "height"])


def source_order(values): return sorted(values, key=lambda key: (values[key]["frameQuartz"]["x"], values[key]["frameQuartz"]["y"]))


def restored(before, after, translation=False):
    if set(before) != set(after) or not before or source_order(before) != source_order(after): return False
    first = source_order(before)[0]
    delta = after[first]["frameQuartz"]["x"] - before[first]["frameQuartz"]["x"] if translation else 0
    for key in before:
        expected = dict(before[key]["frameQuartz"]); expected["x"] += delta
        if not frames_close(expected, after[key]["frameQuartz"]): return False
    return True


def application(snapshot, bundle, required=True):
    matches = [app for app in snapshot.get("apps", []) if app.get("bundle") == bundle]
    if not matches and not required: return None
    if len(matches) != 1: raise AcceptanceError(f"Independent exact {bundle} process count is {len(matches)}")
    if matches[0].get("truncated"): raise AcceptanceError("Independent AX traversal truncated")
    return matches[0]


def buttons(snapshot):
    app = application(snapshot, COLLECTOR)
    return [node for node in app.get("nodes", []) if node.get("role") == "AXButton" and re.fullmatch(r"menuy\.item\.\d+", str(node.get("AXIdentifier", "")))
            and node.get("intersectsDisplay") and node.get("AXEnabled", True) and not node.get("AXHidden", False)]


def source_frames(snapshot, fixture, count):
    source = application(snapshot, FIXTURE)
    if fixture.get("pid") != source["pid"]: raise AcceptanceError("Independent process PID does not match actual fixture receipt")
    if time.time() - fixture.get("nativeTimestamp", 0) > 5: raise AcceptanceError("Fixture source manifest is stale")
    if snapshot.get("menuBarWindowQueryError") != 0: raise AcceptanceError("Independent native menu-window enumeration failed")
    menu_ids = set(snapshot.get("menuBarWindowIDs", []))
    rows = fixture.get("nativeItems", [])
    result = {}
    names = []
    for index in range(1, count + 1):
        found = [row for row in rows if row.get("index") == index]
        if len(found) != 1: raise AcceptanceError(f"Fixture {index} own status-item manifest missing/ambiguous")
        row = found[0]
        name = row.get("name")
        if row.get("sourcePID") != source["pid"] or name != f"Fixture-{index}":
            raise AcceptanceError(f"Fixture {index} has a wrong source PID or stable autosave name")
        names.append(name)
        # Modern NSStatusItems are hosted by Control Center. The fixture may
        # have no Screen Recording entitlement, and its remote proxy frames/
        # windowNumber may be stale or unrelated to real WindowServer IDs.
        # Its own autosave-name/index/PID manifest binds a uniquely named real
        # menu-window ID from this independent, authorized observer instead.
        windows = [window for window in snapshot.get("windows", [])
                   if window.get("id") in menu_ids and window.get("name") == name and window.get("layer") == 25]
        if len(windows) != 1:
            raise AcceptanceError(f"Fixture {index} stable title matches {len(windows)} independent real menu windows; exactly one required")
        window = windows[0]
        frame = window.get("frame", {})
        if not window.get("id") or frame.get("width", 0) <= 0 or frame.get("height", 0) <= 0:
            raise AcceptanceError(f"Fixture {index} independent native window lacks a real ID/frame")
        result[str(index)] = dict(row, windowID=window["id"], frameQuartz=frame,
            hostPID=window["pid"], onScreen=window.get("onScreen", False), independentWindow=window,
            identityMethod="fixture-own-autosave-manifest + independent-unique-native-menu-title-and-CGS-ID",
            sourceObservation=dict(row), sourceReportedWindowID=row.get("windowID"),
            sourceReportedFrameQuartz=row.get("frameQuartz"), sourceNativeMatchCount=row.get("nativeMatchCount"),
            sourceNativeIdentityMethod=row.get("nativeIdentityMethod"))
    if len(set(names)) != count or len({row["windowID"] for row in result.values()}) != count:
        raise AcceptanceError("Original fixture manifest names / independent real native IDs are not unique")
    return result


class HostHarness:
    def __init__(self, args):
        self.args = args
        if not args.verification_host or args.expected_model != MODEL or str(args.collector_path.resolve()) not in ALLOWED_APPS or args.fixture_path.resolve() != FIXTURE_PATH.resolve():
            raise AcceptanceError("Host harness requires explicit --verification-host, exact Mac17,6 and fixed collector/fixture paths")
        actual = subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"], text=True).strip()
        if actual != MODEL: raise AcceptanceError("Exact authorized Host hardware model mismatch")
        if not args.fixture_state.resolve().is_relative_to((WORKSPACE / "artifacts").resolve()): raise AcceptanceError("Fixture evidence path must remain in this workspace's artifacts")
        args.artifacts.mkdir(parents=True, exist_ok=True)
        self.artifacts = args.artifacts
        self.base_args = [str(args.observer), "--verification-host", "--expected-model", MODEL,
            "--collector-path", str(args.collector_path.resolve()), "--fixture-path", str(args.fixture_path.resolve()),
            "--fixture-state", str(args.fixture_state.resolve())]
        if args.fast_window_only: self.base_args.append("--fast-window-only")
        if args.trace_phases: self.base_args.append("--trace-phases")

    def read_fixture(self):
        value = json.loads(self.args.fixture_state.read_text())
        if not isinstance(value, dict): raise AcceptanceError("Fixture receipt is not a JSON object")
        return value

    def snapshot(self, name="host-native"):
        response = subprocess.run(self.base_args, capture_output=True, timeout=55)
        if response.returncode: raise AcceptanceError(response.stderr.decode(errors="replace")[-1800:])
        value = json.loads(response.stdout)
        if response.stderr: (self.artifacts / (name + "-" + uuid.uuid4().hex[:8] + "-phases.log")).write_bytes(response.stderr)
        if value.get("model") != MODEL: raise AcceptanceError("Independent Host observer model mismatch")
        (self.artifacts / (name + "-" + uuid.uuid4().hex[:8] + ".json")).write_text(json.dumps(value, indent=2, ensure_ascii=False))
        return value

    def checkpoint_path(self):
        return self.args.checkpoint or self.artifacts / "checkpoint.json"

    def save_checkpoint(self, checkpoint):
        self.checkpoint_path().write_text(json.dumps(checkpoint, indent=2, ensure_ascii=False))

    def checkpoint(self):
        value = json.loads(self.checkpoint_path().read_text())
        if value.get("model") != MODEL or value.get("collectorPath") != str(self.args.collector_path.resolve()): raise AcceptanceError("Checkpoint belongs to another Host/collector")
        return value

    def capture(self):
        snapshot = self.snapshot()
        fixture = self.read_fixture()
        source = source_frames(snapshot, fixture, self.args.count)
        return snapshot, fixture, source

    def mark(self, menu=False):
        snapshot, fixture, source = self.capture()
        checkpoint = {"model": MODEL, "collectorPath": str(self.args.collector_path.resolve()), "createdAt": time.time(),
            "fixturePID": fixture["pid"], "opensOffset": len(fixture.get("opens", [])), "source": source,
            "sourceOrder": source_order(source), "inputMethod": "Root CUA real shelf InputView; harness never sends input"}
        if menu:
            if self.args.index is None or self.args.button is None: raise AcceptanceError("mark-menu requires --index and --button")
            candidates = [node for node in buttons(snapshot) if fixture_button_index(node, source) == self.args.index]
            if len(candidates) != 1: raise AcceptanceError(f"Exactly one real native shelf InputView target is required; found {len(candidates)}")
            checkpoint.update(index=self.args.index, button=self.args.button, modifiers=self.args.modifiers,
                              mode=source[str(self.args.index)]["mode"], target=candidates[0])
        self.save_checkpoint(checkpoint)
        return {"passed": True, "checkpoint": str(self.checkpoint_path()), "evidence": checkpoint}

    def verify_open(self):
        checkpoint = self.checkpoint()
        snapshot, fixture, source = self.capture()
        if fixture["pid"] != checkpoint["fixturePID"]: raise AcceptanceError("Original fixture process changed after input checkpoint")
        index = checkpoint["index"]
        events = [event for event in fixture.get("opens", [])[checkpoint["opensOffset"]:] if event.get("timestamp", 0) >= checkpoint["createdAt"]]
        clicks = [event for event in events if event.get("index") == index and "button" in event]
        opened = [event for event in events if event.get("menuOpened") == index]
        if not opened or len(clicks) != 1 or index not in fixture.get("openMenus", []): raise AcceptanceError("Fresh actual original menu open and exactly one original click callback are required")
        click = clicks[0]
        if not native_mouse_click_matches(click, checkpoint["button"], checkpoint["modifiers"]):
            raise AcceptanceError("Original native client lacks real mouse down/up/buttonNumber or has wrong/extra modifiers; AX MouseMoved lazy-menu callbacks cannot pass")
        if click.get("mode") != checkpoint["mode"] or any(event.get("mode") != checkpoint["mode"] for event in opened): raise AcceptanceError("Original custom/declarative client mode changed")
        source_app = application(snapshot, FIXTURE)
        menus = [node for node in source_app.get("nodes", []) if node.get("role") == "AXMenu" and node.get("intersectsDisplay")]
        popups = [window for window in snapshot.get("windows", []) if window.get("pid") == fixture["pid"] and window.get("onScreen")
                  and window.get("layer", 0) >= 101 and window.get("frame", {}).get("width", 0) > 40 and window.get("frame", {}).get("height", 0) > 30]
        if not menus and not popups: raise AcceptanceError("Original callback exists but independent actual native menu visibility is missing")
        checkpoint["openedVerifiedAt"] = time.time(); checkpoint["openedEvidence"] = {"events": events, "menus": menus, "popups": popups}
        self.save_checkpoint(checkpoint)
        return {"passed": True, "name": "Actual CUA InputView open, exact original native button/modifiers and menu visibility", "mode": checkpoint["mode"], "events": events, "menus": menus, "popups": popups}

    def verify_selection(self):
        checkpoint = self.checkpoint()
        if not checkpoint.get("openedVerifiedAt"): raise AcceptanceError("Independent actual open must be verified before Root selects the original menu")
        snapshot, fixture, source = self.capture()
        if fixture["pid"] != checkpoint["fixturePID"]: raise AcceptanceError("Original client PID changed")
        index = checkpoint["index"]
        events = fixture.get("opens", [])[checkpoint["opensOffset"]:]
        selected = [event for event in events if event.get("selection") == index and event.get("timestamp", 0) >= checkpoint["openedVerifiedAt"]]
        if not selected or any(event.get("mode") != checkpoint["mode"] for event in selected): raise AcceptanceError("Fresh original NSMenu selection callback missing or wrong client mode")
        if index in fixture.get("openMenus", []): raise AcceptanceError("Original menu remains open after selection")
        if not restored(checkpoint["source"], source): raise AcceptanceError("Original native source frames and neighboring order have not returned")
        return {"passed": True, "name": "Fresh real original selection and independent exact source restoration", "events": selected, "sourceOrder": source_order(source)}

    def compare(self):
        checkpoint = self.checkpoint()
        _, fixture, source = self.capture()
        if fixture["pid"] != checkpoint["fixturePID"]: raise AcceptanceError("Source PID changed during native restoration check")
        okay = restored(checkpoint["source"], source, self.args.allow_translation)
        if not okay: raise AcceptanceError("Independent original source frames/order/neighbor distances differ from checkpoint")
        return {"passed": True, "name": "Independent original source positions/order restored", "source": source}

    def panel(self):
        snapshot, fixture, source = self.capture()
        collector = application(snapshot, COLLECTOR)
        visible = [node for node in collector["nodes"] if node.get("AXIdentifier") == "MacMenuY-horizontal-shelf" and node.get("intersectsDisplay")]
        if not visible: raise AcceptanceError("Actual native shelf AX container is not visible")
        candidates = []
        for window in snapshot.get("windows", []):
            if window.get("pid") != collector["pid"] or not window.get("onScreen") or window.get("frame", {}).get("height", 0) <= 30: continue
            for screen in snapshot.get("screens", []):
                rect = screen["frameQuartz"]
                if abs(window["frame"]["width"] - rect["width"]) <= 2 and abs(window["frame"]["x"] - rect["x"]) <= 2:
                    candidates.append(window)
        if len(candidates) != 1: raise AcceptanceError("Exactly one independent full-width native panel is required")
        panel = candidates[0]
        band = max(row["frameQuartz"]["y"] + row["frameQuartz"]["height"] for row in source.values())
        if panel["frame"]["y"] < band - 1 or abs(panel.get("alpha", -1) - .9) > .01: raise AcceptanceError("Actual native panel covers formal bar or lacks 90% WindowServer alpha")
        covers = [window for window in snapshot.get("windows", []) if window.get("pid") == collector["pid"] and window.get("onScreen")
                  and window["frame"]["width"] > 40 and window["frame"]["height"] > 1 and window["frame"]["y"] < band - 1]
        if covers: raise AcceptanceError("Independent WindowServer found a collector cover over formal menubar")
        native = buttons(snapshot)
        target_count = self.args.expected_visible_count or self.args.count
        fixture_buttons = [node for node in native if fixture_button_index(node, source) in range(1, self.args.count + 1)]
        if len(fixture_buttons) != target_count: raise AcceptanceError(f"Actual fixture InputView buttons rendered {len(fixture_buttons)}, expected {target_count}")
        if not self.args.screenshot or not self.args.screenshot.is_file(): raise AcceptanceError("Actual fresh native screenshot is required")
        if not self.args.screenshot.read_bytes().startswith(PNG): raise AcceptanceError("Native artifact is not PNG")
        after = self.args.after or self.checkpoint().get("createdAt", time.time())
        if self.args.screenshot.stat().st_mtime < after: raise AcceptanceError("Native PNG artifact predates its acceptance checkpoint")
        if not self.args.diagnostics: raise AcceptanceError("Image completeness needs supplemental actual collector diagnostics")
        diagnostics = json.loads(self.args.diagnostics.read_text())
        items = [row for row in diagnostics.get("items", []) if row.get("key", "").startswith(FIXTURE + ":")]
        if len(items) != self.args.count or not all(row.get("hasImage") is True for row in items): raise AcceptanceError("All original fixture native images must be present")
        return {"passed": True, "name": "Actual visible native panel, all source images/buttons, alpha90 and fresh PNG", "panel": panel, "buttons": fixture_buttons, "screenshot": str(self.args.screenshot)}

    def quit(self):
        result = subprocess.run(self.base_args + ["--terminate-collector"], capture_output=True, timeout=10)
        if result.returncode: raise AcceptanceError(result.stderr.decode(errors="replace")[-1500:])
        request = json.loads(result.stdout)
        if request.get("accepted") is not True: raise AcceptanceError("Public normal collector Quit request was not accepted")
        return {"passed": True, "name": "Public normal exact collector Quit requested; completion must be checked independently", "request": request}


def self_test():
    assert not exact_modifiers(["option", "command"], ["option"])
    assert native_mouse_click_matches({"eventType": 3, "buttonNumber": 1, "button": "right", "modifiers": []}, "right", [])
    assert not native_mouse_click_matches({"eventType": 5, "buttonNumber": 0, "button": "left", "modifiers": []}, "left", [])
    assert not native_mouse_click_matches({"eventType": 3, "buttonNumber": 1, "button": "right", "modifiers": ["command"]}, "right", [])
    identities = {"8": {"windowID": 123}, "32": {"windowID": 456}}
    assert fixture_button_index({"AXIdentifier": "menuy.item.456", "AXDescription": "打开 MenuY Fixture"}, identities) == 32
    assert fixture_button_index({"AXIdentifier": "menuy.item.123", "AXDescription": "打开 MenuY Fixture"}, identities) == 8
    assert fixture_button_index({"AXIdentifier": "menuy.item.789", "AXDescription": "打开 Fixture-32"}, identities) is None
    assert fixture_button_index({"AXDescription": "打开 Fixture-32"}, identities) is None
    native = {"menuBarWindowQueryError": 0, "menuBarWindowIDs": [123],
              "apps": [{"bundle": FIXTURE, "pid": 8, "nodes": []}],
              "windows": [{"id": 123, "name": "Fixture-1", "layer": 25, "pid": 746, "onScreen": False,
                           "frame": {"x": -100, "y": 0, "width": 42, "height": 33}}]}
    manifest = {"pid": 8, "nativeTimestamp": time.time(), "nativeItems": [{"index": 1, "name": "Fixture-1", "sourcePID": 8,
                "mode": "custom-action", "nativeMatchCount": 0, "nativeIdentityMethod": "unique-source-view-frame",
                "buttonScreenFrameQuartz": {"x": 1500, "y": 5.5, "width": 42, "height": 22}}]}
    mapped = source_frames(native, manifest, 1)
    assert mapped["1"]["windowID"] == 123 and mapped["1"]["frameQuartz"]["x"] == -100
    assert mapped["1"]["sourceObservation"]["nativeMatchCount"] == 0
    duplicate = dict(native, windows=native["windows"] + [dict(native["windows"][0], id=456)], menuBarWindowIDs=[123, 456])
    try: source_frames(duplicate, manifest, 1)
    except AcceptanceError: pass
    else: raise AssertionError("Duplicate independent native titles must be rejected")
    before = {"1": {"frameQuartz": {"x": -30, "y": 0, "width": 20, "height": 30}}, "2": {"frameQuartz": {"x": -10, "y": 0, "width": 20, "height": 30}}}
    assert restored(before, before)
    swapped = {"1": before["2"], "2": before["1"]}
    assert not restored(before, swapped, True)
    print("PASS: AX MouseMoved delegates cannot pass real-mouse gate; independent unique native titles/CGIDs resolve redacted proxies and labels; no observer, HostUI or input invoked")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("op", choices=["snapshot", "mark", "mark-menu", "verify-open", "verify-selection", "compare-source", "check-panel", "quit"], nargs="?", default="snapshot")
    parser.add_argument("--verification-host", action="store_true")
    parser.add_argument("--expected-model")
    parser.add_argument("--fast-window-only", action="store_true", help="CGWindow/screens/cursor/HID+combined modifier-state only; no AX queries")
    parser.add_argument("--trace-phases", action="store_true", help="Independent observer API phases to stderr / artifact log")
    parser.add_argument("--collector-path", type=Path, default=WORKSPACE / "build/Verification/Build/Products/Release/MacMenuY.app")
    parser.add_argument("--fixture-path", type=Path, default=FIXTURE_PATH)
    parser.add_argument("--observer", type=Path, default=WORKSPACE / "artifacts/host-tools/HostNativeObserver")
    parser.add_argument("--fixture-state", type=Path, default=WORKSPACE / "artifacts/host-native/fixture-state.json")
    parser.add_argument("--artifacts", type=Path, default=WORKSPACE / "artifacts/host-native")
    parser.add_argument("--diagnostics", type=Path)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--count", type=int, default=32)
    parser.add_argument("--index", type=int)
    parser.add_argument("--button", choices=["left", "right"])
    parser.add_argument("--modifiers", nargs="*", default=[])
    parser.add_argument("--expected-visible-count", type=int)
    parser.add_argument("--screenshot", type=Path)
    parser.add_argument("--after", type=float)
    parser.add_argument("--allow-translation", action="store_true", help="Permit only common source x translation after collector separator removal")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test: self_test(); return 0
    if not 1 <= args.count <= 1000 or not set(args.modifiers) <= MODS: parser.error("Invalid fixture count or known modifiers")
    try:
        harness = HostHarness(args)
        operations = {"snapshot": harness.snapshot, "mark": harness.mark, "mark-menu": lambda: harness.mark(True),
                      "verify-open": harness.verify_open, "verify-selection": harness.verify_selection,
                      "compare-source": harness.compare, "check-panel": harness.panel, "quit": harness.quit}
        value = operations[args.op]()
        result = {"operation": args.op, "timestamp": time.time(), "result": value}
        (args.artifacts / (args.op + "-result.json")).write_text(json.dumps(result, indent=2, ensure_ascii=False))
        print(json.dumps(result, ensure_ascii=False)); return 0
    except (AcceptanceError, OSError, ValueError) as exc:
        print(json.dumps({"passed": False, "error": str(exc)}, ensure_ascii=False)); return 1


if __name__ == "__main__": raise SystemExit(main())
