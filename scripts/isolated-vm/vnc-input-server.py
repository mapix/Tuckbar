#!/usr/bin/env python3
"""Persistent Apple Screen Sharing input, confined to the isolated Tart guest.

Development dependencies: asyncvnc, Pillow. No host input API is used.
The official disposable CI image's existing public test account is used only
inside authentication; credentials never appear in command argv or results.
"""
import asyncio
import json
import os
from pathlib import Path
import subprocess

import asyncvnc
from cryptography.hazmat.primitives import serialization
from PIL import Image

root = Path(__file__).resolve().parents[2]
artifacts = root / "artifacts"
socket_path = artifacts / "vm/vnc-input.sock"
environment = os.environ.copy()
environment.update(TART_HOME=str(artifacts / "vm/tart-home"), TART_NO_AUTO_PRUNE="1")
tart = "/opt/homebrew/bin/tart"

def guest_text(*argv):
    return subprocess.check_output([tart, "exec", "menuy-tahoe", *argv], env=environment, text=True, timeout=15).strip()

model = guest_text("/usr/sbin/sysctl", "-n", "hw.model")
if not model.lower().startswith("virtualmac"):
    raise SystemExit("Refusing input outside the independent VirtualMac guest")
account = guest_text("/usr/bin/whoami")
modifiers = {"option": "Alt_L", "shift": "Shift_L", "control": "Control_L", "command": "Super_L"}
keys = {"Down": "Down", "Return": "Return", "Escape": "Escape", "Esc": "Escape", "BackSpace": "BackSpace", "Tab": "Tab", "a": "a"}

async def main():
    key_path = artifacts / "vm-tools/guest-vnc-host-key.der"
    public_key = serialization.load_der_public_key(key_path.read_bytes()) if key_path.exists() else None
    async with asyncvnc.connect("127.0.0.1", 59094, username=account, password=account, host_key=public_key) as client:
        if client.host_key:
            key_path.parent.mkdir(parents=True, exist_ok=True)
            key_path.write_bytes(client.host_key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo))
        lock = asyncio.Lock()

        async def handle(reader, writer):
            try:
                payload = await asyncio.wait_for(reader.readline(), 10)
                if len(payload) > 65536:
                    raise ValueError("Command too large")
                command = json.loads(payload)
                async with lock:
                    op = command["op"]
                    if op in {"move", "click"}:
                        # AX/Quartz coordinates are logical points. Apple's RFB
                        # framebuffer uses backing pixels; this guest is @2x.
                        scale = float(command.get("scale", 2))
                        if scale not in {1, 2}:
                            raise ValueError("Unsupported guest framebuffer scale")
                        x, y = round(float(command["x"]) * scale), round(float(command["y"]) * scale)
                        if not (0 <= x < client.video.width and 0 <= y < client.video.height):
                            raise ValueError("Point outside guest framebuffer")
                        client.mouse.move(x, y)
                        await client.drain()
                        await asyncio.sleep(0.05)
                        if op == "click":
                            button = {"left": 0, "right": 2, "middle": 1}[command.get("button", "left")]
                            flags = [modifiers[name] for name in command.get("modifiers", [])]
                            with client.keyboard.hold(*flags):
                                await client.drain()
                                with client.mouse.hold(button):
                                    await client.drain()
                                    await asyncio.sleep(0.06)
                            await client.drain()
                    elif op == "key":
                        flags = [modifiers[name] for name in command.get("modifiers", [])]
                        client.keyboard.press(*flags, keys[command["key"]])
                        await client.drain()
                    elif op == "text":
                        text = command["text"]
                        if not isinstance(text, str) or len(text) > 512:
                            raise ValueError("Invalid text")
                        client.keyboard.write(text)
                        await client.drain()
                    elif op != "screenshot":
                        raise ValueError("Unsupported guest operation")
                    result = {"success": True, "op": op, "model": model}
                    if op == "screenshot":
                        target = Path(command["path"]).resolve()
                        if target.suffix != ".png" or not target.is_relative_to(artifacts.resolve()):
                            raise ValueError("Screenshot must be a PNG in task artifacts")
                        target.parent.mkdir(parents=True, exist_ok=True)
                        pixels = await asyncio.wait_for(client.screenshot(), 20)
                        Image.fromarray(pixels).save(target)
                        result["path"] = str(target)
                writer.write(json.dumps(result).encode() + b"\n")
                await writer.drain()
            except Exception as error:
                writer.write(json.dumps({"success": False, "error": type(error).__name__ + ": " + str(error)}).encode() + b"\n")
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        if socket_path.exists():
            raise RuntimeError("Existing input socket must be checked and removed before a new owner starts")
        server = await asyncio.start_unix_server(handle, path=str(socket_path), limit=65537)
        os.chmod(socket_path, 0o600)
        print(json.dumps({"ready": True, "model": model, "framebuffer": [client.video.width, client.video.height], "socket": str(socket_path)}), flush=True)
        try:
            async with server:
                await server.serve_forever()
        finally:
            socket_path.unlink(missing_ok=True)

asyncio.run(main())
