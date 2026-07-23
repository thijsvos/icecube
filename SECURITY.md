# Security Policy

Ice Cube ships a root LaunchDaemon, so security reports get priority attention.

## Reporting

Please report vulnerabilities **privately** via GitHub's "Report a
vulnerability" (Security Advisories) on this repository — not as public
issues. You'll get an acknowledgment within a few days.

## Scope of interest

- Anything that lets a non-approved process talk to the helper daemon
  (the XPC listener pins callers to the app's code-signing identity —
  bypasses of that pinning are the crown jewels).
- Anything that makes the daemon write fan targets outside the clamped
  safe range, disable the temperature ceiling, or skip the watchdog.
- Privilege escalation through the daemon's file handling
  (`/Library/Application Support/IceCube`).

## Out of scope

- Attacks requiring root already (root can do anything to the SMC directly).
- The unsigned-tester-build distribution flow (documented risk until
  releases are notarized).
