# Contributing

Bug reports and small, focused improvements are welcome. Chinese and English reports are both useful.

1. Build with `./scripts/build.sh` and run `./scripts/test.sh`.
2. Keep changes limited to the problem being addressed. Explain the user-visible result and relevant validation in the pull request.
3. Add a meaningful regression case when fixing lifecycle, concurrency, install, context, or boundary behavior. Use synthetic text and device fixtures.
4. Check both interface languages and the minimum supported window sizes for UI changes.
5. Keep idle work low. Pause animation and inference appropriately around sleep, lock, hidden windows, and memory pressure. Do not add timers just to update an invisible label.
6. Never commit model weights, downloaded runtime packages, private reference art, voice recordings, personal logs, credentials, or conversation transcripts.

The public mascot is original procedural artwork. New artwork must have a clear license that permits modification and redistribution; attribution or a noncommercial fan-art label alone is not sufficient. Keep third-party license texts and notices when adding dependencies.

By contributing your own code or original art, you agree to its distribution under this project's MIT license. Third-party material must be identified and retain its applicable license. Please discuss larger dependencies or background services before implementing them.
