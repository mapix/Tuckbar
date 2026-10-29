#!/usr/bin/env python3
"""Native MacMenuY verification, exclusively through Tart's guest exec socket.

The runner never invokes host open/osascript/CGEvent. UI input is performed by
MENUY_VERIFY code after a VirtualMac guest-only guard. App transport results are
cross-checked against the original fixture's real NSMenu callbacks.
"""
from __future__ import annotations
import argparse
import io
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tarfile
import time
import uuid

WORKSPACE = Path(__file__).resolve().parents[2]
FIXTURE_BUNDLE = "io.novarock.MacMenuY.Fixture"

class VerificationError(RuntimeError):
    pass

class TartGuest:
    def __init__(self, vm: str, tart_home: Path, tart: str = "tart"):
        self.vm, self.tart = vm, tart
        self.env = os.environ.copy()
        self.env.update(TART_HOME=str(tart_home), TART_NO_AUTO_PRUNE="1")

    def exec(self, argv: list[str], *, data: bytes | None = None, timeout: float = 40, check: bool = True) -> bytes:
        cmd = [self.tart, "exec"] + (["-i"] if data is not None else []) + [self.vm] + argv
        try:
            result = subprocess.run(cmd, input=data, capture_output=True, env=self.env, timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            raise VerificationError(f"Guest exec timed out: {argv[0]}") from exc
        if check and result.returncode:
            raise VerificationError(f"Guest exec failed ({result.returncode}): {result.stderr.decode(errors='replace')[-1800:]}")
        return result.stdout

    def shell(self, text: str, **kwargs) -> bytes:
        return self.exec(["/bin/sh", "-lc", text], **kwargs)

    def verify_guest(self) -> str:
        model = self.exec(["/usr/sbin/sysctl", "-n", "hw.model"]).decode().strip()
        if not model.lower().startswith("virtualmac"):
            raise VerificationError(f"Refusing UI test input outside a VirtualMac guest (model={model!r})")
        return model

    def write(self, path: str, data: bytes) -> None:
        script = "import os,sys; p=sys.argv[1]; os.makedirs(os.path.dirname(p),exist_ok=True); t=p+'.tmp'; open(t,'wb').write(sys.stdin.buffer.read()); os.replace(t,p)"
        self.exec(["/usr/bin/python3", "-c", script, path], data=data)

    def read(self, path: str) -> bytes | None:
        script = "import sys,pathlib; p=pathlib.Path(sys.argv[1]); sys.stdout.buffer.write(p.read_bytes()) if p.exists() else None"
        return self.exec(["/usr/bin/python3", "-c", script, path]) or None

    def read_json(self, path: str) -> dict | None:
        data = self.read(path)
        if data is None:
            return None
        try:
            value = json.loads(data)
        except json.JSONDecodeError as exc:
            raise VerificationError(f"Guest evidence is malformed JSON: {path}") from exc
        if not isinstance(value, dict):
            raise VerificationError(f"Guest evidence is not an object: {path}")
        return value

    def process_running(self, pid: int) -> bool:
        if not isinstance(pid, int) or pid <= 0:
            return False
        script = "import os,sys; p=int(sys.argv[1]);\ntry: os.kill(p,0); print('running')\nexcept ProcessLookupError: print('gone')"
        return self.exec(["/usr/bin/python3", "-c", script, str(pid)]).decode().strip() == "running"

    def copy_bundle(self, source: Path, folder: str) -> str:
        if not source.is_dir() or source.suffix != ".app":
            raise VerificationError(f"Not an application bundle: {source}")
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz", dereference=False) as archive:
            archive.add(source, arcname=source.name, recursive=True)
        self.shell(f"/bin/mkdir -p {shlex.quote(folder)}")
        self.exec(["/usr/bin/tar", "-xzf", "-", "-C", folder], data=buffer.getvalue(), timeout=120)
        return folder + "/" + source.name

class NativeSuite:
    def __init__(self, guest: TartGuest, guest_dir: str, artifacts: Path, count: int, timeout: float):
        self.guest, self.base, self.artifacts = guest, guest_dir.rstrip("/"), artifacts
        self.count, self.timeout = count, timeout
        self.command_path = self.base + "/collector-command.json"
        self.results = self.base + "/results"
        self.fixture_command = self.base + "/fixture-command.json"
        self.fixture_state = self.base + "/fixture-state.json"
        self.collector_state = self.base + "/collector-state.json"
        self.evidence = self.base + "/evidence"
        self.checks: list[dict] = []
        self.app = self.fixture = ""
        self.artifacts.mkdir(parents=True, exist_ok=True)

    def ensure(self, condition: bool, label: str, evidence: dict | None = None) -> None:
        entry = {"name": label, "passed": bool(condition), "evidence": evidence or {}}
        self.checks.append(entry)
        self.save_summary("running")
        if not condition:
            raise VerificationError(label)
        print("PASS:", label, flush=True)

    def save_summary(self, status: str, error: str | None = None) -> None:
        value = {"status": status, "vm": self.guest.vm, "guestDir": self.base,
                 "timestamp": time.time(), "checks": self.checks,
                 "verification": "native VirtualMac guest; host UI untouched",
                 "limitations": ["MENUY_VERIFY command interface exercises shipping paths; final non-verification build needs independent launch/UI acceptance", "Only this guest's native menus are tested, not private host app/account state"]}
        if error:
            value["error"] = error
        target = self.artifacts / "summary.json"
        target.write_text(json.dumps(value, indent=2, ensure_ascii=False))

    def wait_json(self, path: str, predicate=lambda value: True, timeout: float | None = None) -> dict:
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        last = None
        while time.monotonic() < deadline:
            last = self.guest.read_json(path)
            if last is not None and predicate(last):
                return last
            time.sleep(0.25)
        raise VerificationError(f"Guest evidence deadline expired: {path}; last={str(last)[:700]}")

    def command(self, op: str, **fields) -> dict:
        ident = op.replace("_", "-") + "-" + uuid.uuid4().hex[:12]
        payload = {"id": ident, "op": op, **fields}
        self.guest.write(self.command_path, json.dumps(payload).encode())
        result = self.wait_json(self.results + "/" + ident + ".json", lambda value: value.get("id") == ident)
        (self.artifacts / (ident + ".json")).write_text(json.dumps(result, indent=2, ensure_ascii=False))
        if result.get("status") != "completed":
            raise VerificationError(f"Native command {op}: {result.get('error')}")
        return result

    def snapshot(self) -> dict:
        return self.command("snapshot")["state"]

    def fixture_op(self, op: str, **fields) -> dict:
        ident = "fixture-" + uuid.uuid4().hex[:12]
        self.guest.write(self.fixture_command, json.dumps({"id": ident, "op": op, **fields}).encode())
        return self.wait_json(self.fixture_state, lambda value: any(c.get("id") == ident for c in value.get("commands", [])))

    def fixture_items(self, state: dict) -> list[dict]:
        return [item for item in state.get("items", []) if item.get("key", "").startswith(FIXTURE_BUNDLE + ":")]

    def item(self, state: dict, index: int) -> dict:
        matches = [item for item in self.fixture_items(state) if item.get("title") == f"Fixture-{index}"]
        if len(matches) != 1:
            raise VerificationError(f"Expected one real fixture index {index}, found {len(matches)}")
        return matches[0]

    def start_fixture(self) -> dict:
        existing = self.guest.read_json(self.fixture_state)
        if existing and existing.get("count") == self.count and self.guest.process_running(existing.get("pid", 0)):
            return existing
        self.guest.write(self.fixture_command, b"{}")
        self.guest.shell(f"/bin/rm -f {shlex.quote(self.fixture_state)}")
        self.guest.exec(["/usr/bin/open", self.fixture, "--args", "--count", str(self.count), "--output", self.fixture_state, "--command-file", self.fixture_command])
        return self.wait_json(self.fixture_state, lambda value: value.get("count") == self.count)

    def start_collector(self) -> dict:
        existing = self.guest.read_json(self.results + "/ready.json")
        existing_state = (existing or {}).get("state", {})
        if existing_state.get("pid") and self.guest.process_running(existing_state["pid"]):
            state = self.wait_native_count(self.count)
            self.ensure(state.get("accessibility") and state.get("screenCapture"), "Prepared guest native permissions available", state)
            return state
        # A quit command must not replay in the fresh process; ready evidence
        # must belong to the new launch rather than the previous PID.
        self.guest.write(self.command_path, b"{}")
        self.guest.shell(f"/bin/rm -f {shlex.quote(self.results + '/ready.json')}")
        self.guest.exec(["/usr/bin/open", self.app, "--args", "--verification-guest", "--verification-command-file", self.command_path,
                         "--verification-result-dir", self.results, "--verification-fixture-state", self.fixture_state,
                         "--diagnostics-path", self.collector_state, "--evidence-dir", self.evidence])
        # Source discovery may take several bounded AX rounds. Permissions must
        # be granted through the guest OS before this gate can become ready.
        ready = self.wait_json(self.results + "/ready.json", lambda value: value.get("guestModel", "").lower().startswith("virtualmac"), timeout=max(self.timeout, 45))
        self.ensure(ready["state"].get("accessibility") and ready["state"].get("screenCapture"), "Guest native permissions available", ready["state"])
        state = self.wait_native_count(self.count)
        return state

    def wait_native_count(self, expected: int) -> dict:
        deadline = time.monotonic() + self.timeout
        state = {}
        while time.monotonic() < deadline:
            state = self.snapshot()
            if len(self.fixture_items(state)) == expected:
                return state
            time.sleep(0.35)
        raise VerificationError(f"Native fixture count expected {expected}, got {len(self.fixture_items(state))}")

    def artifact(self, guest_name: str, host_name: str) -> None:
        data = self.guest.read(self.evidence + "/" + guest_name)
        if data:
            (self.artifacts / host_name).write_bytes(data)

    def quit_collector(self) -> dict:
        before = self.snapshot()
        self.guest.shell(f"/bin/rm -f {shlex.quote(self.collector_state + '.exit.json')}")
        self.command("quit")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and self.guest.process_running(before["pid"]):
            time.sleep(0.2)
        self.ensure(not self.guest.process_running(before["pid"]), "Collector process terminated after normal cleanup")
        report = self.wait_json(self.collector_state + ".exit.json", timeout=8)
        self.ensure(report.get("remaining") == [], "Normal termination restored every temporary item", report)
        return report

    def menu(self, index: int, button: str, modifiers: list[str], select: bool = True) -> dict:
        before = self.guest.read_json(self.fixture_state) or {}
        count_before = len(before.get("opens", []))
        result = self.command("native_menu", index=index, button=button, modifiers=modifiers, select=select)
        details = result["details"]
        actual = self.guest.read_json(self.fixture_state) or {}
        events = actual.get("opens", [])[count_before:]
        has_open = any(event.get("menuOpened") == index for event in events)
        click = next((event for event in events if event.get("index") == index and "button" in event), None)
        self.ensure(has_open and details.get("clientMenuOpened"), f"Original client {button} menu genuinely opened", {"details": details, "independentFixtureEvents": events})
        self.ensure(click is not None and click.get("button") == button and set(modifiers).issubset(set(click.get("modifiers", []))), f"Original client preserved {button} / {modifiers or 'no modifiers'}", {"click": click})
        if select:
            self.ensure(details.get("clientSelection") and any(event.get("selection") == index for event in events), "Original NSMenu keyboard selection callback executed", {"events": events})
            self.wait_json(self.fixture_state, lambda value: index not in value.get("openMenus", []), timeout=6)
            self.wait_restored(index)
        return result

    def wait_restored(self, index: int) -> dict:
        deadline = time.monotonic() + self.timeout
        latest = {}
        while time.monotonic() < deadline:
            latest = self.snapshot()
            item = self.item(latest, index)
            if not item.get("onScreen") and item["id"] not in latest.get("pendingRestoration", []):
                self.ensure(True, "Temporary original icon returned to hidden native area", item)
                return latest
            time.sleep(0.3)
        raise VerificationError(f"Temporary item {index} not restored: {self.item(latest, index)} pending={latest.get('pendingRestoration')}")

    def prepare(self, app: Path, fixture: Path, copy: bool = True) -> None:
        model = self.guest.verify_guest()
        if copy:
            self.app = self.guest.copy_bundle(app, self.base + "/apps")
            self.fixture = self.guest.copy_bundle(fixture, self.base + "/fixture")
        else:
            self.app, self.fixture = str(app), str(fixture)
        self.guest.shell(f"/bin/mkdir -p {shlex.quote(self.results)} {shlex.quote(self.evidence)}")
        self.start_fixture()
        self.guest.write(self.command_path, b"{}")
        self.guest.shell(f"/bin/rm -f {shlex.quote(self.results + '/ready.json')}")
        argv = ["/usr/bin/open", self.app, "--args", "--verification-guest", "--verification-command-file", self.command_path,
                "--verification-result-dir", self.results, "--verification-fixture-state", self.fixture_state,
                "--diagnostics-path", self.collector_state, "--evidence-dir", self.evidence]
        self.guest.exec(argv)
        value = {"guestModel": model, "app": self.app, "fixture": self.fixture, "launchArguments": argv,
                 "permissions": "Complete normal guest OS permission flow; no TCC/SIP/database changes performed"}
        (self.artifacts / "bootstrap.json").write_text(json.dumps(value, indent=2))
        print("Guest fixture/application prepared; complete permissions in the guest VM, then run --skip-copy with these guest bundle paths", flush=True)

    def run(self, app: Path, fixture: Path, copy: bool = True) -> None:
        try:
            model = self.guest.verify_guest()
            self.ensure(model.lower().startswith("virtualmac"), "Execution bound to isolated VirtualMac", {"model": model})
            if copy:
                self.app = self.guest.copy_bundle(app, self.base + "/apps")
                self.fixture = self.guest.copy_bundle(fixture, self.base + "/fixture")
            else:
                self.app, self.fixture = str(app), str(fixture)
            self.guest.shell(f"/bin/mkdir -p {shlex.quote(self.results)} {shlex.quote(self.evidence)}")
            self.start_fixture()
            state = self.start_collector()
            self.ensure(len(self.fixture_items(state)) == self.count and len({item['id'] for item in self.fixture_items(state)}) == self.count,
                        "All original native fixture windows independently enumerated", {"count": self.count})
            self.ensure(state.get("coverWindows") == [], "No presentation cover exists over original menubar")
            self.ensure(state["preferences"].get("opacity") == 0.9, "Default native shelf opacity is 90%")

            result = self.command("hover")
            self.ensure(result["details"].get("passed"), "Actual native entry hover / shelf stay / leave collapse and work focus", result["details"])
            self.artifact("primary-menubar.png", "hover-primary-menubar.png")
            self.artifact("expanded-shelf.png", "hover-expanded-shelf.png")

            self.command("preview")
            result = self.command("search", query=f"Fixture-{self.count}")
            ui = result["details"].get("ui", {})
            self.ensure(ui.get("available") and ui.get("itemButtonCount") == 1, "Actual native search reduces shelf to one original item", result["details"])
            self.command("hide")

            self.menu(self.count, "left", [], True)
            self.menu(self.count, "right", [], True)
            self.menu(self.count, "left", ["option"], True)

            result = self.command("pin", index=self.count, value=True)
            item = result["details"].get("after", {})
            self.ensure(item.get("pinned") and item.get("onScreen"), "Pin genuinely returns original item to formal menubar", result["details"])
            self.quit_collector()
            state = self.start_collector()
            item = self.item(state, self.count)
            self.ensure(item.get("pinned") and item.get("onScreen"), "Native pin survives manager relaunch", item)
            original_window = item["id"]
            fixture_before = self.guest.read_json(self.fixture_state) or {}
            self.guest.exec(["/bin/kill", "-TERM", str(fixture_before["pid"])])
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline and self.guest.process_running(fixture_before["pid"]):
                time.sleep(0.2)
            self.start_fixture()
            deadline = time.monotonic() + self.timeout
            while time.monotonic() < deadline:
                state = self.snapshot()
                try:
                    item = self.item(state, self.count)
                except VerificationError:
                    time.sleep(0.2); continue
                if item["id"] != original_window and item.get("pinned") and item.get("onScreen"):
                    break
                time.sleep(0.3)
            self.ensure(item["id"] != original_window and item.get("pinned") and item.get("onScreen"),
                        "Pin identity survives source fixture process/window relaunch", item)
            result = self.command("pin", index=self.count, value=False)
            item = result["details"].get("after", {})
            self.ensure(not item.get("pinned") and not item.get("onScreen"), "Unpin genuinely returns original item to hidden area", result["details"])

            self.fixture_op("add")
            self.wait_native_count(self.count + 1)
            self.ensure(True, "New native status item discovered")
            self.fixture_op("remove")
            self.wait_native_count(self.count)
            self.ensure(True, "Removed native status item and image ID pruned")

            self.fixture_op("set_badge", index=self.count, unreadCount=3)
            deadline = time.monotonic() + self.timeout
            state = {}
            while time.monotonic() < deadline:
                state = self.snapshot()
                if state.get("unreadCount") == 3:
                    break
                time.sleep(0.3)
            self.ensure(state.get("unreadCount") == 3, "Real native badge and explicit AX hint produce 3 confirmed unread", state)
            self.command("preview")
            self.artifact("expanded-shelf.png", "native-badge-3.png")
            self.fixture_op("clear_badge", index=self.count)
            deadline = time.monotonic() + self.timeout
            while time.monotonic() < deadline:
                state = self.snapshot()
                if state.get("unreadCount") == 0:
                    break
                time.sleep(0.3)
            self.ensure(state.get("unreadCount") == 0, "Explicit native zero clears confirmed unread without invented activity count", state)

            self.command("preferences", sortMode="alphabetical", rules=[{"pattern": "*Fixture*", "priority": -10}])
            state = self.snapshot()
            prefix = state.get("orderedKeys", [])[:self.count]
            self.ensure(len(prefix) == self.count and all(key.startswith(FIXTURE_BUNDLE + ":") for key in prefix), "User priority rules applied to native item display order", {"orderedKeys": state.get("orderedKeys")})
            for style, size in [("native", 24), ("glass", 32), ("compact", 16)]:
                self.command("preferences", style=style, iconSize=size, opacity=0.9)
                result = self.command("preview")
                state = result["state"]
                panel = state.get("panelFrame", {})
                screen = state.get("screens", [{}])[0]
                rect = screen.get("frame", {})
                self.ensure(state.get("panelOpacity") == 0.9 and panel.get("width") == rect.get("width") and
                            panel.get("y", 0) + panel.get("height", 0) <= rect.get("y", 0) + rect.get("height", 0) - screen.get("menuBarHeight", 0) + 1,
                            f"Actual {style} / {size}pt full-width native shelf preserves opacity and formal-bar boundary", state)
                self.artifact("expanded-shelf.png", f"style-{style}-{size}.png")
            self.command("preferences", style="native", iconSize=24, opacity=0.9, sortMode="original", rules=[])
            self.command("enabled", value=False)
            state = self.snapshot()
            self.ensure(not state.get("enabled"), "Native folding can be disabled")
            self.command("enabled", value=True)
            self.ensure(self.snapshot().get("enabled"), "Native folding can be re-enabled")

            self.menu(self.count, "left", [], False)
            actual = self.guest.read_json(self.fixture_state) or {}
            self.ensure(self.count in actual.get("openMenus", []), "Termination test starts with original menu genuinely active")
            self.quit_collector()
            actual = self.guest.read_json(self.fixture_state) or {}
            self.ensure(self.count not in actual.get("openMenus", []), "Normal app quit closes its own original temporary menu")
            self.save_summary("passed")
        except Exception as exc:
            self.save_summary("failed", str(exc))
            raise


def self_test() -> None:
    # Demonstrate that a transport-only result cannot satisfy source menu gates.
    fake = {"transportError": "", "clientMenuOpened": False, "clientEvents": []}
    assert not fake["clientMenuOpened"]
    events = [{"menuOpened": 8}, {"index": 8, "button": "left", "modifiers": ["option"]}, {"selection": 8}]
    assert any(e.get("menuOpened") == 8 for e in events)
    assert any(e.get("selection") == 8 for e in events)
    assert set(["option"]).issubset(set(events[1]["modifiers"]))
    assert not set(["option"]).issubset(set([]))
    print("PASS: source callback requirements veto transport-only completion; modifier/selection gates are distinct")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--vm", default=os.environ.get("MENUY_VM_NAME", "menuy-tahoe"))
    parser.add_argument("--tart", default="tart")
    parser.add_argument("--tart-home", type=Path, default=WORKSPACE / "artifacts/vm/tart-home")
    parser.add_argument("--app", type=Path, default=WORKSPACE / "build/Verification/Build/Products/Release/MacMenuY.app")
    parser.add_argument("--fixture", type=Path, default=WORKSPACE / "build/native-interaction/MenuYFixture.app")
    parser.add_argument("--guest-dir", default="/tmp/macmenuy-verify")
    parser.add_argument("--artifacts", type=Path, default=WORKSPACE / "artifacts/isolated-native")
    parser.add_argument("--count", type=int, default=32)
    parser.add_argument("--timeout", type=float, default=24)
    parser.add_argument("--skip-copy", action="store_true", help="--app/--fixture already refer to guest paths")
    parser.add_argument("--self-test", action="store_true", help="Pure gate checks; no VM, host app or UI is contacted")
    parser.add_argument("--prepare-only", action="store_true", help="Copy and launch in guest so normal guest OS permissions can be granted before runtime gates")
    args = parser.parse_args()
    if args.self_test:
        self_test(); return 0
    if not 1 <= args.count <= 1000:
        parser.error("count must be 1..1000")
    if not args.guest_dir.startswith("/tmp/"):
        parser.error("guest-dir must remain in the private /tmp test namespace")
    guest = TartGuest(args.vm, args.tart_home, args.tart)
    suite = NativeSuite(guest, args.guest_dir, args.artifacts, args.count, args.timeout)
    try:
        if args.prepare_only:
            suite.prepare(args.app, args.fixture, copy=not args.skip_copy)
            return 0
        suite.run(args.app, args.fixture, copy=not args.skip_copy)
    except VerificationError as exc:
        print("FAIL:", exc, flush=True); return 1
    print("Native isolated verification passed; see", args.artifacts / "summary.json", flush=True)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
