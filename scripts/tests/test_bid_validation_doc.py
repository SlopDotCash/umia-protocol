"""Run the real docs guard against isolated copies of the contract sources."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class BidValidationDocTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="umia-doc-check-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "smart-contracts"
        self.repo.mkdir()
        shutil.copy2(ROOT / "check-bid-validation-doc.sh", self.repo)
        shutil.copytree(ROOT / "src", self.repo / "src")
        self.doc = Path(self.temp.name) / "web/site/content/docs/technical-reference/bid-validation.mdx"
        self.doc.parent.mkdir(parents=True)
        self.doc.write_text("<!-- bid-validation-source: " + "0" * 64 + " -->\nFlow charts\n")

    def run_guard(self, *args):
        return subprocess.run(
            ["bash", "check-bid-validation-doc.sh", *args],
            cwd=self.repo, text=True, capture_output=True,
        )

    def test_update_then_check_and_detect_source_change(self):
        self.assertEqual(self.run_guard("--update").returncode, 0)
        self.assertEqual(self.run_guard().returncode, 0)
        source = self.repo / "src/periphery/UmiaValidationHook.sol"
        source.write_text(source.read_text() + "\n// changed for docs guard test\n")
        self.assertNotEqual(self.run_guard().returncode, 0)
        self.assertEqual(self.run_guard("--update").returncode, 0)
        self.assertEqual(self.run_guard().returncode, 0)

    def test_update_rejects_missing_marker_without_changing_doc(self):
        self.doc.write_text("Flow charts without a source marker\n")
        before = self.doc.read_bytes()
        result = self.run_guard("--update")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.doc.read_bytes(), before)

    def test_update_rejects_duplicate_markers_without_changing_doc(self):
        marker = "<!-- bid-validation-source: " + "0" * 64 + " -->"
        for separator in ("\n", " "):
            with self.subTest(separator=repr(separator)):
                self.doc.write_text(marker + separator + marker + "\n")
                before = self.doc.read_bytes()
                result = self.run_guard("--update")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.doc.read_bytes(), before)

    def test_update_rejects_missing_source_without_changing_doc(self):
        (self.repo / "src/periphery/UmiaValidationHook.sol").unlink()
        before = self.doc.read_bytes()
        result = self.run_guard("--update")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.doc.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
