#!/usr/bin/env python3
"""Credential pairing tests: mocks only, no personal configuration or network."""
import importlib.util
import pathlib
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("llm_judge", pathlib.Path(__file__).resolve().parents[1] / "llm_judge.py")
judge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(judge)


class JudgeCredentialTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict("os.environ", {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.entries = [{"id": "synthetic-model", "url": "https://provider-a.invalid/v1", "apiKey": "FAKE_A"}]
        self.config = patch.object(judge, "workbuddy_models", return_value=self.entries)
        self.config.start()
        self.addCleanup(self.config.stop)
        self.keychain = patch.object(judge, "keychain_lookup", side_effect=AssertionError("must not borrow unbound credentials"))
        self.keychain.start()
        self.addCleanup(self.keychain.stop)

    def args(self, base=None):
        return SimpleNamespace(model="synthetic-model", base_url=base)

    def test_other_endpoint_cannot_borrow_key(self):
        with self.assertRaises(ValueError):
            judge.resolve_judge(self.args("https://provider-b.invalid/v1"))

    def test_exact_endpoint_can_select_its_config(self):
        base, _, key, _ = judge.resolve_judge(self.args("https://provider-a.invalid/v1/"))
        self.assertEqual(base.rstrip("/"), self.entries[0]["url"])
        self.assertEqual(key, "FAKE_A")

    def test_complete_environment_is_kept_together(self):
        with patch.dict("os.environ", {"MS_JUDGE_BASE_URL": "https://provider-b.invalid/v1", "MS_JUDGE_KEY": "FAKE_B"}):
            base, _, key, _ = judge.resolve_judge(self.args())
        self.assertEqual((base, key), ("https://provider-b.invalid/v1", "FAKE_B"))

    def test_key_without_endpoint_is_rejected(self):
        with patch.dict("os.environ", {"MS_JUDGE_KEY": "FAKE_B"}), self.assertRaises(ValueError):
            judge.resolve_judge(self.args())

    def test_complete_workbuddy_config_is_kept_together(self):
        base, _, key, _ = judge.resolve_judge(self.args())
        self.assertEqual((base, key), (self.entries[0]["url"], "FAKE_A"))


if __name__ == "__main__":
    unittest.main()
