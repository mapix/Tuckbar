#!/usr/bin/env python3
"""Native MacMenuY verification, exclusively through Tart's guest exec socket.

The runner never invokes host open/osascript/CGEvent. UI input is performed by an explicit external Guest VNC driver. MENUY_VERIFY
commands prepare state; original menu acceptance always clicks the real shelf
AX input view and checks independent fresh original-client NSMenu callbacks.
"""
from __future__ import annotations
import argparse
from collections import Counter
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
from native_evidence import (COLLECTOR_BUNDLE, ExternalInput, NativeObserver, app as native_app,
    actual_panel, center, exact_modifiers, executable, executable_hash, find_button,
    fixture_index, frames_close, native_buttons, no_cover_windows, positions_restored,
    source_order, source_positions, relative_positions_restored, PNG_SIGNATURE)

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

    def bundle_hash(self, bundle: str, name: str = "MacMenuY") -> str:
        path = bundle.rstrip("/") + "/Contents/MacOS/" + name
        return self.exec(["/usr/bin/shasum", "-a", "256", path]).decode().split()[0]

    def running_bundle_pids(self, bundle: str) -> list[int]:
        # ps inspects Guest process argv only; no host process or input API.
        script = "import subprocess,sys,json; prefix=sys.argv[1]+'/Contents/MacOS/'; rows=subprocess.check_output(['/bin/ps','-axo','pid=,command='],text=True).splitlines(); print(json.dumps([int(r.strip().split(None,1)[0]) for r in rows if len(r.strip().split(None,1))==2 and r.strip().split(None,1)[1].startswith(prefix)]))"
        return json.loads(self.exec(["/usr/bin/python3", "-c", script, bundle]))

    def copy_bundle(self, source: Path, folder: str) -> str:
        if not source.is_dir() or source.suffix != ".app":
            raise VerificationError(f"Not an application bundle: {source}")
        destination = folder + "/" + source.name
        running = self.running_bundle_pids(destination)
        if running:
            raise VerificationError(f"Refusing to overwrite a running Guest bundle {destination}: PIDs {running}; normal quit is required first")
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz", dereference=False) as archive:
            archive.add(source, arcname=source.name, recursive=True)
        staging = folder + "/.copy-" + uuid.uuid4().hex
        self.exec(["/bin/mkdir", "-p", staging])
        self.exec(["/usr/bin/tar", "-xzf", "-", "-C", staging], data=buffer.getvalue(), timeout=120)
        name = executable(source).name
        expected = executable_hash(source)
        actual = self.bundle_hash(staging + "/" + source.name, name)
        if actual != expected:
            raise VerificationError(f"Staged executable SHA256 mismatch: {source}")
        # Check again immediately before the atomic directory swap.
        if self.running_bundle_pids(destination):
            raise VerificationError(f"Guest application started during copy; original bundle retained: {destination}")
        script = "import os,sys,shutil; dst,stage=sys.argv[1:]; old=dst+'.old'; shutil.rmtree(old,ignore_errors=True); os.rename(dst,old) if os.path.exists(dst) else None; os.rename(stage,dst); shutil.rmtree(old,ignore_errors=True); os.rmdir(os.path.dirname(stage))"
        self.exec(["/usr/bin/python3", "-c", script, destination, staging + "/" + source.name])
        if self.bundle_hash(destination, name) != expected:
            raise VerificationError(f"Installed Guest executable SHA256 mismatch: {destination}")
        return destination

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
        self.input = ExternalInput(None, guest.vm, artifacts)
        self.observer = NativeObserver(guest, guest_dir, artifacts)
        self.host_app = WORKSPACE / "build/Verification/Build/Products/Release/MacMenuY.app"
        self.host_fixture = WORKSPACE / "build/native-interaction/MenuYFixture.app"
        self.app_hash = ""
        self.source_baseline: dict[int, dict] | None = None
        self.source_window_ids: dict[int, int] = {}
        self.extra_launch_args: list[str] = []
        self.run_restoration_fault = False
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
                 "limitations": ["MENUY_VERIFY commands configure state; actual menu input uses external VNC and independent source callbacks; final production build is accepted separately", "Only this guest's native menus are tested, not private host app/account state"]}
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
        self.assert_app_hash("before-fresh-launch")
        self.guest.exec(["/usr/bin/open", self.app, "--args", "--verification-guest", "--verification-command-file", self.command_path,
                         "--verification-result-dir", self.results, "--verification-fixture-state", self.fixture_state,
                         "--diagnostics-path", self.collector_state, "--evidence-dir", self.evidence, *self.extra_launch_args])
        # Source discovery may take several bounded AX rounds. Permissions must
        # be granted through the guest OS before this gate can become ready.
        ready = self.wait_json(self.results + "/ready.json", lambda value: value.get("guestModel", "").lower().startswith("virtualmac"), timeout=max(self.timeout, 45))
        self.ensure(ready["state"].get("accessibility") and ready["state"].get("screenCapture"), "Guest native permissions available", ready["state"])
        state = self.wait_native_count(self.count)
        self.assert_app_hash("after-fresh-launch")
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
        self.ensure(bool(data and data.startswith(PNG_SIGNATURE) and len(data) > 128),
                    "Required fresh native PNG exists: " + host_name,
                    {"guestPath": self.evidence + "/" + guest_name, "bytes": len(data or b"")})
        (self.artifacts / host_name).write_bytes(data)

    def configure_runtime(self, driver: Path | None, observer: Path | None, host_app: Path | None = None, host_fixture: Path | None = None) -> None:
        self.input = ExternalInput(driver, self.guest.vm, self.artifacts)
        self.observer = NativeObserver(self.guest, self.base, self.artifacts, observer)
        if host_app: self.host_app = host_app
        if host_fixture: self.host_fixture = host_fixture

    def assert_app_hash(self, phase: str) -> None:
        actual = self.guest.bundle_hash(self.app, executable(self.host_app).name)
        self.ensure(bool(self.app_hash and actual == self.app_hash), "Guest executable SHA256 matches current Host build: " + phase,
                    {"expected": self.app_hash, "actual": actual, "hostApp": str(self.host_app), "guestApp": self.app})

    def configure_bundles(self, app: Path, fixture: Path, copy: bool) -> None:
        if copy:
            self.host_app, self.host_fixture = app, fixture
            self.app = self.base + "/apps/" + app.name
            self.fixture = self.base + "/fixture/" + fixture.name
        else:
            self.app, self.fixture = str(app), str(fixture)
        self.app_hash = executable_hash(self.host_app)
        existing = self.guest.read_json(self.results + "/ready.json") or {}
        pid = existing.get("state", {}).get("pid") or (self.guest.read_json(self.collector_state) or {}).get("pid", 0)
        if pid and self.guest.process_running(pid):
            old_hash = self.guest.bundle_hash(self.app, executable(self.host_app).name)
            self.ensure(True, "Recorded prepared collector hash before normal stop", {"pid": pid, "sha256": old_hash})
            self.quit_collector(independent=False)
        self.ensure(not self.guest.running_bundle_pids(self.app), "Prepared old collector fully stopped before bundle installation")
        if copy:
            # Fixture mutations are not overlaid on a running client either.
            existing_fixture = self.guest.read_json(self.fixture_state) or {}
            if self.guest.running_bundle_pids(self.fixture):
                self.ensure(self.guest.process_running(existing_fixture.get("pid", 0)), "Running fixture identity has a current native receipt")
                self.guest.exec(["/bin/kill", "-TERM", str(existing_fixture["pid"])])
                deadline = time.monotonic() + 8
                while self.guest.process_running(existing_fixture["pid"]) and time.monotonic() < deadline: time.sleep(.2)
                self.ensure(not self.guest.process_running(existing_fixture["pid"]), "Old isolated fixture stopped before installation")
            self.app = self.guest.copy_bundle(app, self.base + "/apps")
            self.fixture = self.guest.copy_bundle(fixture, self.base + "/fixture")
        self.assert_app_hash("prepared-bundle")
        fixture_hash = self.guest.bundle_hash(self.fixture, executable(self.host_fixture).name)
        self.ensure(fixture_hash == executable_hash(self.host_fixture), "Guest fixture SHA256 matches current Host fixture",
                    {"expected": executable_hash(self.host_fixture), "actual": fixture_hash})

    def journal(self) -> dict:
        script = "import subprocess,plistlib,json; p=plistlib.loads(subprocess.check_output(['/usr/bin/defaults','export','io.novarock.MacMenuY','-'])); raw=p.get('MacMenuY.NativeRestorationJournal.v1'); value=json.loads(raw) if isinstance(raw,bytes) else {'version':1,'entries':[]}; print(json.dumps(value))"
        value = json.loads(self.guest.exec(["/usr/bin/python3", "-c", script]))
        self.ensure(value.get("version") == 1 and isinstance(value.get("entries"), list), "Independent local restoration journal is readable", value)
        return value

    def observe_sources(self, name: str, count: int | None = None) -> tuple[dict, dict[int, dict]]:
        observed = self.observer.snapshot(name)
        positions = source_positions(observed, count or self.count, self.source_window_ids or None)
        return observed, positions

    def capture_source_baseline(self) -> None:
        state = self.snapshot()
        self.source_window_ids = {index: self.item(state, index)["id"] for index in range(1, self.count + 1)}
        observed, self.source_baseline = self.observe_sources("source-hidden-baseline")
        self.ensure(len(self.source_baseline) == self.count, "Every original source has independent AX and CGWindow frame evidence", {"order": source_order(self.source_baseline)})

    def quit_collector(self, independent: bool = True, expect_fault: bool = False) -> dict:
        before = self.snapshot()
        self.guest.shell(f"/bin/rm -f {shlex.quote(self.collector_state + '.exit.json')}")
        self.command("quit")
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline and self.guest.process_running(before["pid"]): time.sleep(.2)
        self.ensure(not self.guest.process_running(before["pid"]), "Collector process terminated after native cleanup")
        report = self.wait_json(self.collector_state + ".exit.json", timeout=8)
        self.assert_app_hash("after-normal-stop") if self.app_hash and independent else None
        if expect_fault:
            self.ensure(bool(report.get("remaining")) and report.get("journalSaved") is True,
                        "Injected real return failure persisted pending restoration journal", report)
        else:
            self.ensure(report.get("remaining") == [] and report.get("journalSaved") is True and report.get("journalPending", -1) == 0,
                        "Normal termination reports every temporary item restored and empty journal", report)
        if independent and self.source_baseline:
            observed, after = self.observe_sources("independent-post-quit")
            groups = {False: [], True: []}
            for index in self.source_baseline:
                groups[bool(self.item(before, index).get("pinned"))].append(index)
            # Removing separator status items changes the gap between permanent
            # pinned and folded groups; every source's order and neighbor spacing
            # within each group must still match independent pre-menu evidence.
            restored = source_order(self.source_baseline) == source_order(after) and all(
                relative_positions_restored({index: self.source_baseline[index] for index in indexes},
                                            {index: after[index] for index in indexes})
                for indexes in groups.values() if indexes)
            self.ensure((not restored) if expect_fault else restored,
                        "Independent original positions and neighboring order " + ("remain displaced after injected failure" if expect_fault else "restored after quit"),
                        {"before": self.source_baseline, "after": after, "beforeOrder": source_order(self.source_baseline), "afterOrder": source_order(after)})
        return report

    def external_hover(self) -> dict:
        self.command("hide")
        current = self.observer.snapshot("external-hover-before")
        display = current["display"]
        outside = {"x": display["x"] + display["width"] * .55, "y": display["y"] + display["height"] * .7}
        self.input.send("move", **outside)
        time.sleep(.4)
        current = self.observer.snapshot("external-hover-hidden")
        self.ensure(actual_panel(current) is None, "Independent native shelf initially collapsed before hover")
        self.input.screenshot("hover-primary-menubar.png")
        nodes = native_app(current, COLLECTOR_BUNDLE)["nodes"]
        entries = [node for node in nodes if node.get("role") in {"AXButton", "AXMenuBarItem"}
                   and (node.get("AXDescription") or node.get("AXTitle")) in {"MacMenuY", "MacMenuY 收纳入口"}
                   and node.get("intersectsDisplay") and node.get("frame", {}).get("y", 99999) < 40]
        entries = list({json.dumps(node["frame"], sort_keys=True): node for node in entries}.values())
        self.ensure(len(entries) == 1, "Independent AX finds exactly one actual formal-bar collector entry", {"entries": entries})
        focus_before = current.get("frontmostBundle")
        x, y = center(entries[0]); self.input.send("move", x=x, y=y)
        deadline = time.monotonic() + 6
        shown = None
        while time.monotonic() < deadline:
            current = self.observer.snapshot("external-hover-opening")
            shown = actual_panel(current)
            if shown is not None: break
            time.sleep(.2)
        self.ensure(shown is not None, "Real external VNC entry hover opens actual native panel", {"panel": shown})
        self.input.send("move", x=shown["frame"]["x"] + shown["frame"]["width"] / 2,
                        y=shown["frame"]["y"] + min(20, shown["frame"]["height"] / 2))
        time.sleep(.3)
        stayed = self.observer.snapshot("external-hover-stay")
        self.ensure(actual_panel(stayed) is not None and stayed.get("frontmostBundle") == focus_before,
                    "External pointer enters shelf and preserves original work application focus", {"focusBefore": focus_before, "focusAfter": stayed.get("frontmostBundle")})
        self.input.screenshot("hover-expanded-shelf.png")
        self.input.send("move", **outside)
        deadline = time.monotonic() + 4
        collapsed = False
        while time.monotonic() < deadline:
            current = self.observer.snapshot("external-hover-collapsing")
            collapsed = actual_panel(current) is None
            if collapsed: break
            time.sleep(.2)
        self.ensure(collapsed, "Real external pointer leave collapses actual native shelf")
        return {"details": {"passed": True, "input": "external VNC", "focusBefore": focus_before, "focusAfter": stayed.get("frontmostBundle"), "panel": shown}}

    def menu(self, index: int, button: str, modifiers: list[str], select: bool = True) -> dict:
        # Preparation may hold the shelf, but input itself MUST cross InputView.
        self.command("preview")
        self.command("search", query="")
        observed = self.observer.snapshot("pre-external-" + button + "-menu")
        panel = actual_panel(observed)
        self.ensure(panel is not None, "Real shelf visible before external icon input", {"window": panel})
        state = self.snapshot()
        expected_label = "打开 " + self.item(state, index)["name"]
        candidates = [node for node in native_buttons(observed) if fixture_index(node) == index or node.get("AXDescription") == expected_label]
        self.ensure(len(candidates) == 1, "Exactly one real native shelf InputView button targets original fixture", {"index": index, "expectedLabel": expected_label, "matches": candidates})
        before = self.guest.read_json(self.fixture_state) or {}
        count_before, pid_before = len(before.get("opens", [])), before.get("pid")
        started = float(self.guest.exec(["/usr/bin/python3", "-c", "import time;print(time.time())"]))
        input_receipt = self.input.click_node(candidates[0], button, modifiers)
        actual = self.wait_json(self.fixture_state, lambda value: value.get("pid") == pid_before and
            any(event.get("menuOpened") == index and event.get("timestamp", 0) >= started for event in value.get("opens", [])[count_before:]), timeout=10)
        events = [event for event in actual.get("opens", [])[count_before:] if event.get("timestamp", 0) >= started]
        click = next((event for event in events if event.get("index") == index and "button" in event), None)
        self.ensure(any(event.get("menuOpened") == index for event in events), f"External shelf {button} input genuinely opened original client menu", {"input": input_receipt, "independentFixtureEvents": events})
        self.ensure(click is not None and click.get("button") == button and exact_modifiers(click.get("modifiers", []), modifiers),
                    f"Original client preserved exact {button} / {modifiers or 'no modifiers'}", {"click": click, "expectedModifiers": modifiers})
        opened_observation = self.observer.snapshot("actual-original-menu-open")
        source = native_app(opened_observation, FIXTURE_BUNDLE)
        menu_nodes = [node for node in source["nodes"] if node.get("role") == "AXMenu" and node.get("intersectsDisplay")]
        self.ensure(bool(menu_nodes), "Independent source AX confirms actual original native menu is visible", {"nativeMenus": menu_nodes})
        if select:
            self.input.send("key", key="Down", modifiers=[])
            self.input.send("key", key="Return", modifiers=[])
            actual = self.wait_json(self.fixture_state, lambda value: any(event.get("selection") == index and event.get("timestamp", 0) >= started for event in value.get("opens", [])[count_before:]), timeout=8)
            events = actual.get("opens", [])[count_before:]
            self.ensure(any(event.get("selection") == index for event in events), "External keyboard selection reached original NSMenu callback", {"events": events})
            self.wait_json(self.fixture_state, lambda value: index not in value.get("openMenus", []), timeout=6)
            self.wait_restored(index)
            if self.source_baseline:
                _, returned = self.observe_sources("post-menu-independent-source-return")
                self.ensure(positions_restored(self.source_baseline, returned), "Independent source position and neighboring order restored after real menu", {"before": self.source_baseline, "after": returned})
        return {"input": input_receipt, "events": events, "started": started}

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

    def restoration_fault_scenario(self) -> None:
        self.extra_launch_args = ["--verification-restoration-fail-once", "--verification-restoration-exit-save"]
        self.start_collector()
        self.capture_source_baseline()
        self.menu(self.count, "left", [], False)
        self.quit_collector(expect_fault=True)
        self.ensure(bool(self.journal().get("entries")), "Injected failure leaves independently readable nonempty persisted journal")
        self.extra_launch_args = []
        fresh = self.start_collector()
        self.ensure(bool(fresh.get("pid")), "Fresh process started after persisted native return failure")
        deadline = time.monotonic() + self.timeout
        returned = {}
        while time.monotonic() < deadline:
            _, returned = self.observe_sources("startup-restoration-native")
            if positions_restored(self.source_baseline, returned): break
            time.sleep(.3)
        self.ensure(positions_restored(self.source_baseline, returned), "Fresh startup independently restored pending source frame and neighbor order", {"before": self.source_baseline, "after": returned})
        self.ensure(self.journal().get("entries") == [], "Fresh startup independently cleared persisted restoration journal")
        self.quit_collector()

    def prepare(self, app: Path, fixture: Path, copy: bool = True) -> None:
        model = self.guest.verify_guest()
        self.observer.install()
        self.configure_bundles(app, fixture, copy)
        self.guest.shell(f"/bin/mkdir -p {shlex.quote(self.results)} {shlex.quote(self.evidence)}")
        self.start_fixture()
        self.guest.write(self.command_path, b"{}")
        self.guest.shell(f"/bin/rm -f {shlex.quote(self.results + '/ready.json')}")
        argv = ["/usr/bin/open", self.app, "--args", "--verification-guest", "--verification-command-file", self.command_path,
                "--verification-result-dir", self.results, "--verification-fixture-state", self.fixture_state,
                "--diagnostics-path", self.collector_state, "--evidence-dir", self.evidence]
        self.assert_app_hash("before-preparation-launch")
        self.guest.exec(argv)
        self.assert_app_hash("after-preparation-launch")
        value = {"guestModel": model, "app": self.app, "fixture": self.fixture, "launchArguments": argv,
                 "permissions": "Complete normal guest OS permission flow; no TCC/SIP/database changes performed"}
        (self.artifacts / "bootstrap.json").write_text(json.dumps(value, indent=2))
        print("Guest fixture/application prepared; complete permissions in the guest VM, then run --skip-copy with these guest bundle paths", flush=True)

    def run(self, app: Path, fixture: Path, copy: bool = True) -> None:
        try:
            model = self.guest.verify_guest()
            self.ensure(model.lower().startswith("virtualmac"), "Execution bound to isolated VirtualMac", {"model": model})
            self.observer.install()
            self.configure_bundles(app, fixture, copy)
            self.guest.shell(f"/bin/mkdir -p {shlex.quote(self.results)} {shlex.quote(self.evidence)}")
            self.start_fixture()
            state = self.start_collector()
            self.capture_source_baseline()
            self.ensure(len(self.fixture_items(state)) == self.count and len({item['id'] for item in self.fixture_items(state)}) == self.count,
                        "All original native fixture windows independently enumerated", {"count": self.count})
            self.ensure(state.get("coverWindows") == [], "No presentation cover exists over original menubar")
            self.ensure(state["preferences"].get("opacity") == 0.9, "Default native shelf opacity is 90%")

            result = self.external_hover()
            self.ensure(result["details"].get("passed"), "Actual native entry hover / shelf stay / leave collapse and work focus", result["details"])

            self.command("preview")
            result = self.command("search", query=f"Fixture-{self.count}")
            ui = result["details"].get("ui", {})
            self.ensure(ui.get("available") and ui.get("itemButtonCount") == 1, "Actual native search reduces shelf to one original item", result["details"])
            independent_search = self.observer.snapshot("independent-native-search")
            searched_buttons = native_buttons(independent_search)
            self.ensure(actual_panel(independent_search) is not None and len(searched_buttons) == 1, "Independent AX confirms one actually rendered searched icon", {"buttons": searched_buttons})
            self.command("hide")

            self.menu(self.count, "left", [], True)
            self.menu(self.count, "right", [], True)
            self.menu(self.count, "left", ["option"], True)

            _, independent_pin_before = self.observe_sources("independent-pin-before")
            result = self.command("pin", index=self.count, value=True)
            _, independent_pin_after = self.observe_sources("independent-pin-after")
            self.ensure(independent_pin_after[self.count].get("intersectsDisplay") and
                        not frames_close(independent_pin_before[self.count]["frame"], independent_pin_after[self.count]["frame"]),
                        "Independent original native source actually moved into formal menubar after Pin", {"before": independent_pin_before[self.count], "after": independent_pin_after[self.count]})
            item = result["details"].get("after", {})
            self.ensure(item.get("pinned") and item.get("onScreen"), "Pin genuinely returns original item to formal menubar", result["details"])
            self.capture_source_baseline()
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
            self.source_window_ids = {}
            self.ensure(item["id"] != original_window and item.get("pinned") and item.get("onScreen"),
                        "Pin identity survives source fixture process/window relaunch", item)
            result = self.command("pin", index=self.count, value=False)
            item = result["details"].get("after", {})
            self.ensure(not item.get("pinned") and not item.get("onScreen"), "Unpin genuinely returns original item to hidden area", result["details"])
            _, independent_unpin = self.observe_sources("independent-unpin-after")
            self.ensure(not independent_unpin[self.count].get("intersectsDisplay"), "Independent native source AX confirms Unpin returned item offscreen", independent_unpin[self.count])
            self.capture_source_baseline()

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
            self.guest.exec(["/bin/rm", "-f", self.evidence + "/expanded-shelf.png"])
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
                self.guest.exec(["/bin/rm", "-f", self.evidence + "/expanded-shelf.png"])
                result = self.command("preview")
                self.command("search", query="")
                state = self.snapshot()
                observed = self.observer.snapshot("actual-style-" + style)
                real_panel = actual_panel(observed)
                buttons = native_buttons(observed)
                expected_labels = Counter("打开 " + item["name"] for item in self.fixture_items(state))
                rendered_labels = Counter(node.get("AXDescription") or node.get("AXTitle") for node in buttons)
                self.ensure(state.get("panelVisible") is True and real_panel is not None and
                            all(item.get("hasImage") is True for item in self.fixture_items(state)) and
                            len(self.fixture_items(state)) == self.count and len(buttons) >= self.count and
                            all(rendered_labels[label] >= number for label, number in expected_labels.items()),
                            f"Actual {style} panel visible, all {self.count} source images present and independent native buttons rendered",
                            {"window": real_panel, "buttons": buttons, "expectedLabelCounts": dict(expected_labels)})
                self.ensure(real_panel is not None and abs(real_panel.get("alpha", -1) - .9) <= .01 and
                            no_cover_windows(observed, state["screens"][0]["menuBarHeight"]) == [],
                            "Independent WindowServer confirms 90% alpha and no cover over formal menubar", {"window": real_panel})
                self.input.screenshot(f"independent-style-{style}-{size}.png")
                panel = state.get("panelFrame", {})
                screen = state.get("screens", [{}])[0]
                rect = screen.get("frame", {})
                self.ensure(state.get("panelOpacity") == 0.9 and panel.get("width") == rect.get("width") and
                            panel.get("y", 0) + panel.get("height", 0) <= rect.get("y", 0) + rect.get("height", 0) - screen.get("menuBarHeight", 0) + 1,
                            f"Actual {style} / {size}pt full-width native shelf preserves opacity and formal-bar boundary", state)
                self.artifact("expanded-shelf.png", f"style-{style}-{size}.png")
            self.command("preferences", style="native", iconSize=24, opacity=0.9, sortMode="original", rules=[])
            self.command("hide")
            _, folded = self.observe_sources("independent-enabled-before")
            self.command("enabled", value=False)
            state = self.snapshot()
            observed, unfolded = self.observe_sources("independent-disabled-after")
            self.ensure(not state.get("enabled") and any(not frames_close(folded[index]["frame"], unfolded[index]["frame"]) for index in folded)
                        and any(value.get("intersectsDisplay") for value in unfolded.values()),
                        "Disabled folding independently unfolds native source frames", {"before": folded, "after": unfolded})
            self.command("enabled", value=True)
            deadline = time.monotonic() + self.timeout
            refolded = {}
            while time.monotonic() < deadline:
                _, refolded = self.observe_sources("independent-refolded")
                if positions_restored(folded, refolded): break
                time.sleep(.25)
            self.ensure(self.snapshot().get("enabled") and positions_restored(folded, refolded), "Re-enabled folding independently returns native source frames and order", {"before": folded, "after": refolded})
            self.source_baseline = refolded

            self.menu(self.count, "left", [], False)
            actual = self.guest.read_json(self.fixture_state) or {}
            self.ensure(self.count in actual.get("openMenus", []), "Termination test starts with original menu genuinely active")
            self.quit_collector()
            actual = self.guest.read_json(self.fixture_state) or {}
            self.ensure(self.count not in actual.get("openMenus", []), "Normal app quit closes its own original temporary menu")
            if self.run_restoration_fault:
                self.restoration_fault_scenario()
            self.save_summary("passed")
        except Exception as exc:
            self.save_summary("failed", str(exc))
            raise


def self_test() -> None:
    # These vetoes address concrete former false passes; no VM or input touched.
    assert not exact_modifiers(["option", "command"], ["option"])
    assert not exact_modifiers(["option"], [])
    assert exact_modifiers(["option"], ["option"])
    assert exact_modifiers([], [])
    assert not exact_modifiers(["unknown"], [])
    before = {1: {"frame": {"x": -40, "y": 0, "width": 20, "height": 24}}, 2: {"frame": {"x": -20, "y": 0, "width": 20, "height": 24}}}
    moved = {1: {"frame": {"x": -20, "y": 0, "width": 20, "height": 24}}, 2: {"frame": {"x": -40, "y": 0, "width": 20, "height": 24}}}
    assert positions_restored(before, before)
    assert not positions_restored(before, moved)
    # A cached frame without a visible actual shelf AX container cannot pass.
    fake = {"apps": [{"bundle": COLLECTOR_BUNDLE, "pid": 5, "nodes": []}], "display": {"width": 1024}, "windows": []}
    assert actual_panel(fake) is None
    assert not b"old missing evidence".startswith(PNG_SIGNATURE)
    print("PASS: exact modifiers, original frame/order restoration and actual visible panel/image gates veto old false positives")


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
    parser.add_argument("--host-app", type=Path, default=WORKSPACE / "build/Verification/Build/Products/Release/MacMenuY.app", help="Current Host build SHA256 reference, including --skip-copy")
    parser.add_argument("--host-fixture", type=Path, default=WORKSPACE / "build/native-interaction/MenuYFixture.app", help="Current Host fixture SHA256 reference, including --skip-copy")
    parser.add_argument("--input-driver", type=Path, help="Root supplied Guest VNC JSON CLI; mandatory for real menu acceptance")
    parser.add_argument("--observer", type=Path, help="Precompiled read-only GuestNativeObserver; otherwise Host compile only")
    parser.add_argument("--restoration-fault", action="store_true", help="Also verify persisted real return failure and independent startup recovery")
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
    suite.configure_runtime(args.input_driver, args.observer, args.host_app, args.host_fixture)
    suite.run_restoration_fault = args.restoration_fault
    try:
        if args.prepare_only:
            suite.prepare(args.app, args.fixture, copy=not args.skip_copy)
            return 0
        suite.run(args.app, args.fixture, copy=not args.skip_copy)
    except (VerificationError, RuntimeError) as exc:
        suite.save_summary("failed", str(exc))
        print("FAIL:", exc, flush=True); return 1
    print("Native isolated verification passed; see", args.artifacts / "summary.json", flush=True)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
