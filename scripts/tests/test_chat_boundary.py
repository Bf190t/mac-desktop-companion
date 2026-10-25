import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('chat_boundary', ROOT / 'scripts/chat_boundary.py')
boundary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boundary)


class BoundaryTests(unittest.TestCase):
    def test_behavior_cases(self):
        cases = json.loads((Path(__file__).with_name('chat_boundary_cases.json')).read_text())['cases']
        aliases = {'allow': None, 'status': boundary.STATUS_REPLY, 'bluetooth': boundary.BLUETOOTH_REPLY,
                   'action': boundary.ACTION_REPLY, 'unfinished': boundary.UNFINISHED_REPLY, 'long': boundary.LONG_REPLY,
                   'identity':boundary.IDENTITY_REPLY,'model':boundary.MODEL_REPLY,'capability':boundary.CAPABILITY_REPLY,
                   'prompt':boundary.PROMPT_REPLY,'text_input':boundary.TEXT_INPUT_REPLY,'weather':boundary.WEATHER_REPLY,'clock':boundary.CLOCK_REPLY}
        for case in cases:
            with self.subTest(case=case['id']):
                expected = aliases.get(case['expected'], case['expected'])
                actual = boundary.reply_before_inference(case['input']) if case['stage'] == 'pre' else boundary.sanitize_reply(case['input'])
                self.assertEqual(actual, expected)
                if case['stage'] == 'post':
                    self.assertLessEqual(len(actual), 120)

    def test_default_prompt_matches_artifact(self):
        path = ROOT / 'chat/persona/integrated-v1.txt'
        self.assertEqual(boundary.DEFAULT_PERSONA, path.read_text().strip())
        self.assertNotIn('用户：', boundary.DEFAULT_PERSONA)
        self.assertNotIn('回答：', boundary.DEFAULT_PERSONA)



if __name__ == '__main__':
    unittest.main()
