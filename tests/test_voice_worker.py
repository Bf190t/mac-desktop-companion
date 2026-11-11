"""Tests for the reading-voice helper (voice/tts_worker.py) without loading a model.

The text tests need only the standard library. The streaming tests need numpy; they are skipped
when it is missing (the plain macOS python3 used by CI), and run with the installed voice runtime:
  ~/Library/Application\\ Support/io.github.bf190t.desktop-companion/Voice/python-base/bin/python3.12 -I \\
      tests/test_voice_worker.py   (with that installation's deps folder on sys.path)
"""
import base64
import io
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "voice"))
import tts_worker as w  # noqa: E402

try:
    import numpy as np
except ImportError:  # pragma: no cover - CI without numpy
    np = None

RATE = 24000


class FakeMX:
    class random:
        @staticmethod
        def seed(_):
            pass

    @staticmethod
    def clear_cache():
        pass


class Result:
    def __init__(self, seconds):
        self.audio = np.full(int(seconds * RATE), 0.1, dtype=np.float32)


class FakeModel:
    """A CustomVoice-style model with built-in speakers."""
    sample_rate = RATE

    def __init__(self, seconds_per_char=0.22, runaway=False, on_chunk=None):
        self.seconds_per_char, self.runaway, self.on_chunk, self.calls = seconds_per_char, runaway, on_chunk, []

    def get_supported_speakers(self):
        return ["Uncle_Fu", "Serena"]

    def generate_custom_voice(self, **options):
        self.calls.append(options)
        remaining = len(options["text"]) * self.seconds_per_char
        index = 0
        while self.runaway or remaining > 0:
            chunk = w.STREAM_INTERVAL if self.runaway else min(w.STREAM_INTERVAL, remaining)
            remaining -= chunk
            index += 1
            if self.on_chunk:
                self.on_chunk(index)
            yield Result(chunk)


class FakeBase(FakeModel):
    """The 0.6B Base model: no built-in speakers, cloned from reference audio."""

    class config:
        tts_model_type = "base"

    def get_supported_speakers(self):
        return []

    def generate(self, **options):
        return self.generate_custom_voice(**options)


def run(model, request, requests=None, reference=None):
    buffer = io.StringIO()
    requests = requests or w.Requests(io.BytesIO())
    w.speak(w.Voices(model, reference), request, requests, w.Output(buffer), np, FakeMX)
    return [json.loads(line) for line in buffer.getvalue().splitlines()]


class TextTests(unittest.TestCase):
    def test_quotes_and_title_marks_dropped(self):
        self.assertEqual(w.prepare_text("“《夜行列车》怎么样？”"), "夜行列车怎么样？")

    def test_ellipsis_becomes_pause(self):
        self.assertEqual(w.prepare_text("嗯……好吧"), "嗯，好吧")

    def test_lonely_punctuation(self):
        self.assertEqual(w.prepare_text("”"), "")
        self.assertEqual(w.prepare_text("……"), "")
        self.assertEqual(w.prepare_text("，，好的。"), "好的。")

    def test_clock_times_in_chinese_only(self):
        self.assertEqual(w.prepare_text("8:30 到公司，最晚 7:50 出门，9:00 开会，7:05 起。"),
                         "8点半 到公司，最晚 7点50分 出门，9点 开会，7点零5分 起。")
        self.assertEqual(w.prepare_text("Meet at 8:30, leave by 7:50.", "english"), "Meet at 8:30, leave by 7:50.")
        self.assertEqual(w.prepare_text("比分 3:2，时长 1:23:45"), "比分 3:2，时长 1:23:45")

    def test_words_and_numbers_kept(self):
        text = "路上 40 分钟，打 Lifeline 13 11 14。"
        self.assertEqual(w.prepare_text(text), text)

    def test_no_punctuation_only_part(self):
        parts = w.split_parts(w.prepare_text("“《夜行列车》怎么样？那种感觉，最适合现在了。”"))
        self.assertTrue(parts and all(w.speakable(p) for p in parts))

    def test_long_reply_split_at_sentence_ends(self):
        sentence = "今天的风有点大，出门记得多穿一件外套。"
        parts = w.split_parts(sentence * 8)
        self.assertGreater(len(parts), 1)
        self.assertTrue(all(len(p) <= w.MAX_PART for p in parts))
        self.assertEqual("".join(parts), sentence * 8)

    def test_latin_sentences_keep_their_space(self):
        self.assertEqual(w.split_parts("Really? Yes!"), ["Really? Yes!"])

    def test_limits(self):
        self.assertEqual(w.duration_limit("嗯。"), 4.45)
        self.assertEqual(w.token_limit("嗯"), 56)

    def test_default_voice_and_languages(self):
        self.assertEqual(w.DEFAULT_VOICE, "companion")
        self.assertEqual(w.LANGUAGES, {"chinese", "english"})

    def test_newer_request_cancels_older(self):
        requests = w.Requests(io.BytesIO())
        requests.handle({"op": "speak", "id": "a"})
        requests.handle({"op": "speak", "id": "b"})
        self.assertTrue(requests.is_cancelled("a"))
        self.assertFalse(requests.is_cancelled("b"))

    def test_reader_handles_bad_lines_and_quit(self):
        requests = w.Requests(io.BytesIO(b'not json\n{"op":"speak","id":"7","text":"hi"}\n{"op":"quit"}\n{"op":"speak","id":"8"}\n'))
        requests.run()
        self.assertEqual(requests.queue.get()["id"], "7")
        self.assertIsNone(requests.queue.get())


@unittest.skipUnless(np is not None, "numpy is not installed")
class SpeakTests(unittest.TestCase):
    def test_cloned_voice_streams_and_finishes(self):
        model, reference = FakeBase(), np.zeros(RATE, dtype=np.float32)
        events = run(model, {"id": "1", "text": "今天辛苦了，早点休息。"}, reference=reference)
        self.assertEqual(events[-1]["event"], "done")
        self.assertGreater([e["event"] for e in events].count("audio"), 3)
        self.assertEqual(len(base64.b64decode(events[0]["pcm"])) % 2, 0)
        call = model.calls[0]
        self.assertIs(call["ref_audio"], reference)
        self.assertEqual(call["lang_code"], "chinese")
        self.assertNotIn("ref_text", call)

    def test_english_request(self):
        model = FakeBase()
        run(model, {"id": "2", "text": "See you at 8:30.", "language": "english"}, reference=np.zeros(10))
        self.assertEqual(model.calls[0]["lang_code"], "english")
        self.assertEqual(model.calls[0]["text"], "See you at 8:30.")

    def test_unknown_language_falls_back(self):
        model = FakeBase()
        run(model, {"id": "3", "text": "好。", "language": "klingon"}, reference=np.zeros(10))
        self.assertEqual(model.calls[0]["lang_code"], "chinese")

    def test_runaway_is_cut_at_the_limit(self):
        events = run(FakeBase(runaway=True), {"id": "4", "text": "好的。"}, reference=np.zeros(10))
        self.assertEqual(events[-1]["limited"], 1)
        self.assertAlmostEqual(events[-1]["audio_seconds"], w.duration_limit("好的。"), places=2)

    def test_cancel_stops_mid_stream(self):
        requests = w.Requests(io.BytesIO())
        requests.handle({"op": "speak", "id": "5"})
        model = FakeBase(on_chunk=lambda i: i == 3 and requests.handle({"op": "cancel", "id": "5"}))
        events = run(model, {"id": "5", "text": "这是一句比较长的话，用来测试中途停止。"}, requests, reference=np.zeros(10))
        self.assertEqual(events[-1], {"event": "cancelled", "id": "5"})

    def test_reference_required_for_cloning(self):
        self.assertEqual(w.Voices(FakeBase(), None).names(), [])
        events = run(FakeBase(), {"id": "6", "text": "你好"})
        self.assertEqual(events[0]["code"], "unknown_voice")

    def test_custom_voice_models_still_work(self):
        model = FakeModel()
        run(model, {"id": "7", "text": "好。", "voice": "Serena", "language": "english"})
        self.assertEqual(model.calls[0]["speaker"], "serena")
        self.assertEqual(model.calls[0]["language"], "English")

    def test_nothing_to_say(self):
        model = FakeBase()
        events = run(model, {"id": "8", "text": "”……"}, reference=np.zeros(10))
        self.assertEqual(model.calls, [])
        self.assertEqual(events[-1]["audio_seconds"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
