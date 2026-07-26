## What & why

## Checklist

- [ ] `swift test` green (`cd IceCubeKit && swift test`)
- [ ] `swiftformat --lint .` clean
- [ ] Works in simulated mode (`ICECUBE_SIMULATED=1`)
- [ ] Safety invariants untouched (or the PR argues, loudly, why a change is safe)
- [ ] No new dependencies, no SMC writes outside `IceCubeHelper/`
- [ ] Helper-daemon changes: tested via `install.sh --debug` + Re-register on real hardware
