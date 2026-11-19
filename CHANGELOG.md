# Changelog

## 0.2.2 — 2026-11

A security review release. Nothing changes in how the companion looks or chats.

Earlier versions are affected (the notice lists which versions each problem affects); please update. Their downloads were taken off the Releases page, and the Git history was rewritten to remove the 0.2.0 reference voice sample, so every earlier commit has a new ID and the tags `v0.1.0`, `v0.2.0` and `v0.2.1` moved. See the [security notice](docs/SECURITY_NOTICE_2026-11.md) for the old and new commit IDs and how to update a clone.

### Security and privacy
- The local chat and reading-voice helpers run in a stricter sandbox. Besides having no network access, they can no longer start other programs, ask macOS to open apps or links, send Apple events, use the microphone or camera, change any app's preferences or use the pasteboard, or write anywhere except their own folder inside your private temporary folder (which is also their TMPDIR): with network denial alone, code inside a helper could start `/usr/bin/open` and let an app outside the sandbox go online, or leave a file that runs later. The reading-voice helper no longer inherits the app's environment variables.
- Chat-template control tokens (such as `<|im_start|>` or `<think>`) in messages, the persona and "What I remember about you" are neutralised, so pasted text cannot fake a system or assistant turn. The local chat worker does the same with its tokenizer's special-token list.
- "What I remember about you" no longer learns from quoted or pasted text, long messages or instructions to the companion (also in Traditional Chinese or reworded), and the prompt marks it as information, not instructions. Ordinary facts about yourself are still remembered.
- Replies that ask you to type or send a password, code or PIN are replaced with a warning (help such as how to reset a password is left alone); text-direction control characters are removed from replies.
- Crisis support: the support line is always shown in full in the speech bubble (long replies are shortened instead) and as its own line in the chat window, without being sent back to the model. It also appears when a reply is interrupted (memory pressure, lock screen, sleep). Recognition now covers Traditional Chinese, spaced-out or punctuated words, look-alike letters, invisible characters and many more phrasings in both languages, while everyday sentences ("the meeting is over", "I took some cold medicine") no longer trigger it. A message too long to send still gets the support line when it needs one.
- The single-instance lock lives in your own temporary folder instead of the shared `/tmp`, so another account cannot keep the app from starting. A lock-screen notification only hides the companion, or stops voice input and reading, once macOS itself reports the screen as locked.
- Optional-component downloads stop at their expected size, and the installers ignore `~/.curlrc`.
- Acceptance screenshots and reports are written atomically into owner-only folders.

### Voice
- A reading voice installed by 0.2.0 switches to the current voice on its own, without downloading anything: the bundled sample is copied in and the hourly chimes are recorded again on this Mac (about 1–2 minutes). The system voice reads until then. The switch swaps folders in one step, and an interrupted switch is repaired on the next start.

### Release checks
- `scripts/audit_release.py` pins the companion voice by SHA-256 (the file and its JSON record must match), rejects retired voice samples, accepts a private word list (`--deny-terms-file` or the `RELEASE_DENY_TERMS` environment variable, matched after Unicode normalisation and with spaces and punctuation removed), adds generic checks for e-mail addresses, tokens, home-folder paths, UTF-16/GB18030 text, look-alike letters, Base64 runs, PNG text chunks, any audio other than the pinned sample (recognised by file header) and nested archives (scanned inside, with size limits), and has a `history` mode that checks every blob in the Git history against a list of accepted past findings. CI audits the release package again right before uploading it.
- An offline static security scan (`scripts/security_scan.py`) runs with the headless tests; every reviewed finding is recorded with a reason in `scripts/security-scan-baseline.json`.

## 0.2.1 — 2026-11

### Voice
- Mochi has a new reading voice: Serena, one of Qwen3-TTS's built-in speakers, cloned by timbre from one synthetic sample (`voice/companion_voice.wav`). It replaces the earlier VoiceDesign sample.
- A reading voice installed by 0.2.0 keeps working with the previous voice; the chat window says so. Remove the reading voice and install it again to switch: this downloads the runtime and model again (about 2.5 GB) and records the hourly chimes with the new voice.

## 0.2.0 — 2026-11

### Chat
- New companion prompt: a short editable persona plus fixed capabilities and limits, the current date and time, a few example turns and a tone reminder next to the latest message. Mochi follows the language of each message and never plays a romantic partner.
- "Be there by 8:30, 40 minutes away, when should I get up?" — the app works out such times exactly (Chinese and English) and hands the result to the model.
- "What I remember about you": clear statements about yourself (name, likes, work) are remembered on this Mac and can be edited or cleared.
- When a message suggests someone is struggling, the reply ends with a verified crisis line for the Mac's region (20 regions; see docs/CRISIS_LINES.md).
- Time and date questions now reach the model, which knows the current time.
- Canned refusals no longer pile up in the model's context; a reply that hits the length cap keeps its finished sentences instead of being discarded; presence penalty replaces repetition penalty, which pushed the small model towards odd words and English.
- The model can start loading as soon as you type or click the microphone.

### Voice
- One window for chat and voice. Click once to record, click again to stop (up to 60 seconds); the foot-level microphone works the same way.
- macOS 26 or newer uses the system's on-device SpeechAnalyzer: only microphone permission, no Dictation needed. Recognition follows the interface language.
- Optional reading voice: Mochi's own voice (Qwen3-TTS 0.6B, on-device, streamed as it is generated), installed from the chat window. The hourly time can be spoken too, in Chinese or English, from clips recorded at install time. The system voice takes over whenever the reading voice is missing or fails.
- Reading cleans up emoji, stage directions and tildes; "3~5" is read as a range.

### Fixes
- The menu check marks follow the visible page of the status window; the status window and foot input stay above the pet.
- CPU readings appear about one second after opening the status window; newer Apple chips find their temperature sensors.
- The system voice follows the interface language (it was always Chinese).
- More robust voice capture: device changes (AirPods) keep recording, pauses no longer drop earlier sentences.

## 0.1.0 — 2026-10

First public release: original Mochi mascot, bilingual interface, computer and Bluetooth battery windows, optional local Qwen3-1.7B chat.
