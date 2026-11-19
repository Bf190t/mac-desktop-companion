"""Swift/Python parity for the text boundary (round 2 of the 2026-11 review).

ChatBoundaryTests writes the Swift results for every case in chat_boundary_cases.json; this test checks
that scripts/chat_boundary.py gives the same normalized forms, crisis decision, reply sanitizing and
pre-inference reply, and that the shared rule texts are character-for-character the same in both files.
Run: python3 -I scripts/tests/test_boundary_parity.py <swift-results.json>
"""
import importlib.util
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('chat_boundary', ROOT / 'scripts/chat_boundary.py')
boundary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(boundary)
SWIFT_RESULTS = None
SHARED = {'crisis': 'CRISIS', 'crisisEN': 'CRISIS_EN', 'crisisCompact': 'CRISIS_COMPACT', 'askZH': 'ASK_ZH',
          'askEN': 'ASK_EN', 'elsewhere': 'ELSEWHERE', 'negated': 'NEGATED', 'reassure': 'REASSURE'}


class ParityTests(unittest.TestCase):
    def test_rule_texts_are_identical(self):
        swift = (ROOT / 'app/Sources/ChatBoundary.swift').read_text()
        for swift_name, py_name in SHARED.items():
            with self.subTest(rule=swift_name):
                found = re.search(r'static let ' + swift_name + r' = #"(.*?)"#\n', swift)
                self.assertIsNotNone(found)
                self.assertEqual(found.group(1), getattr(boundary, py_name))
        table = re.search(r'traditional = scalarMap\("(.*?)", "(.*?)"\)', swift)
        self.assertEqual(str.maketrans(table.group(1), table.group(2)), boundary._TRADITIONAL)
        glyphs = re.search(r'homoglyphs = scalarMap\("(.*?)", "(.*?)"\)', swift)
        self.assertEqual(str.maketrans(glyphs.group(1), glyphs.group(2)), boundary._HOMOGLYPHS)

    def test_same_results_on_every_case(self):
        cases = json.loads((Path(__file__).with_name('chat_boundary_cases.json')).read_text())['cases']
        self.assertEqual(set(SWIFT_RESULTS), {c['id'] for c in cases})
        for case in cases:
            swift, text = SWIFT_RESULTS[case['id']], case['input']
            with self.subTest(case=case['id']):
                self.assertEqual(boundary.normalized_forms(text), swift['forms'])
                self.assertEqual(boundary.needs_crisis_support(text), swift['crisis'])
                if case['stage'] in ('post', 'reply', 'crisis'):
                    self.assertEqual(boundary.sanitize_reply(text), swift['sanitized'])
                if case['stage'] == 'pre':
                    self.assertEqual(boundary.reply_before_inference(text), swift['pre'])


if __name__ == '__main__':
    SWIFT_RESULTS = json.loads(Path(sys.argv.pop(1)).read_text())
    unittest.main()
