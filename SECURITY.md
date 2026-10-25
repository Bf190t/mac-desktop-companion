# Security

## Scope

Desktop Companion is a local desktop application. The base app has no account, analytics endpoint, cloud chat service, automatic updater, privileged helper, or remote-control interface. Optional component installation downloads code and model data from the upstream locations pinned in the repository. Model inference runs in a separate local process with network access denied.

This separation is not a complete security boundary against every local attack. The model worker still executes third-party native runtime code and can access files available to its user process. The application supplies it with chat text, not system-monitor snapshots or arbitrary tools. Hash pinning detects a change from the reviewed download; it does not prove that the pinned content has no vulnerabilities.

Experimental speech input requests microphone and Speech permissions only when used. An unavailable on-device recognizer is treated as unavailable; there is no intentional cloud-recognition fallback. System voices and operating-system privacy behavior are controlled by macOS.

## Reporting

For an ordinary bug, use the repository's Issues page. Include the app version, macOS version, broad chip family, reproduction steps, and a sanitized screenshot only if needed.

**Do not post tokens, chat histories, full hardware snapshots, Bluetooth addresses, device names, or personal file paths.** For a vulnerability that would expose private data or permit execution, use GitHub's **Report a vulnerability** entry if it is available for this repository. If it is unavailable, open an issue asking for a private contact without disclosing exploit details. There is no guaranteed response time or paid security support.

## Release checks

`scripts/audit_release.py` performs a bounded release-content check for private paths, common secret formats, accidental model/runtime payloads, and excluded artifacts. It does not replace a security audit. The release process also builds from a clean source copy and runs regression checks.

The initial binary is ad-hoc signed and is not Apple-notarized. Checksums help confirm that a download matches a release file; they are not a publisher identity or a guarantee of safety.
