#!/usr/bin/env python3
"""Reading-voice helper for Desktop Companion: Qwen3-TTS 0.6B through MLX, fully offline.

The companion's voice ("companion") was designed once with the Qwen3-TTS 1.7B VoiceDesign model (a clear,
slightly high young voice with an even tone) and is cloned here by its speaker embedding with the 0.6B
Base model and companion_voice.wav: the timbre only, the model's own rhythm. CustomVoice models still
work with their built-in speakers.

The app starts this with the optional voice runtime it installed under Application Support and talks
to it with one JSON object per line.

  stdin   {"op": "speak", "id": "7", "text": "…", "voice": "companion", "language": "chinese"}
          {"op": "cancel", "id": "7"}          {"op": "quit"}
  stdout  {"event": "loading"}
          {"event": "ready", "sample_rate": 24000, "voices": [...], "load_seconds": 1.8}
          {"event": "audio", "id": "7", "pcm": "<base64, 16-bit little-endian mono>"}   (streamed)
          {"event": "done", "id": "7", "audio_seconds": …, "generation_seconds": …, "first_audio_seconds": …,
           "parts": n, "limited": 0}
          {"event": "cancelled", "id": "7"}
          {"event": "error", "id": "7", "code": "…", "detail": "…"}

A newer speak request cancels the one still in progress. The helper exits when stdin closes, on
"quit", or when the app's process is gone.
"""
from __future__ import annotations

import argparse
import base64
import json
import math
import os
import queue
import re
import sys
import threading
import time

DEFAULT_VOICE = "companion"
LANGUAGES = {"chinese", "english"}
SEED = 82040                  # same voice colour every time
STREAM_INTERVAL = 0.32        # seconds of audio per streamed chunk (measured: first sound ~0.12 s)
CACHE_LIMIT = 256 * 1024 * 1024  # keeps the helper near 3 GB instead of ~6 GB
MAX_PART = 80                 # characters per generation; longer replies are cut at sentence ends

# Quotes and title marks are not read; on their own they made Qwen3-TTS produce 1-6 s of noise.
_DROP = str.maketrans("", "", "“”‘’「」『』《》〈〉\"")
_PAUSES = re.compile(r"(?:…+|\.{3,}|—{2,}|-{2,}|～+|~+)")
_SENTENCE_END = "。！？!?；;\n"
# "8:30" was read unreliably (dropped at the start of a sentence, "7:30" heard as "7:00翻"), so clock
# times are written out the way people say them: 8点半, 7点50分, 9点, 7点零5分.
_CLOCK = re.compile(r"(?<![\d:：])([01]?\d|2[0-3])[:：]([0-5]\d)(?![\d:：])")


def _clock(match: re.Match) -> str:
    hour, minute = int(match.group(1)), int(match.group(2))
    if minute == 0:
        return f"{hour}点"
    if minute == 30:
        return f"{hour}点半"
    return f"{hour}点零{minute}分" if minute < 10 else f"{hour}点{minute}分"


def prepare_text(text: str, language: str = "chinese") -> str:
    """What is sent to the model. Words are never changed; only marks it handles badly and, in
    Chinese, clock times."""
    value = (text or "").translate(_DROP)
    if language == "chinese":
        value = _CLOCK.sub(_clock, value)
    value = _PAUSES.sub("，", value)
    value = re.sub(r"[ \t　]+", " ", value).strip()
    value = re.sub(r"[，,、]+(?=[，,。！？!?；;：:])", "", value)      # comma right before other punctuation
    value = re.sub(r"^[，,、。；;：:！？!?\s]+", "", value)              # nothing to say before the first word
    return value


def speakable(text: str) -> bool:
    return any(ch.isalnum() for ch in text)


def _glue(a: str, b: str) -> str:
    """Joins two pieces; Latin words keep a space between them ("Really? Yes!")."""
    if a and b and a[-1].isascii() and not a[-1].isspace() and b[0].isascii() and b[0].isalnum():
        return a + " " + b
    return a + b


def split_parts(text: str, maximum: int = MAX_PART) -> list[str]:
    """Sentences packed into parts of at most `maximum` characters. A part with no letters or
    digits (a lone "。" or "）") is glued to the part before it instead of being spoken."""
    sentences, start = [], 0
    for i, ch in enumerate(text):
        if ch in _SENTENCE_END:
            sentences.append(text[start:i + 1]); start = i + 1
    if start < len(text):
        sentences.append(text[start:])
    pieces = []
    for sentence in sentences:
        while len(sentence) > maximum:
            window = sentence[:maximum]
            cut = max(window.rfind("，"), window.rfind(","), window.rfind("、"), window.rfind(" "))
            cut = cut + 1 if cut >= maximum // 3 else maximum
            pieces.append(sentence[:cut]); sentence = sentence[cut:]
        if sentence:
            pieces.append(sentence)
    parts: list[str] = []
    for piece in pieces:
        piece = piece.strip()
        if not piece:
            continue
        if not speakable(piece):
            if parts:
                parts[-1] += piece
            continue
        if parts and len(parts[-1]) + len(piece) < maximum:
            parts[-1] = _glue(parts[-1], piece)
        else:
            parts.append(piece)
    return parts


def duration_limit(text: str) -> float:
    """Longest believable reading of `text`, in seconds. Measured readings run 0.20-0.25 s per
    character; past this the model is rambling (it can keep going when it misses the end)."""
    spoken = sum(ch.isalnum() for ch in text)
    return max(4.0, spoken * 0.45 + 4.0)


def token_limit(text: str) -> int:
    return math.ceil(duration_limit(text) * 12.5)     # the 12 Hz codec makes 12.5 tokens per second


class Voices:
    """The voices the loaded model offers and how to stream one."""

    def __init__(self, model, reference=None):
        self.model, self.reference = model, reference
        self.clone = getattr(getattr(model, "config", None), "tts_model_type", "") == "base"

    def names(self) -> list[str]:
        if self.clone:
            return [DEFAULT_VOICE] if self.reference is not None else []
        return sorted(v.lower() for v in self.model.get_supported_speakers())

    def stream(self, voice: str, text: str, max_tokens: int, language: str = "chinese"):
        if self.clone:   # speaker embedding from the reference only, no reference text
            return self.model.generate(text=text, ref_audio=self.reference, lang_code=language, stream=True,
                                       streaming_interval=STREAM_INTERVAL, max_tokens=max_tokens)
        return self.model.generate_custom_voice(text=text, speaker=voice, language=language.capitalize(), stream=True,
                                                streaming_interval=STREAM_INTERVAL, max_tokens=max_tokens)


class Output:
    """The only writer of real stdout; library chatter goes to stderr."""

    def __init__(self, stream):
        self.stream, self.lock = stream, threading.Lock()

    def emit(self, value: dict) -> None:
        line = json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n"
        with self.lock:
            self.stream.write(line); self.stream.flush()


class Requests:
    """Reads stdin on its own thread so a cancel arrives while audio is being generated."""

    def __init__(self, stream):
        self.queue: queue.Queue = queue.Queue()
        self.cancelled: set[str] = set()
        self.active: set[str] = set()
        self.lock = threading.Lock()
        self.stream = stream

    def is_cancelled(self, rid: str) -> bool:
        with self.lock:
            return rid in self.cancelled

    def finished(self, rid: str) -> None:
        with self.lock:
            self.active.discard(rid); self.cancelled.discard(rid)

    def handle(self, message: dict) -> bool:
        op = message.get("op")
        if op == "speak":
            rid = str(message.get("id", ""))
            with self.lock:
                self.cancelled |= self.active            # the newest reply wins
                self.active.add(rid)
            self.queue.put(message)
        elif op == "cancel":
            with self.lock:
                target = message.get("id")
                self.cancelled |= ({str(target)} if target is not None else set(self.active))
        elif op == "quit":
            return False
        return True

    def run(self) -> None:
        for raw in self.stream:
            try:
                message = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if isinstance(message, dict) and not self.handle(message):
                break
        self.queue.put(None)


def speak(voices: Voices, request: dict, requests: Requests, out: Output, np, mx) -> None:
    rid = str(request.get("id", ""))
    if requests.is_cancelled(rid):
        out.emit({"event": "cancelled", "id": rid}); return
    voice = str(request.get("voice") or DEFAULT_VOICE).lower()
    if voice not in voices.names():
        out.emit({"event": "error", "id": rid, "code": "unknown_voice", "detail": voice}); return
    language = str(request.get("language") or "chinese").lower()
    if language not in LANGUAGES:
        language = "chinese"
    parts = split_parts(prepare_text(str(request.get("text", "")), language))
    rate = int(voices.model.sample_rate)
    started, first, total, limited = time.monotonic(), None, 0.0, 0
    for part in parts:
        limit, produced = duration_limit(part), 0.0
        mx.random.seed(SEED)
        generator = voices.stream(voice, part, token_limit(part), language)
        try:
            for result in generator:
                if requests.is_cancelled(rid):
                    out.emit({"event": "cancelled", "id": rid}); return
                audio = np.asarray(result.audio, dtype=np.float32).reshape(-1)
                if audio.size == 0:
                    continue
                if not np.isfinite(audio).all():
                    out.emit({"event": "error", "id": rid, "code": "non_finite_audio"}); return
                room = int(max(0.0, limit - produced) * rate)
                cut = audio.size > room
                if cut:
                    audio = audio[:room]
                if audio.size:
                    pcm = (np.clip(audio, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
                    out.emit({"event": "audio", "id": rid, "pcm": base64.b64encode(pcm).decode("ascii")})
                    if first is None:
                        first = time.monotonic() - started
                    produced += audio.size / rate
                if cut:
                    limited += 1; break
        finally:
            generator.close()
        total += produced
    mx.clear_cache()
    out.emit({"event": "done", "id": rid, "audio_seconds": round(total, 3),
              "generation_seconds": round(time.monotonic() - started, 3),
              "first_audio_seconds": round(first, 3) if first is not None else None,
              "parts": len(parts), "limited": limited})


def watch_parent(pid: int) -> None:
    while True:
        time.sleep(2)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            os._exit(0)
        except PermissionError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--parent-pid", type=int, default=0)
    parser.add_argument("--voice-ref", help="reference audio of the companion's designed voice (Base models)")
    parser.add_argument("--deps", help="folder with the installed Python packages")
    args = parser.parse_args()
    for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY", "DO_NOT_TRACK"):
        os.environ[key] = "1"
    if args.deps:
        sys.path.insert(0, args.deps)
    # The protocol gets its own copy of fd 1, and fd 1 itself now points at stderr, so nothing a
    # library prints (Python or C) can land in the middle of a JSON line.
    out = Output(os.fdopen(os.dup(1), "w", encoding="ascii", buffering=1))
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    if args.parent_pid > 0:
        threading.Thread(target=watch_parent, args=(args.parent_pid,), daemon=True).start()
    requests = Requests(sys.stdin.buffer)
    threading.Thread(target=requests.run, daemon=True).start()
    out.emit({"event": "loading"})
    try:
        started = time.monotonic()
        import numpy as np
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model
        mx.set_cache_limit(CACHE_LIMIT)
        model = load_model(args.model_path)
        reference = None
        if args.voice_ref:
            from mlx_audio.utils import load_audio
            reference = load_audio(args.voice_ref, sample_rate=int(model.sample_rate))
        voices = Voices(model, reference)
        if not voices.names():
            raise FileNotFoundError("voice reference")
        # One short warm-up so the first real reply starts as fast as the rest (~0.12 s, not ~0.3 s).
        for _ in voices.stream(voices.names()[0], "嗯。", 40):
            pass
        mx.clear_cache()
        out.emit({"event": "ready", "sample_rate": int(model.sample_rate), "voices": voices.names(),
                  "load_seconds": round(time.monotonic() - started, 2)})
    except Exception as exc:  # the model inputs and environment are not echoed
        out.emit({"event": "error", "code": "model_load", "detail": type(exc).__name__})
        return 1
    while (request := requests.queue.get()) is not None:
        rid = str(request.get("id", ""))
        try:
            speak(voices, request, requests, out, np, mx)
        except Exception as exc:
            out.emit({"event": "error", "id": rid, "code": "generation_failed", "detail": type(exc).__name__})
        finally:
            requests.finished(rid)
    return 0


if __name__ == "__main__":
    # os._exit, not a normal exit: the stdin reader is a daemon thread that may be blocked in a read,
    # and interpreter shutdown then aborts ("could not acquire lock for <stdin>", exit 134), which
    # macOS can report as a crash. Every protocol line is already flushed.
    code = main()
    sys.stderr.flush()
    os._exit(code)
