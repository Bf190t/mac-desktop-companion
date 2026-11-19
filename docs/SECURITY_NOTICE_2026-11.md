# Security notice — November 2026

[简体中文](SECURITY_NOTICE_2026-11.zh-CN.md) · English

**In short:** Desktop Companion **0.2.2** fixes security problems found in a full review on 2026-11-19. **Earlier versions (0.1.0–0.2.1) are affected. Please update to 0.2.2.** None of the problems is rated high severity, and we know of no case where any of them was used against anyone. The downloads of the earlier versions have been taken off the Releases page.

At the same time the Git history was rewritten by the maintainer to remove a file that should not have been published. Every commit before 0.2.2 has a new ID, and the tags `v0.1.0`, `v0.2.0` and `v0.2.1` were moved to the new commits. If you noticed moved tags and wondered whether the repository was tampered with: this is the reason, and the exact differences are listed below so you can check them yourself. **If you only download the app, you can skip the Git part.**

## Who is affected

- **Everyone**: another account on the same Mac could keep the app from starting, and any program could hide the companion with a fake lock-screen notification (low).
- **If you installed the optional local chat**: the chat problems in the table below, including the helper sandbox.
- **If you installed the optional reading voice**: the helper sandbox, and with a voice installed by 0.2.0, the earlier voice sample.

## What 0.2.2 fixes

| Problem | Versions | Severity |
|---|---|---|
| **The helper sandbox could be escaped.** The local chat and reading-voice helpers run third-party runtime code in a sandbox that only denied network access. Code running inside a helper could start `/usr/bin/open` to make a program outside the sandbox go online, or leave a file that runs at the next login. This needs a flaw in the pinned runtime or model files first. Now the helpers also cannot start other programs, open apps or links, send Apple events, use the microphone or camera, change any app's settings or use the clipboard, and they can write only to their own folder inside your private temporary folder. | chat 0.1.0+, reading voice 0.2.0+ | Medium |
| **Pasted text could fake a system message.** Chat-template control tokens such as `<\|im_start\|>` in a message were treated as real turn boundaries; from 0.2.0 a fake turn could also stay in "What I remember about you". They are now neutralised in the app and in the chat helper. | chat 0.1.0+ | Medium |
| **The crisis line could be cut off or missed.** A long reply could push the support line out of the speech bubble, in both interface languages; Traditional Chinese, spaced-out words and many phrasings were not recognised. The line is now always shown in full, also when a reply is interrupted. | chat 0.2.0+ | Medium |
| **The 0.2.0 reading voice stayed in use after updating.** This is the earlier voice sample described below. 0.2.1 only suggested reinstalling (2.5 GB); 0.2.2 switches to the current voice on its own, without downloading anything. | reading voice installed by 0.2.0 | Medium |
| **Replies asking you to type a password were shown as is**, and from 0.2.0 "What I remember about you" also learned from pasted text and instructions. | chat 0.1.0+ | Low |
| **The component installers had no download size limit and read `~/.curlrc`.** This only matters while installing an optional component. | chat installer 0.1.0+, voice installer 0.2.0+ | Low |
| **Another account on the same Mac could keep the app from starting** (the single-instance lock was in the shared `/tmp`), and any program could hide the companion with a fake lock-screen notification. | 0.1.0+ | Low |
| **Release process:** the CI checkout kept a write token on disk during the build, and the release content check missed most of its own test cases. | — | Low |

Details are in the [0.2.2 changelog](../CHANGELOG.md).

## Why the Git history changed

0.2.0 shipped a reference voice sample (`voice/companion_voice.wav`) and its description (`voice/companion_voice.json`) that were not suitable for public distribution. 0.2.1 replaced them with a synthetic sample made from Qwen3-TTS's built-in speaker Serena, and the 0.2.0 download was withdrawn, but the old files were still in the Git history. To stop distributing them, the history was rewritten on 2026-11-19:

- in the two 0.2.0 commits, the old `voice/companion_voice.wav` and `voice/companion_voice.json` were removed;
- in the seven commits after the initial commit, two internal entries were removed from `scripts/audit_release.py`;
- the initial commit has exactly the same files. Its ID changed only because the signature GitHub added when it was created could not be kept, so it no longer shows as "Verified".

Authors, dates and commit messages are unchanged. Old and new commit IDs:

| Commit | Old | New | Tag |
|---|---|---|---|
| Initial commit | `c47a0f8` | `9ce009e` | |
| Release Desktop Companion 0.1.0 | `ef4b84a` | `03899e5` | |
| Bilingual offline documentation | `878e913` | `6ddeb71` | |
| Regression fixtures in both languages | `72b9437` | `3a9974c` | |
| Deterministic Bluetooth scheduling tests | `15d4b73` | `6674546` | `v0.1.0` |
| Desktop Companion 0.2.0 | `efa97d5` | `c802bc3` | |
| CI: check on macOS 15 and 26 | `0d917fe` | `f62fc5c` | `v0.2.0` |
| Desktop Companion 0.2.1 | `32be71d` | `5eca5a1` | `v0.2.1` |

Because the sample is gone, the `v0.2.0` tag can no longer be built from source; use 0.2.2.

### If you have a clone made before the rewrite

**Do not run `git pull` first.** If you already did, see the note in step 1.

1. Back up everything, then mark where you started:
   - `git bundle create ../before-rewrite.bundle --all` (a full copy of your clone; it still contains the removed sample, so keep it private);
   - `git branch old-upstream origin/main`.
   If you already ran `git pull` or `git fetch` after the rewrite, `origin/main` is already the new history. Use the old ID instead: `git branch old-upstream 32be71d`, or for a clone made before 0.2.1 the newest old ID from the table above for which `git cat-file -t <ID>` prints `commit`.
2. Fetch the new history: `git fetch origin --force --tags` (without `--force` the moved tags are refused).
3. Check the difference: `git diff --stat 32be71d 5eca5a1` (or the old and new IDs of the same row in the table) shows only `scripts/audit_release.py | 2 --`; for the two 0.2.0 commits it also lists the two removed voice files.
4. For each of your branches, see whether it has commits of your own: `git log --oneline old-upstream..<branch>`.
   - Some output: `git rebase --onto origin/main old-upstream <branch>`.
   - No output, on `main`: `git checkout main` and then `git reset --hard origin/main` (this discards uncommitted changes, so copy them first).
   - No output, any other branch: delete it with `git branch -D <branch>`.
5. Check that nothing else still holds the old history: `git for-each-ref --contains c47a0f8 --format='%(refname)'` should list only `refs/heads/old-upstream`.
   - Your own tags in the list: `git tag -d <tag>` (recreate them on the new commits if you need them).
   - `refs/stash`: `git stash pop` to get the changes back, then `git stash drop` for any that remain.
   - If `old-upstream` is not in the list, it was created after the new history arrived: redo step 1 with an old ID and repeat step 4.
   When the list shows only `old-upstream`, delete it with `git branch -D old-upstream`. Do not push it or the backup bundle anywhere.

If you ran `git pull` before following these steps, it most likely reported "refusing to merge unrelated histories", "divergent branches" or "Not possible to fast-forward". With `pull.rebase` set it may have succeeded and kept your commits; the tags still point to the old commits until step 2, and step 5 still applies. **Never use `--allow-unrelated-histories`**: it would merge the old history, and the removed sample, back in. If you pushed the old history somewhere else, replace it with the new one, and please do not re-upload the removed sample.

## What to do

1. **Update to 0.2.2.** Download it from [Releases](https://github.com/Bf190t/mac-desktop-companion/releases), quit the old app and replace it. Settings, "What I remember about you" and installed components are kept.
2. **If you used the local chat**, open "What I remember about you" once and delete anything you did not say yourself.
3. **If you installed the reading voice with 0.2.0**, 0.2.2 switches it to the current voice by itself (about 1–2 minutes, no download). The system voice reads until it is done.
4. **If you build from source or copied code from this project**, in particular the sandbox profile or the chat-template handling, take the 0.2.2 versions.

## Checking the 0.2.2 download

The 0.2.2 ZIP and its `.sha256` file are built and uploaded by the repository's CI from the `v0.2.2` tag, after the release content check runs again on the finished archive. The app is ad-hoc signed and not notarized by Apple; the checksum confirms that your download matches the release file, not who made it.

## Check your own apps the same way

This review was done with [app-security-review](https://github.com/Bf190t/app-security-review), an open-source skill for Claude Code and Codex by the same maintainer. It reviews code you own in an isolated copy, runs an offline scan, has separate reviewers reproduce every finding, and has the fixes checked again by reviewers who did not write them. The lessons from this review are included.

To report a security problem, see [SECURITY.md](../SECURITY.md).
