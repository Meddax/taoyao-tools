# Xiaomi 12 Lite (`taoyao`) Kernel Tools

Companion utilities for the `taoyao` Linux 6.12 kernel tree:

- `flasher/` — PC helper scripts (`run-flash.sh`, `run-flash.ps1`, `run-flash.bat`) for ADB/sideload flashing and slot backup management.
- `diagnostics/` — On-device diagnostic collector (`taoyao-check.sh` and PC wrappers) for capturing dmesg, pstore, DSP/FastRPC, audio, and suspend state.
- `checks/` — Offline verification scripts (`dtcheck.py`, `cfgcheck.py`, `uapicheck/`) for device-tree label checking and msm-5.4 UAPI layout validation.
- `powerhal/` — Optional KernelSU `powerhint.json` override module builder for older kernel builds without in-kernel `bw_hwmon` compatibility.
