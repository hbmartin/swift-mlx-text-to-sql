"""Qualification requires immutable, comparable runtime evidence."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "tools/compare_prefill_chunking.py"
SPEC = importlib.util.spec_from_file_location("prefill_gate", SCRIPT)
assert SPEC and SPEC.loader
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class ComparePrefillChunkingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = self.root / "creg-eval-cli"
        self.binary.write_bytes(b"one optimized binary")
        self.binary_hash = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.items = [
            {"id": f"G-{index:03d}", "predictedSQL": f"SELECT {index}",
             "ex": index < 100, "validSQL": True}
            for index in range(200)
        ]
        self.qualified = self.write_run("qualified", "remainder", self.items)
        self.remainder = self.write_run("remainder", "remainder", self.items)
        self.balanced = self.write_run("balanced", "balanced", self.items)

    def write_run(
        self,
        name: str,
        chunking: str,
        results: list[dict],
        *,
        executable_sha256: str | None = None,
        fallback: dict | None = None,
        settings_overrides: dict | None = None,
    ) -> Path:
        path = self.root / f"{name}.json"
        settings = {key: "off" for key in GATE.REQUIRED_EFFECTIVE_SETTINGS}
        settings["prefillChunking"] = chunking
        settings["fallbackModelKey"] = "none"
        settings["fallbackModelRevision"] = "none"
        provenance = {
            "modelDirectorySHA256": "a" * 64,
            "systemPromptSHA256": "b" * 64,
            "schemaPromptSHA256": "c" * 64,
            "grammarSHA256": "d" * 64,
            "gold": {"sha256": "e" * 64},
            "database": {"sha256": "f" * 64},
            "packageLock": {"sha256": "1" * 64},
            "executable": {"sha256": executable_sha256 or self.binary_hash},
        }
        if fallback is not None:
            settings["fallbackModelKey"] = fallback.get("key", "fallback-model")
            settings["fallbackModelRevision"] = fallback.get("revision", "2" * 40)
            if "repository" in fallback:
                settings["fallbackModelRepository"] = fallback["repository"]
            if "digest" in fallback:
                provenance["fallbackModelDirectorySHA256"] = fallback["digest"]
        settings.update(settings_overrides or {})
        provenance["effectiveSettings"] = settings
        path.write_text(json.dumps({
            "schemaVersion": 3,
            "command": [str(self.binary)],
            "summary": {
                "itemCount": 200, "model": {"key": "pinned"},
                "gcd": "off", "temperature": 0, "seed": 0,
                "topP": 1, "topK": 0, "maxTokens": 128,
                "rowCap": 10000, "prefillChunking": chunking,
            },
            "provenance": provenance,
            "results": results,
        }))
        return path

    def gate(self) -> tuple[subprocess.CompletedProcess[str], dict]:
        report_path = self.root / "report.json"
        result = subprocess.run(
            [sys.executable, str(SCRIPT),
             "--qualified", str(self.qualified),
             "--balanced", str(self.balanced),
             "--remainder", str(self.remainder),
             "--binary", str(self.binary),
             "--out", str(report_path)],
            cwd=self.root, capture_output=True, text=True, check=False,
        )
        return result, json.loads(report_path.read_text())

    def test_identical_evidence_passes_outside_repo_root(self) -> None:
        result, report = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["status"], "passed")

    def test_aggregate_tie_with_one_item_loss_is_blocked(self) -> None:
        balanced_items = [dict(item) for item in self.items]
        balanced_items[0]["ex"] = False
        balanced_items[100]["ex"] = True
        self.write_run("balanced", "balanced", balanced_items)
        result, report = self.gate()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report["balancedLossesAgainstRemainder"]["ex"], ["G-000"])

    def test_missing_runtime_hash_blocks_historical_run(self) -> None:
        data = json.loads(self.qualified.read_text())
        del data["provenance"]["executable"]
        self.qualified.write_text(json.dumps(data))
        result, report = self.gate()
        self.assertEqual(result.returncode, 2)
        self.assertIn("candidate.provenance.executable.sha256.missing",
                      report["qualifiedIdentityMismatches"])

    def test_changed_effective_kv_setting_blocks(self) -> None:
        data = json.loads(self.remainder.read_text())
        data["provenance"]["effectiveSettings"]["kvBits"] = "4"
        self.remainder.write_text(json.dumps(data))
        result, report = self.gate()
        self.assertEqual(result.returncode, 2)
        self.assertIn("effectiveSettings.kvBits",
                      report["sameBinaryControlIdentityMismatches"])

    def test_changed_binary_blocks(self) -> None:
        self.binary.write_bytes(b"different optimized binary")
        result, report = self.gate()
        self.assertEqual(result.returncode, 2)
        self.assertIn("balanced.executableSHA256",
                      report["sameBinaryControlIdentityMismatches"])
        self.assertIn("remainder.executableSHA256",
                      report["sameBinaryControlIdentityMismatches"])

    def test_qualified_baseline_from_another_binary_passes_with_disclosure(self) -> None:
        other_binary = hashlib.sha256(b"the qualified binary").hexdigest()
        self.write_run(
            "qualified", "remainder", self.items, executable_sha256=other_binary)
        result, report = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["qualifiedIdentityMismatches"], [])
        self.assertTrue(report["qualifiedBinaryDiffers"])
        self.assertEqual(report["qualifiedBinarySHA256"], other_binary)
        self.assertEqual(report["binarySHA256"], self.binary_hash)
        self.assertEqual(report["sameBinaryControlIdentityMismatches"], [])

    def test_cross_binary_qualified_baseline_still_blocks_on_item_losses(self) -> None:
        other_binary = hashlib.sha256(b"the qualified binary").hexdigest()
        qualified_items = [dict(item) for item in self.items]
        qualified_items[150]["ex"] = True
        self.write_run(
            "qualified", "remainder", qualified_items, executable_sha256=other_binary)
        result, report = self.gate()
        self.assertEqual(result.returncode, 2)
        self.assertTrue(report["qualifiedBinaryDiffers"])
        self.assertEqual(report["balancedLossesAgainstQualified"]["ex"], ["G-150"])

    def test_cross_binary_qualified_baseline_still_needs_matching_inputs(self) -> None:
        other_binary = hashlib.sha256(b"the qualified binary").hexdigest()
        self.write_run(
            "qualified", "remainder", self.items, executable_sha256=other_binary,
            settings_overrides={"ngramDraftCorpusSHA256": "9" * 64})
        result, report = self.gate()
        self.assertEqual(result.returncode, 2)
        self.assertIn("effectiveSettings.ngramDraftCorpusSHA256",
                      report["qualifiedIdentityMismatches"])

    def test_same_binary_control_from_another_binary_blocks(self) -> None:
        other_binary = hashlib.sha256(b"a different control binary").hexdigest()
        self.write_run(
            "remainder", "remainder", self.items, executable_sha256=other_binary)
        result, report = self.gate()
        self.assertEqual(result.returncode, 2)
        self.assertIn("remainder.executableSHA256",
                      report["sameBinaryControlIdentityMismatches"])
        self.assertIn("provenance.executable.sha256",
                      report["sameBinaryControlIdentityMismatches"])

    def test_matching_fallback_evidence_passes(self) -> None:
        fallback = {"repository": "org/fallback", "digest": "3" * 64}
        for name, chunking in (("qualified", "remainder"),
                               ("remainder", "remainder"),
                               ("balanced", "balanced")):
            self.write_run(name, chunking, self.items, fallback=fallback)
        result, report = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["status"], "passed")

    def test_changed_fallback_weights_block(self) -> None:
        self.write_run(
            "qualified", "remainder", self.items,
            fallback={"repository": "org/fallback", "digest": "3" * 64})
        self.write_run(
            "remainder", "remainder", self.items,
            fallback={"repository": "org/fallback", "digest": "3" * 64})
        self.write_run(
            "balanced", "balanced", self.items,
            fallback={"repository": "org/fallback", "digest": "4" * 64})
        result, report = self.gate()
        self.assertEqual(result.returncode, 2)
        self.assertIn("provenance.fallbackModelDirectorySHA256",
                      report["sameBinaryControlIdentityMismatches"])
        self.assertIn("provenance.fallbackModelDirectorySHA256",
                      report["qualifiedIdentityMismatches"])

    def test_changed_fallback_repository_blocks(self) -> None:
        for name, chunking, repository in (("qualified", "remainder", "org/fallback"),
                                           ("remainder", "remainder", "org/fallback"),
                                           ("balanced", "balanced", "org/other")):
            self.write_run(
                name, chunking, self.items,
                fallback={"repository": repository, "digest": "3" * 64})
        result, report = self.gate()
        self.assertEqual(result.returncode, 2)
        self.assertIn("effectiveSettings.fallbackModelRepository",
                      report["sameBinaryControlIdentityMismatches"])

    def test_missing_fallback_provenance_blocks(self) -> None:
        # Fallback configured, but neither the content digest nor the
        # repository was recorded.
        for name, chunking in (("qualified", "remainder"),
                               ("remainder", "remainder"),
                               ("balanced", "balanced")):
            self.write_run(name, chunking, self.items, fallback={"key": "fallback-model"})
        result, report = self.gate()
        self.assertEqual(result.returncode, 2)
        self.assertIn("reference.provenance.fallbackModelDirectorySHA256.missing",
                      report["sameBinaryControlIdentityMismatches"])
        self.assertIn("reference.effectiveSettings.fallbackModelRepository.missing",
                      report["sameBinaryControlIdentityMismatches"])

    def test_runs_without_fallback_remain_compatible(self) -> None:
        # The default fixture records no fallback and no fallback evidence.
        data = json.loads(self.balanced.read_text())
        self.assertEqual(
            data["provenance"]["effectiveSettings"]["fallbackModelKey"], "none")
        self.assertNotIn("fallbackModelDirectorySHA256", data["provenance"])
        result, report = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report["status"], "passed")

    def test_identical_corpus_bytes_compare_equal_and_changed_bytes_block(self) -> None:
        corpus = self.root / "corpus.jsonl"
        corpus.write_bytes(b'{"messages":[{"role":"assistant","content":"SELECT 1"}]}\n')
        digest = hashlib.sha256(corpus.read_bytes()).hexdigest()
        for name, chunking in (("qualified", "remainder"),
                               ("remainder", "remainder"),
                               ("balanced", "balanced")):
            self.write_run(
                name, chunking, self.items,
                settings_overrides={"ngramDraftCorpusSHA256": digest})
        result, report = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        # The same bytes hashed again yield the same recorded identity.
        self.assertEqual(hashlib.sha256(corpus.read_bytes()).hexdigest(), digest)
        corpus.write_bytes(b'{"messages":[{"role":"assistant","content":"SELECT 2"}]}\n')
        self.write_run(
            "balanced", "balanced", self.items,
            settings_overrides={
                "ngramDraftCorpusSHA256": hashlib.sha256(corpus.read_bytes()).hexdigest()
            })
        result, report = self.gate()
        self.assertEqual(result.returncode, 2)
        self.assertIn("effectiveSettings.ngramDraftCorpusSHA256",
                      report["sameBinaryControlIdentityMismatches"])


if __name__ == "__main__":
    unittest.main()
