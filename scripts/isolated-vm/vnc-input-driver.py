#!/usr/bin/env python3
"""Send one JSON command to the task's persistent, Guest-only VNC connection."""
import json
from pathlib import Path
import socket
import sys

root = Path(__file__).resolve().parents[2]
if len(sys.argv) != 2:
    raise SystemExit("Usage: vnc-input-driver.py JSON")
command = json.loads(sys.argv[1])
payload = json.dumps(command).encode() + b"\n"
if len(payload) > 65536:
    raise SystemExit("Command too large")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
    connection.settimeout(40)
    connection.connect(str(root / "artifacts/vm/vnc-input.sock"))
    connection.sendall(payload)
    response = b""
    while not response.endswith(b"\n") and len(response) < 65536:
        chunk = connection.recv(4096)
        if not chunk:
            raise SystemExit("Guest input server closed without a result")
        response += chunk
result = json.loads(response)
print(json.dumps(result))
if result.get("success") is not True:
    raise SystemExit(1)
