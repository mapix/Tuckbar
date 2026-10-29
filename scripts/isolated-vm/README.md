# Isolated macOS verification VM

This VM is a separate macOS WindowServer/session for MacMenuY runtime tests.
It never uses the host's pointer or opens a host display window.

- Official Tart 2.41.1 was installed with `brew install openai/tools/tart`.
- Source image: `ghcr.io/cirruslabs/macos-tahoe-base:latest` (macOS Tahoe, no Xcode).
- Task-local `TART_HOME`: `artifacts/vm/tart-home`; automatic pruning is disabled.
- VM name: `menuy-tahoe`.
- Configuration: 4 vCPUs, 8 GiB memory, 1728×1117-point display, no display refit.
- No host audio, USB accessory or clipboard passthrough. Only `artifacts/vm/share`
  may be mounted read-only for this project's built binaries/test artifacts.

Run from the project root:

```sh
bash scripts/isolated-vm/clone.sh
bash scripts/isolated-vm/run.sh
bash scripts/isolated-vm/status.sh
bash scripts/isolated-vm/exec.sh /usr/bin/sw_vers
bash scripts/isolated-vm/stop.sh
```

`run.sh` stays attached to the background VM process. Launch it with an explicit
log/process owner when needed. `tart exec` uses the Guest Agent's local control
socket; the official base image already provides the agent. It does not need an
SSH password or modify the host's SSH configuration.

If Guest TCC UI is needed, `tart run --no-graphics --vnc-experimental` prints a
loopback hardware-VNC endpoint instead of opening the host Screen Sharing app.
Inspect its actual bind address before use; do not expose it publicly. Treat any
generated VNC credential as private. No host TCC/SIP/network-security preferences
were changed during setup. Inspect guest `csrutil status` and actual permissions
rather than claiming a public CI VM has the same security configuration as host.

Tart's old CirrusLabs Homebrew tap is incompatible with current Homebrew; use the
current official OpenAI tap. The formula dependency `openai/tools/softnet` was
trusted individually for installation; this VM uses default Apple shared NAT,
not Softnet, and no DHCP/network preferences were edited.

## Guest security parity

The public CI base template first disables SIP and seeds Guest Agent/SSH TCC
permissions. These are image properties, not changes made to host. After boot
inspect `csrutil status`. To strengthen Guest SIP, stop normal VM and run
`run-recovery.sh`; use the Guest recovery Terminal's official `csrutil enable`,
then boot normal VM and verify enabled. Never run that command on host, and
never relax other security controls for convenience. Guest TCC prompts can be
handled in its hardware VNC UI using normal macOS System Settings.
