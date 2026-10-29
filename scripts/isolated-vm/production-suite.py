#!/usr/bin/env python3
"""Accept the normal shipping MacMenuY inside an isolated VirtualMac Guest.

No collector verification command is written or invoked. All interactions enter
native views through Root's external Guest VNC driver. The original fixture's
NSMenu callbacks and a separate AX/WindowServer observer decide each gate.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import uuid
from native_evidence import (
    COLLECTOR_BUNDLE, FIXTURE_BUNDLE, ExternalInput, NativeObserver, actual_panel,
    app as native_app, center, exact_modifiers, executable, executable_hash,
    find_button, fixture_index, frames_close, label, native_buttons,
    no_cover_windows, positions_restored, relative_positions_restored,
    source_order, source_positions,
)

WORKSPACE = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("menuy_guest_transport", Path(__file__).with_name("guest-suite.py"))
_transport = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_transport)
TartGuest, VerificationError = _transport.TartGuest, _transport.VerificationError


class ProductionSuite:
    def __init__(self, args):
        self.args = args
        self.guest = TartGuest(args.vm, args.tart_home, args.tart)
        self.artifacts = args.artifacts
        self.artifacts.mkdir(parents=True, exist_ok=True)
        self.base = args.guest_dir.rstrip("/")
        self.input = ExternalInput(args.input_driver, args.vm, self.artifacts)
        self.observer = NativeObserver(self.guest, args.observer_guest_dir, self.artifacts, args.observer)
        self.checks = []
        self.collector = self.base + "/apps/" + args.app.name
        self.diagnostics = self.base + "/collector-diagnostics.json"
        self.fixture_state = args.fixture_state
        self.pid = 0
        self.host_hash = executable_hash(args.app)
        self.folded = None
        self.unmanaged = None
        self.quit_helper = self.base + "/tools/GuestCollectorQuit"

    def save(self, status, error=None):
        value = {"status": status, "timestamp": time.time(), "vm": self.args.vm,
                 "checks": self.checks, "app": str(self.args.app), "guestApp": self.collector,
                 "executableSHA256": self.host_hash,
                 "method": "shipping app; real external Guest VNC; independent AX/CGWindow; fresh original fixture NSMenu callbacks",
                 "collectorVerificationCommands": False,
                 "limitations": ["Independent VirtualMac runtime acceptance covers this native fixture and one Guest display; host private application/account state is untouched"]}
        if error: value["error"] = str(error)
        (self.artifacts / "summary.json").write_text(json.dumps(value, indent=2, ensure_ascii=False))

    def ensure(self, condition, name, evidence=None):
        self.checks.append({"name": name, "passed": bool(condition), "evidence": evidence or {}})
        self.save("running")
        if not condition: raise VerificationError(name)
        print("PASS:", name, flush=True)

    def wait(self, probe, predicate, name, timeout=None):
        deadline = time.monotonic() + (timeout or self.args.timeout)
        last = None
        while time.monotonic() < deadline:
            last = probe()
            if predicate(last): return last
            time.sleep(.25)
        raise VerificationError(f"{name}: deadline expired; last={str(last)[:900]}")

    def snapshot(self, name="production-native"):
        return self.observer.snapshot(name)

    def panel_or_none(self, value):
        try: return actual_panel(value)
        except RuntimeError as exc:
            # Native shelf has no frame during the brief initial layout turn.
            if "panel count is 0" in str(exc): return None
            raise

    def source_positions(self, snapshot):
        return source_positions(snapshot, self.args.count)

    def fixture(self):
        value = self.guest.read_json(self.fixture_state)
        if not value: raise VerificationError("Original fixture native receipt missing")
        return value

    def assert_hash(self, phase):
        actual = self.guest.bundle_hash(self.collector, executable(self.args.app).name)
        self.ensure(actual == self.host_hash, "Shipping Guest executable matches current Host SHA256: " + phase,
                    {"expected": self.host_hash, "actual": actual})

    def entry(self, snapshot):
        nodes = native_app(snapshot, COLLECTOR_BUNDLE)["nodes"]
        candidates = [node for node in nodes if node.get("role") in {"AXMenuBarItem", "AXButton"}
                      and label(node) in {"MacMenuY", "MacMenuY 收纳入口"}
                      and node.get("intersectsDisplay") and node.get("frame", {}).get("y", 99999) < 40]
        unique = {json.dumps(node["frame"], sort_keys=True): node for node in candidates}
        if len(unique) != 1:
            raise VerificationError(f"Original native collection entry missing/ambiguous: {list(unique.values())}")
        return next(iter(unique.values()))

    def hover_open(self):
        before = self.snapshot("hover-before")
        x, y = center(self.entry(before))
        self.input.send("move", x=x, y=y)
        shown = self.wait(lambda: self.snapshot("hover-open"), lambda value: self.panel_or_none(value) is not None, "Native shipping hover did not open shelf")
        panel = actual_panel(shown)
        # Cross into actual panel, which must retain visibility through normal hover.
        self.input.send("move", x=panel["frame"]["x"] + panel["frame"]["width"] / 2,
                        y=panel["frame"]["y"] + min(20, panel["frame"]["height"] / 2))
        time.sleep(.25)
        stayed = self.snapshot("hover-stay")
        self.ensure(actual_panel(stayed) is not None, "Shipping shelf remains open while real pointer enters native panel")
        return stayed

    def close_by_leaving(self):
        before = self.snapshot("hover-leave-before")
        display = before["display"]
        self.input.send("move", x=display["x"] + display["width"] * .55,
                        y=display["y"] + display["height"] * .7)
        return self.wait(lambda: self.snapshot("hover-leave"), lambda value: self.panel_or_none(value) is None, "Shipping shelf failed to collapse after real pointer leave")

    def click_label(self, text, exact=True):
        observed = self.snapshot("before-button")
        node = find_button(observed, text, exact=exact)
        self.input.click_node(node)
        return node

    def search(self, query):
        current = self.hover_open()
        fields = [node for node in native_app(current, COLLECTOR_BUNDLE)["nodes"]
                  if node.get("AXIdentifier") == "menuy-search" and node.get("intersectsDisplay")]
        self.ensure(len(fields) == 1, "Shipping native NSSearchField has an actual visible AX frame", {"fields": fields})
        self.input.click_node(fields[0])
        self.input.send("key", key="a", modifiers=["command"])
        self.input.send("key", key="BackSpace", modifiers=[])
        if query: self.input.send("text", text=query)
        expected = 1 if query else self.args.count
        result = self.wait(lambda: self.snapshot("actual-search"), lambda value:
                           len([node for node in native_buttons(value) if fixture_index(node)]) == expected,
                           "Shipping real keyboard search produced wrong fixture button count")
        self.ensure(actual_panel(result) is not None, "Shipping search retains actual native panel")
        return result

    def fixture_button(self, snapshot, index, editing=False):
        nodes = [node for node in native_buttons(snapshot, editing=editing) if fixture_index(node) == index]
        if len(nodes) != 1:
            raise VerificationError(f"Expected one independently rendered original fixture {index} button; got {nodes}")
        return nodes[0]

    def menu(self, index, button, modifiers, select=True):
        current = self.search("")
        target = self.fixture_button(current, index)
        before = self.fixture()
        source_pid, offset = before["pid"], len(before.get("opens", []))
        started = float(self.guest.exec(["/usr/bin/python3", "-c", "import time;print(time.time())"]))
        receipt = self.input.click_node(target, button, modifiers)
        actual = self.wait(self.fixture, lambda value: value.get("pid") == source_pid and
            any(event.get("menuOpened") == index and event.get("timestamp", 0) >= started for event in value.get("opens", [])[offset:]),
            "Shipping external InputView click did not open original native menu", timeout=10)
        events = [event for event in actual.get("opens", [])[offset:] if event.get("timestamp", 0) >= started]
        click = next((event for event in events if event.get("index") == index and "button" in event), None)
        self.ensure(click is not None and click.get("button") == button and exact_modifiers(click.get("modifiers", []), modifiers),
                    "Shipping real " + button + " input preserves exact original modifiers",
                    {"input": receipt, "events": events, "expectedModifiers": modifiers})
        original = self.snapshot("shipping-original-menu-open")
        menus = [node for node in native_app(original, FIXTURE_BUNDLE)["nodes"] if node.get("role") == "AXMenu" and node.get("intersectsDisplay")]
        self.ensure(bool(menus), "Independent source AX proves actual shipping original native menu is visible", {"menus": menus})
        self.input.screenshot(f"original-{button}-{'option' if modifiers else 'plain'}-menu.png")
        if select:
            self.input.send("key", key="Down", modifiers=[])
            self.input.send("key", key="Return", modifiers=[])
            self.wait(self.fixture, lambda value: any(event.get("selection") == index and event.get("timestamp", 0) >= started for event in value.get("opens", [])[offset:]), "External original NSMenu selection callback missing", timeout=8)
            self.wait(self.fixture, lambda value: index not in value.get("openMenus", []), "Selected original native menu failed to close")
            returned = self.wait(lambda: self.source_positions(self.snapshot("post-shipping-menu-return")),
                                 lambda value: positions_restored(self.folded, value), "Shipping native source frame / neighboring order not restored")
            self.ensure(positions_restored(self.folded, returned), "Shipping selected original menu restores independent source frames and order")

    def pin(self, value):
        current = self.search("")
        self.input.click_node(find_button(current, "整理图标"))
        edited = self.wait(lambda: self.snapshot("pin-editing"), lambda snapshot: bool(native_buttons(snapshot, editing=True)), "Real pin editing toggle failed")
        target = self.fixture_button(edited, self.args.count, editing=True)
        self.ensure(label(target).startswith("固定 " if value else "收回 "), "Native pin toggle advertises actual source state", {"target": target})
        before = self.source_positions(edited)
        self.input.click_node(target)
        after = self.wait(lambda: self.source_positions(self.snapshot("pin-native-after")), lambda result:
            (not frames_close(before[self.args.count]["frame"], result[self.args.count]["frame"])) and
            (result[self.args.count].get("intersectsDisplay") if value else positions_restored(self.folded, result)),
            "Real shipping pin toggle did not move the original source")
        self.ensure(after[self.args.count].get("intersectsDisplay") is True if value else positions_restored(self.folded, after),
                    "Shipping real pin " + ("returns source to formal menubar" if value else "restores source to folded native position"),
                    {"before": before[self.args.count], "after": after[self.args.count]})
        self.click_label("整理图标")

    def install_quit_helper(self):
        host = self.args.quit_helper or self.artifacts / "GuestCollectorQuit"
        if self.args.quit_helper is None:
            source = WORKSPACE / "Tests/GuestCollectorQuit.swift"
            result = subprocess.run(["xcrun", "swiftc", str(source), "-o", str(host)], capture_output=True, timeout=90)
            if result.returncode:
                raise VerificationError(f"Guest public Quit helper compile failed: {result.stderr.decode(errors='replace')[-1200:]}")
        data = host.read_bytes()
        self.guest.write(self.quit_helper, data)
        self.guest.exec(["/bin/chmod", "755", self.quit_helper])
        guest_hash = self.guest.exec(["/usr/bin/shasum", "-a", "256", self.quit_helper]).decode().split()[0]
        self.ensure(guest_hash == hashlib.sha256(data).hexdigest(), "Public Guest Quit helper executable SHA256 verified")

    def launch(self):
        model = self.guest.verify_guest()
        self.ensure(model.lower().startswith("virtualmac"), "Production acceptance runs only in isolated VirtualMac", {"model": model})
        self.observer.install()
        self.install_quit_helper()
        before = self.snapshot("production-before-install")
        running = [value for value in before.get("apps", []) if value.get("bundle") == COLLECTOR_BUNDLE]
        self.ensure(not running, "Previous collector fully stopped before installing shipping bundle", {"running": running})
        original_fixture = native_app(before, FIXTURE_BUNDLE)
        fixture_receipt = self.fixture()
        self.ensure(fixture_receipt.get("pid") == original_fixture["pid"] and fixture_receipt.get("count") == self.args.count,
                    "Production uses one actual independent native fixture process", {"fixture": fixture_receipt})
        fixture_hash = self.guest.bundle_hash(original_fixture["bundlePath"], executable(self.args.host_fixture).name)
        self.ensure(fixture_hash == executable_hash(self.args.host_fixture), "Production fixture executable matches current Host SHA256")
        self.unmanaged = self.source_positions(before)
        # Inspect the shipping artifact without executing anything on the Host.
        strings = subprocess.run(["/usr/bin/strings", str(executable(self.args.app))], capture_output=True, check=True).stdout
        self.ensure(b"MenuYVerificationCommands" not in strings and b"verification-command-file" not in strings,
                    "Current shipping executable omits collector verification command surface")
        self.collector = self.guest.copy_bundle(self.args.app, self.base + "/apps")
        self.guest.exec(["/bin/mkdir", "-p", self.base + "/evidence"])
        self.guest.exec(["/bin/rm", "-f", self.diagnostics, self.diagnostics + ".exit.json"])
        self.assert_hash("before-fresh-launch")
        argv = ["/usr/bin/open", self.collector, "--args", "--diagnostics-path", self.diagnostics]
        self.guest.exec(argv)
        ready = self.wait(lambda: self.snapshot("shipping-fresh-launch"), lambda value:
            any(candidate.get("bundle") == COLLECTOR_BUNDLE for candidate in value.get("apps", [])), "Shipping Guest app did not launch")
        self.pid = native_app(ready, COLLECTOR_BUNDLE)["pid"]
        self.assert_hash("after-fresh-launch")
        if self.args.prepare_only:
            self.save("prepared")
            return
        self.wait(lambda: self.guest.read_json(self.diagnostics), lambda value: value and value.get("pid") == self.pid and
            value.get("accessibility") and value.get("screenCapture") and not value.get("busy"), "Shipping app needs normal Guest native permissions and completed setup")
        # This movement is observed, never inferred from enabled=true.
        self.folded = self.wait(lambda: self.source_positions(self.snapshot("shipping-source-folded")),
            lambda positions: not positions_restored(self.unmanaged, positions), "Shipping app did not actually fold native source positions")
        self.ensure(source_order(self.folded) == source_order(self.unmanaged), "Shipping startup preserves independent original source neighbor order")

    def quit(self, baseline, active_menu=False):
        if active_menu:
            self.ensure(self.args.count in self.fixture().get("openMenus", []), "Original menu remains genuinely active at standard shipping Quit request")
            # Public native termination enters the shipping normal Quit handler.
            # An entry context-menu click would close the source popup beforehand.
            request = json.loads(self.guest.exec([self.quit_helper, "--bundle-path", self.collector], timeout=16))
            self.ensure(request.get("accepted") is True and request.get("pid") == self.pid and request.get("model", "").lower().startswith("virtualmac"),
                        "Public native Quit request accepted for exact active-menu Guest collector", request)
        else:
            current = self.hover_open()
            self.input.click_node(find_button(current, "退出 MacMenuY"))
            self.ensure(True, "External real shipping Quit button clicked", {"request": "native AX button frame through Guest VNC"})
        self.wait(lambda: self.guest.process_running(self.pid), lambda running: not running, "Shipping process failed normal quit", timeout=12)
        report = self.wait(lambda: self.guest.read_json(self.diagnostics + ".exit.json"), lambda value: value is not None, "Shipping final native cleanup receipt missing")
        self.ensure(report.get("remaining") == [] and report.get("journalPending", -1) == 0 and report.get("journalSaved") is True,
                    "Shipping normal quit reports no remaining temporary moves or saved journal backlog", report)
        after = self.source_positions(self.snapshot("shipping-independent-after-quit"))
        self.ensure(relative_positions_restored(baseline, after), "Shipping quit independently restores original source frames and all neighbor distances",
                    {"before": baseline, "after": after, "beforeOrder": source_order(baseline), "afterOrder": source_order(after)})
        self.assert_hash("after-normal-stop")
        self.ensure(self.args.count not in self.fixture().get("openMenus", []), "Shipping quit closes its own genuinely active original menu")

    def run(self):
        try:
            self.launch()
            if self.args.prepare_only:
                return
            focus = self.snapshot("focus-before-hover")["frontmostBundle"]
            shown = self.hover_open()
            self.ensure(shown["frontmostBundle"] == focus, "Shipping real hover preserves work application focus")
            panel = actual_panel(shown)
            positions = self.source_positions(shown)
            menu_height = max(value["frame"]["y"] + value["frame"]["height"] for value in positions.values())
            self.ensure(panel["frame"]["y"] >= menu_height - 1 and abs(panel.get("alpha", -1) - .9) <= .01,
                        "Independent shipping full-width native shelf stays below formal bar at 90% opacity", {"panel": panel, "menuHeight": menu_height})
            self.ensure(no_cover_windows(shown, menu_height) == [], "Independent WindowServer proves shipping app creates no cover over formal menubar")
            rendered = [node for node in native_buttons(shown) if fixture_index(node)]
            self.ensure(len(rendered) == self.args.count and {fixture_index(node) for node in rendered} == set(range(1, self.args.count + 1)),
                        "Every original fixture has a real rendered enabled shipping AX input button", {"buttons": rendered})
            self.input.screenshot("shipping-native-expanded.png")
            collapsed = self.close_by_leaving()
            self.ensure(self.panel_or_none(collapsed) is None, "Shipping real pointer leave collapses the native shelf")
            self.search(f"Fixture-{self.args.count}")
            self.ensure(len(native_buttons(self.snapshot("shipping-one-search-result"))) == 1, "Shipping external keyboard search renders exactly one native item button")
            self.menu(self.args.count, "left", [], True)
            self.menu(self.args.count, "right", [], True)
            self.menu(self.args.count, "left", ["option"], True)
            self.pin(True)
            self.pin(False)
            current = self.search("")
            self.input.click_node(find_button(current, "停用收纳"))
            unfolded = self.wait(lambda: self.source_positions(self.snapshot("shipping-disabled")), lambda positions:
                                 relative_positions_restored(self.unmanaged, positions), "Shipping Disable button did not actually unfold sources")
            self.ensure(not positions_restored(self.folded, unfolded), "Shipping Disable changes actual original native frames")
            current = self.hover_open()
            self.input.click_node(find_button(current, "启用收纳"))
            refolded = self.wait(lambda: self.source_positions(self.snapshot("shipping-reenabled")), lambda positions:
                                 positions_restored(self.folded, positions), "Shipping Enable button did not restore folded source frames")
            self.ensure(positions_restored(self.folded, refolded), "Shipping Enable independently restores original folded native frame/order")
            self.quit(self.unmanaged)
            self.launch()
            self.menu(self.args.count, "right", [], False)
            self.ensure(self.args.count in self.fixture().get("openMenus", []), "Shipping termination starts with original right-click menu genuinely active")
            self.quit(self.unmanaged, active_menu=True)
            self.save("passed")
        except Exception as exc:
            self.save("failed", exc)
            raise


def self_test():
    assert not exact_modifiers(["option", "command"], ["option"])
    before = {1: {"frame": {"x": -40, "y": 0, "width": 20, "height": 24}}, 2: {"frame": {"x": -20, "y": 0, "width": 20, "height": 24}}}
    translated = {1: {"frame": {"x": 60, "y": 0, "width": 20, "height": 24}}, 2: {"frame": {"x": 80, "y": 0, "width": 20, "height": 24}}}
    assert relative_positions_restored(before, translated)
    translated[2]["frame"]["x"] = 120
    assert not relative_positions_restored(before, translated)
    print("PASS: shipping gate rejects extra modifiers and displaced native neighbor distances; no Guest contacted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vm", default=os.environ.get("MENUY_VM_NAME", "menuy-tahoe"))
    parser.add_argument("--tart", default="tart")
    parser.add_argument("--tart-home", type=Path, default=WORKSPACE / "artifacts/vm/tart-home")
    parser.add_argument("--app", type=Path, default=WORKSPACE / "build/Production/Build/Products/Release/MacMenuY.app")
    parser.add_argument("--host-fixture", type=Path, default=WORKSPACE / "build/native-interaction/MenuYFixture.app")
    parser.add_argument("--fixture-state", default="/tmp/macmenuy-verify/fixture-state.json")
    parser.add_argument("--guest-dir", default="/tmp/macmenuy-production")
    parser.add_argument("--observer-guest-dir", default="/tmp/macmenuy-verify", help="Reuse observer's authorized Guest executable path")
    parser.add_argument("--quit-helper", type=Path, help="Host precompiled public GuestCollectorQuit; otherwise Host compile only")
    parser.add_argument("--observer", type=Path, help="Host precompiled read-only GuestNativeObserver binary")
    parser.add_argument("--input-driver", type=Path)
    parser.add_argument("--artifacts", type=Path, default=WORKSPACE / "artifacts/isolated-production")
    parser.add_argument("--count", type=int, default=32)
    parser.add_argument("--timeout", type=float, default=25)
    parser.add_argument("--prepare-only", action="store_true", help="Fresh install/launch in Guest for normal production permission flow; no runtime pass or input")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test(); return 0
    if not args.input_driver: parser.error("--input-driver is required: production acceptance must use real external native input")
    if not args.guest_dir.startswith("/tmp/") or not args.observer_guest_dir.startswith("/tmp/"): parser.error("Guest paths must remain inside the private /tmp namespace")
    if not 1 <= args.count <= 1000: parser.error("count must be 1..1000")
    try: ProductionSuite(args).run()
    except (RuntimeError, VerificationError) as exc:
        print("FAIL:", exc, flush=True); return 1
    print("Shipping Guest application prepared for normal OS permission flow; no runtime pass" if args.prepare_only else "Shipping isolated native acceptance passed; see " + str(args.artifacts / "summary.json"), flush=True)
    return 0


if __name__ == "__main__": raise SystemExit(main())
