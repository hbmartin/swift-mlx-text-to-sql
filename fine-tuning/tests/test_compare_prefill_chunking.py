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

    def write_run(self, name: str, chunking: str, results: list[dict]) -> Path:
        path = self.root / f"{name}.json"
        settings = {key: "off" for key in GATE.REQUIRED_EFFECTIVE_SETTINGS}
        settings["prefillChunking"] = chunking
        path.write_text(json.dumps({
            "schemaVersion": 3,
            "command": [str(self.binary)],
            "summary": {
                "itemCount": 200, "model": {"key": "pinned"},
                "gcd": "off", "temperature": 0, "seed": 0,
                "topP": 1, "topK": 0, "maxTokens": 128,
                "rowCap": 10000, "prefillChunking": chunking,
            },
            "provenance": {
                "modelDirectorySHA256": "a" * 64,
                "systemPromptSHA256": "b" * 64,
                "schemaPromptSHA256": "c" * 64,
                "grammarSHA256": "d" * 64,
                "gold": {"sha256": "e" * 64},
                "database": {"sha256": "f" * 64},
                "packageLock": {"sha256": "1" * 64},
                "executable": {"sha256": self.binary_hash},
                "effectiveSettings": settings,
            },
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


if __name__ == "__main__":
    unittest.main()
