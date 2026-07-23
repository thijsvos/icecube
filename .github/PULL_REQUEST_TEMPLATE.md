## What & why

## Checklist

- [ ] `swift test` green (`cd ZephyrKit && swift test`)
- [ ] `swiftformat --lint .` clean
- [ ] Works in simulated mode (`ZEPHYR_SIMULATED=1`)
- [ ] Safety invariants untouched (or the PR argues, loudly, why a change is safe)
- [ ] No new dependencies, no SMC writes outside `ZephyrHelper/`
- [ ] Helper-daemon changes: tested via `install-debug.sh` + Re-register on real hardware
