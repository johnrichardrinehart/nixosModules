import unittest

import dictation_lib as dlib


class CommandPhraseMatchesTest(unittest.TestCase):
    def test_matches_exact_phrase(self):
        self.assertTrue(dlib.command_phrase_matches("Stop dictation", "stop dictation"))

    def test_matches_phrase_with_surrounding_words(self):
        self.assertTrue(
            dlib.command_phrase_matches("Please stop dictation now", "stop dictation")
        )

    def test_matches_common_stop_phrase_mistranscription(self):
        self.assertTrue(
            dlib.command_phrase_matches("Stopped dicatation", "stop dictation")
        )

    def test_rejects_partial_phrase(self):
        self.assertFalse(dlib.command_phrase_matches("Stop", "stop dictation"))

    def test_rejects_unrelated_phrase(self):
        self.assertFalse(dlib.command_phrase_matches("Stop typing", "stop dictation"))


if __name__ == "__main__":
    unittest.main()
