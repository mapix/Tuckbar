"""Independent Guest-only observations and an explicit external VNC input contract.

Importing this module never contacts a VM or sends input. All coordinates use
Quartz points, not the VNC framebuffer's backing pixels.
"""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import uuid

COLLECTOR_BUNDLE = "io.novarock.MacMenuY"
FIXTURE_BUNDLE = "io.novarock.MacMenuY.Fixture"
KNOWN_MODIFIERS = frozenset({"option", "shift", "control", "command", "capsLock"})
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def executable(bundle: Path) -> Path:
    import plistlib
    with (bundle / "Contents/Info.plist").open("rb") as source:
        name = plistlib.load(source)["CFBundleExecutable"]
    path = bundle / "Contents/MacOS" / name
    if not path.is_file():
        raise RuntimeError(f"Application executable missing: {path}")
    return path


def executable_hash(bundle: Path) -> str:
    return hashlib.sha256(executable(bundle).read_bytes()).hexdigest()


def exact_modifiers(actual: list[str], expected: list[str]) -> bool:
    return (isinstance(actual, list) and set(actual) <= KNOWN_MODIFIERS
            and set(expected) <= KNOWN_MODIFIERS and set(actual) == set(expected))


def label(node: dict) -> str:
    return str(node.get("AXDescription") or node.get("AXTitle") or "")


def fixture_index(node: dict) -> int | None:
    identity = re.fullmatch(r"fixture\.item\.(\d+)", str(node.get("AXIdentifier", "")))
    if identity:
        return int(identity.group(1))
    for key in ["AXDescription", "AXTitle", "AXHelp"]:
        match = re.search(r"\bFixture[- ]?(\d+)\b", str(node.get(key, "")), re.I)
        if match:
            return int(match.group(1))
    return None


def app(snapshot: dict, bundle: str) -> dict:
    matches = [value for value in snapshot.get("apps", []) if value.get("bundle") == bundle]
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one independently running {bundle}; found {len(matches)}")
    if matches[0].get("truncated"):
        raise RuntimeError(f"Independent native AX traversal truncated: {bundle}")
    return matches[0]


def native_buttons(snapshot: dict, *, editing: bool = False) -> list[dict]:
    prefixes = ("固定 ", "收回 ") if editing else ("打开 ",)
    return [node for node in app(snapshot, COLLECTOR_BUNDLE).get("nodes", [])
            if node.get("role") == "AXButton" and label(node).startswith(prefixes)
            and node.get("intersectsDisplay") and node.get("AXEnabled", True)
            and not node.get("AXHidden", False)]


def find_button(snapshot: dict, text: str, *, exact: bool = True) -> dict:
    nodes = [node for node in app(snapshot, COLLECTOR_BUNDLE).get("nodes", [])
             if node.get("role") in {"AXButton", "AXCheckBox", "AXMenuItem", "AXRadioButton"}
             and (label(node) == text if exact else text in label(node))
             and node.get("intersectsDisplay") and node.get("AXEnabled", True)
             and not node.get("AXHidden", False)]
    if len(nodes) != 1:
        raise RuntimeError(f"Expected one real visible native button {text!r}; found {len(nodes)}")
    return nodes[0]


def center(node: dict) -> tuple[float, float]:
    rect = node.get("frame", {})
    if rect.get("width", 0) <= 0 or rect.get("height", 0) <= 0:
        raise RuntimeError(f"Native target lacks a nonempty frame: {node}")
    return rect["x"] + rect["width"] / 2, rect["y"] + rect["height"] / 2


def source_positions(snapshot: dict, count: int, window_ids: dict[int, int] | None = None) -> dict[int, dict]:
    """Original source AX frames, optionally cross checked with independent CG IDs."""
    nodes = app(snapshot, FIXTURE_BUNDLE).get("nodes", [])
    result = {}
    for index in range(1, count + 1):
        candidates = [node for node in nodes if fixture_index(node) == index
                      and node.get("frame", {}).get("width", 0) > 0
                      and node.get("frame", {}).get("height", 0) > 0
                      and not label(node).startswith(("打开 ", "固定 ", "收回 "))]
        identified = [node for node in candidates if node.get("AXIdentifier") == f"fixture.item.{index}"]
        candidates = identified or candidates
        # Some clients expose both AXButton and its parent with identical frames.
        frames = {json.dumps(node["frame"], sort_keys=True): node for node in candidates}
        if len(frames) != 1:
            raise RuntimeError(f"Independent source native frame missing/ambiguous for fixture {index}: {len(frames)}")
        source = dict(next(iter(frames.values())))
        if window_ids:
            windows = [window for window in snapshot.get("windows", []) if window.get("id") == window_ids[index]]
            if len(windows) != 1:
                raise RuntimeError(f"Independent CGWindow ID {window_ids[index]} missing for fixture {index}")
            source["cgWindow"] = windows[0]
            if not frames_close(source["frame"], windows[0]["frame"], tolerance=2):
                raise RuntimeError(f"Fixture {index} independent AX/CG frame mismatch: {source['frame']} vs {windows[0]['frame']}")
        result[index] = source
    return result


def frames_close(left: dict, right: dict, tolerance: float = 2) -> bool:
    return all(abs(float(left.get(key, -999999)) - float(right.get(key, 999999))) <= tolerance
               for key in ("x", "y", "width", "height"))


def source_order(positions: dict[int, dict]) -> list[int]:
    return sorted(positions, key=lambda index: (positions[index]["frame"]["x"], positions[index]["frame"]["y"]))


def positions_restored(before: dict[int, dict], after: dict[int, dict], *, exact_frames: bool = True) -> bool:
    return (set(before) == set(after) and source_order(before) == source_order(after)
            and (not exact_frames or all(frames_close(before[index]["frame"], after[index]["frame"]) for index in before)))


def actual_panel(snapshot: dict) -> dict | None:
    collector = app(snapshot, COLLECTOR_BUNDLE)
    shelf = [node for node in collector.get("nodes", []) if node.get("AXIdentifier") == "MacMenuY-horizontal-shelf"]
    if not shelf or not any(node.get("intersectsDisplay") and not node.get("AXHidden", False) for node in shelf):
        return None
    display = snapshot["display"]
    candidates = [window for window in snapshot.get("windows", [])
                  if window.get("pid") == collector["pid"] and window.get("onScreen")
                  and abs(window["frame"]["width"] - display["width"]) <= 2
                  and window["frame"]["height"] > 30 and window["frame"]["y"] >= display["y"] + 20]
    if len(candidates) != 1:
        raise RuntimeError(f"Native shelf AX exists but independent full-width WindowServer panel count is {len(candidates)}")
    return candidates[0]


def no_cover_windows(snapshot: dict, menu_height: float, control_ids: set[int] | None = None) -> list[dict]:
    collector = app(snapshot, COLLECTOR_BUNDLE)
    display = snapshot["display"]
    controls = control_ids or set()
    return [window for window in snapshot.get("windows", [])
            if window.get("pid") == collector["pid"] and window.get("onScreen")
            and window.get("id") not in controls
            and window["frame"]["width"] > 40 and window["frame"]["height"] > 1
            and window["frame"]["y"] < display["y"] + menu_height
            and window["frame"]["y"] + window["frame"]["height"] > display["y"]]


class ExternalInput:
    """A Root supplied CLI talks to a persistent Guest VNC session; never host UI."""
    def __init__(self, driver: Path | None, vm: str, artifacts: Path):
        self.driver, self.vm, self.artifacts = driver, vm, artifacts

    def send(self, op: str, **fields) -> dict:
        if not self.driver or not self.driver.is_file():
            raise RuntimeError("Real native input requires --input-driver (Guest VNC JSON CLI); direct Shelf.activate is not acceptance")
        payload = {"op": op, "vm": self.vm, "coordinateSpace": "quartz-points", **fields}
        result = subprocess.run([str(self.driver), json.dumps(payload, ensure_ascii=False)], capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError(f"External Guest input failed: {result.stderr.decode(errors='replace')[-1200:]}")
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"External driver response was not JSON: {result.stdout[:300]!r}") from exc
        if value.get("success") is not True:
            raise RuntimeError(f"External driver did not confirm drained input: {value}")
        ident = f"input-{op}-{uuid.uuid4().hex[:12]}"
        (self.artifacts / (ident + ".json")).write_text(json.dumps({"request": payload, "response": value}, indent=2, ensure_ascii=False))
        return value

    def click_node(self, node: dict, button: str = "left", modifiers: list[str] | None = None) -> dict:
        x, y = center(node)
        return self.send("click", x=x, y=y, button=button, modifiers=modifiers or [])

    def screenshot(self, name: str) -> Path:
        target = self.artifacts / name
        if target.exists(): target.unlink()
        result = self.send("screenshot", path=str(target.resolve()))
        actual = Path(result.get("path", str(target)))
        if not actual.is_file():
            raise RuntimeError(f"External VNC screenshot artifact missing: {actual}")
        data = actual.read_bytes()
        if not data.startswith(PNG_SIGNATURE) or len(data) < 128:
            raise RuntimeError(f"External VNC screenshot artifact is not valid PNG: {actual}")
        if actual != target: target.write_bytes(data)
        return target


class NativeObserver:
    def __init__(self, guest, guest_dir: str, artifacts: Path, binary: Path | None = None):
        self.guest, self.artifacts = guest, artifacts
        self.path = guest_dir.rstrip("/") + "/tools/GuestNativeObserver"
        self.binary = binary

    def install(self) -> None:
        self.guest.verify_guest()
        source = Path(__file__).resolve().parents[2] / "Tests/GuestNativeObserver.swift"
        binary = self.binary or self.artifacts / "GuestNativeObserver"
        if self.binary is None:
            result = subprocess.run(["xcrun", "swiftc", str(source), "-o", str(binary)], capture_output=True, timeout=90)
            if result.returncode:
                raise RuntimeError(f"Read-only Guest observer compile failed: {result.stderr.decode(errors='replace')[-1600:]}")
        if not binary.is_file():
            raise RuntimeError(f"Read-only Guest observer missing: {binary}")
        data = binary.read_bytes()
        self.guest.write(self.path, data)
        self.guest.exec(["/bin/chmod", "755", self.path])
        expected = hashlib.sha256(data).hexdigest()
        actual = self.guest.exec(["/usr/bin/shasum", "-a", "256", self.path]).decode().split()[0]
        if expected != actual:
            raise RuntimeError("Independent observer Guest executable hash mismatch")

    def snapshot(self, label_name: str = "observer") -> dict:
        raw = self.guest.exec([self.path], timeout=35)
        value = json.loads(raw)
        if not value.get("model", "").lower().startswith("virtualmac"):
            raise RuntimeError("Independent observer reported non-VirtualMac identity")
        if value.get("trusted") is not True or value.get("screenCapture") is not True:
            raise RuntimeError("Independent Guest observer needs its own normal Accessibility and Screen Recording grants")
        name = re.sub(r"[^a-zA-Z0-9_-]", "-", label_name) + "-" + uuid.uuid4().hex[:8]
        (self.artifacts / (name + ".json")).write_text(json.dumps(value, indent=2, ensure_ascii=False))
        return value

    def screenshot(self, name: str) -> Path:
        # A unique Guest filename makes stale image evidence impossible.
        path = self.path.rsplit("/", 2)[0] + "/evidence/independent-" + uuid.uuid4().hex + ".png"
        self.guest.exec(["/usr/sbin/screencapture", "-x", path])
        data = self.guest.read(path)
        if not data or not data.startswith(PNG_SIGNATURE) or len(data) < 128:
            raise RuntimeError(f"Independent native screenshot missing or invalid: {path}")
        target = self.artifacts / name
        target.write_bytes(data)
        return target


def relative_positions_restored(before: dict[int, dict], after: dict[int, dict]) -> bool:
    """Allow only a uniform x translation when collector control items disappear.

    Every source's order, neighbor distances, size and menu band must still match.
    This prevents a moved icon from passing merely because the app exited.
    """
    if set(before) != set(after) or not before or source_order(before) != source_order(after):
        return False
    anchor = source_order(before)[0]
    delta = after[anchor]["frame"]["x"] - before[anchor]["frame"]["x"]
    for index in before:
        expected = dict(before[index]["frame"])
        expected["x"] += delta
        if not frames_close(expected, after[index]["frame"]):
            return False
    return True
