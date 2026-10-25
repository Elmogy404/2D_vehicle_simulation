from __future__ import annotations
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ai"))
from training_config import TRAINING_DEFAULTS, REWARD_DEFAULTS, prepare_manifest
from policy_checkpoint import checkpoint_generator, manifest_for_model
from training_control import DEFAULT_REWARD_CONFIG

class ConfigTests(unittest.TestCase):
    def test_shared_defaults_and_reserved_names(self):
        self.assertEqual(DEFAULT_REWARD_CONFIG, REWARD_DEFAULTS)
        self.assertEqual(TRAINING_DEFAULTS["eval_episodes"], 128)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run_training_config.json"
            prepare_manifest(path, {"workers": 8}, resume=False)
            original = path.read_bytes()
            with self.assertRaisesRegex(ValueError, "already exists"):
                prepare_manifest(path, {"workers": 1}, resume=False)
            self.assertEqual(path.read_bytes(), original)

    def test_generator_discovery_and_resume_protection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "run_training_config.json"
            manifest = dict(generator_type="segmented", workers=8, runtime={"source_hash": "abc"})
            prepare_manifest(path, manifest, resume=False)
            checkpoint = root / "checkpoints/run_8192_steps.zip"
            self.assertEqual(checkpoint_generator(checkpoint), "segmented")
            self.assertEqual(manifest_for_model(checkpoint)[0], path.resolve())
            with self.assertRaisesRegex(ValueError, "trained on"):
                checkpoint_generator(checkpoint, "original")
            prepare_manifest(path, manifest, resume=True)
            with self.assertRaisesRegex(ValueError, "workers"):
                prepare_manifest(path, dict(manifest, workers=4), resume=True)
            with self.assertRaisesRegex(ValueError, "source changed"):
                prepare_manifest(path, dict(manifest, runtime={"source_hash": "def"}), resume=True)

    def test_best_and_partial_checkpoints_reserve_a_run_name(self):
        for suffix in ("_best.zip", "checkpoints/run_1024_steps.zip"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                artifact = root / (suffix if suffix.startswith("checkpoints") else "run" + suffix)
                artifact.parent.mkdir(exist_ok=True)
                artifact.write_bytes(b"keep")
                with self.assertRaisesRegex(ValueError, "already exists"):
                    prepare_manifest(root / "run_training_config.json", {}, resume=False)

if __name__ == "__main__":
    unittest.main()
