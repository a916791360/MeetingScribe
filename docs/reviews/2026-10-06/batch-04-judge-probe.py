#!/usr/bin/env python3
"""Pure mocks: no personal model config, Keychain, corpus or network access."""
import importlib.util
import pathlib
from types import SimpleNamespace
from unittest.mock import patch

repo = pathlib.Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("review_judge", repo / "Scripts/llm_judge.py")
judge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(judge)
fake_key = "REVIEW_SYNTHETIC_PROVIDER_A_KEY"
mock_models = [{"id": "synthetic-model", "url": "https://provider-a.invalid/v1", "apiKey": fake_key}]
args = SimpleNamespace(model="synthetic-model", base_url="https://provider-b.invalid/v1")

with patch.dict("os.environ", {}, clear=True), \
        patch.object(judge, "workbuddy_models", return_value=mock_models), \
        patch.object(judge, "keychain_lookup", side_effect=AssertionError("Unexpected Keychain access")):
    base, model, key, origin = judge.resolve_judge(args)
    assert base == "https://provider-b.invalid/v1"
    assert key == fake_key
    print("PASS: explicit provider B endpoint is paired with mocked provider A credential")
    print(f"resolved model={model}; origin label={origin}")

def fake_urlopen(request, **kwargs):
    assert request.full_url == "https://provider-b.invalid/v1/chat/completions"
    assert request.get_header("Authorization") == "Bearer " + fake_key
    raise RuntimeError("Review mock intercepted before network access")

with patch.object(judge.urllib.request, "urlopen", side_effect=fake_urlopen):
    try:
        judge.call_judge(base, model, key, "SYNTHETIC REVIEW PROMPT", retries=0)
    except RuntimeError as error:
        assert "Review mock intercepted" in str(error)
        print("PASS: call_judge constructs provider B request with provider A Bearer; no request sent")
    else:
        raise AssertionError("Expected mock interception")
