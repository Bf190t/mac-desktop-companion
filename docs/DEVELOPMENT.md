# Development and validation

The application is native Swift/AppKit. It links the system frameworks and does not use a web renderer or third-party window library. The original mascot is drawn from code, so a source build does not require a separate art download.

## Build

```sh
./scripts/build.sh
./scripts/test.sh
```

The default build targets Apple Silicon and macOS 14 or newer. Use a supported Xcode or Command Line Tools installation selected by `xcode-select`. The build locates its SDK through `xcrun`; toolchain-specific workarounds must remain bounded to the affected setup. The optional chat runtime has its own newer macOS requirement.

The output is `dist/Desktop Companion.app`. Existing output bundles are never overwritten; for another build, set `COMPANION_APP_DIR` to a fresh absolute output path. Build results, extracted packages, and QA output are not source files and must not be committed. The base app must launch with no optional model or runtime installed.

## Validation layers

- **Pure logic:** lifecycle policies, short-chat boundaries, synthetic fixtures, and roaming rules. Boundary checks use an isolated preferences domain, explicitly select Chinese and English, and set UTC within the test process; they do not depend on or modify the app’s real language setting.
- **Concurrency:** model input/cancel/release handling, without requiring a real conversation or microphone.
- **Native application:** launch a freshly built bundle in an isolated test preferences domain; check windows, original artwork, supported language settings, and state restoration. The window test always checks geometry and configuration; when no `NSScreen` is available it explicitly reports native zoom as skipped. On a session with a display, those zoom assertions run normally and any failure remains a failure.
- **Optional install:** pinned download verification, staged install, cancellation/failure behavior, inference, and removal must be checked separately from the base app.
- **Archive:** extract the release into a clean directory, verify its signature/integrity, and run the extracted executable's self-test. Scan the final source candidate and bundle for excluded content.

A clean-directory test on one Mac is not a physical test on every supported Mac. The declared deployment target is not proof that all older macOS versions, Bluetooth devices, sensor keys, or OS permission flows were tested. Release notes should state which checks actually ran and which remained unavailable. No measured CPU percentage should be described as a measured battery-life result.

## Content audit

```sh
python3 scripts/audit_release.py . --mode source
python3 scripts/audit_release.py 'dist/Desktop Companion.app' --mode app
```

You can add `--deny-term` for a private local identifier without putting that identifier in the repository. Audit reports include rule names and relative file names, not matched secret text. A nonzero result must be reviewed before publication. This is a targeted content check, not a claim that the program or its dependencies are vulnerability-free.

## Release

Use a new version number, complete the source and app checks, and keep optional weights out of Git and the base archive. Include the root license, third-party notices, and applicable dependency license texts. Publish SHA-256 checksums for release files. Do not label an ad-hoc signature as Developer ID signing or notarization.
