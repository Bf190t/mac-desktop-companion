# Changelog

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
