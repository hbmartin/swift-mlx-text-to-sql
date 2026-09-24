"""The prefill gate rejects item losses even when aggregate accuracy ties."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "tools/compare_prefill_chunking.py"


class ComparePrefillChunkingTests(unittest.TestCase):
    def test_aggregate_tie_with_one_item_loss_is_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "creg-eval-cli"
            binary.write_bytes(b"one optimized binary")
            items = [
                {
                    "id": f"G-{index:03d}",
                    "predictedSQL": f"SELECT {index}",
                    "ex": index < 100,
                    "validSQL": True,
                }
                for index in range(200)
            ]

            def write_run(name: str, chunking: str, results: list[dict]) -> Path:
                path = root / f"{name}.json"
                path.write_text(json.dumps({
                    "command": [str(binary)],
                    "summary": {
                        "itemCount": 200,
                        "model": {"key": "pinned"},
                        "gcd": "off", "temperature": 0, "seed": 0,
                        "topP": 1, "topK": 0, "maxTokens": 128,
                        "rowCap": 10000, "prefillChunking": chunking,
                    },
                    "provenance": {
                        "modelDirectorySHA256": "model",
                        "systemPromptSHA256": "system",
                        "schemaPromptSHA256": "schema",
                        "grammarSHA256": "grammar",
                        "gold": {"sha256": "gold"},
                        "database": {"sha256": "database"},
                        "packageLock": {"sha256": "package"},
                    },
                    "results": results,
                }))
                return path

            qualified = write_run("qualified", "remainder", items)
            remainder = write_run("remainder", "remainder", items)
            balanced_items = [dict(item) for item in items]
            balanced_items[0]["ex"] = False
            balanced_items[100]["ex"] = True
            balanced = write_run("balanced", "balanced", balanced_items)
            report_path = root / "report.json"
            result = subprocess.run(
                [
                    sys.executable, str(SCRIPT),
                    "--qualified", str(qualified),
                    "--balanced", str(balanced),
                    "--remainder", str(remainder),
                    "--binary", str(binary),
                    "--out", str(report_path),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            report = json.loads(report_path.read_text())
            self.assertEqual(result.returncode, 2)
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(report["runs"]["balanced"]["outcomes"]["ex"], 100)
            self.assertEqual(report["runs"]["remainder"]["outcomes"]["ex"], 100)
            self.assertEqual(report["balancedLossesAgainstRemainder"]["ex"], ["G-000"])


if __name__ == "__main__":
    unittest.main()
