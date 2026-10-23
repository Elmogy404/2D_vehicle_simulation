"""Exercise the real console-free launcher, including full error capture."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


LAUNCHER = Path(__file__).resolve().parents[1] / "ai" / "gui_train_launcher.py"


class GuiLauncherTests(unittest.TestCase):
    def test_probe_distinguishes_external_live_and_exited_processes(self) -> None:
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            result = subprocess.run([sys.executable, str(LAUNCHER), "--probe-pid", str(child.pid)], timeout=10)
            self.assertEqual(result.returncode, 0)
        finally:
            child.terminate()
            child.wait(timeout=10)
        result = subprocess.run([sys.executable, str(LAUNCHER), "--probe-pid", str(child.pid)], timeout=10)
        self.assertEqual(result.returncode, 1)

    def launch(self, source: str, state: str = "starting") -> tuple[subprocess.CompletedProcess, str, dict]:
        with tempfile.TemporaryDirectory(prefix="training launcher with spaces ") as directory:
            project = Path(directory)
            ai = project / "ai"
            ai.mkdir()
            shutil.copyfile(LAUNCHER, ai / LAUNCHER.name)
            (ai / "train.py").write_text(source, encoding="utf-8")
            status = project / "status.json"
            status.write_text(json.dumps({"run_id": "test", "state": state, "message": "specific trainer error"}), encoding="utf-8")
            log = project / "run.log"
            result = subprocess.run(
                [sys.executable, str(ai / LAUNCHER.name), "--log-file", str(log),
                 "--status-file", str(status), "--run-id", "test"],
                capture_output=True, text=True, timeout=30,
            )
            return result, log.read_text(encoding="utf-8"), json.loads(status.read_text(encoding="utf-8"))

    def test_success_and_paths_with_spaces(self) -> None:
        result, log, _status = self.launch("print('trainer reached startup')\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("trainer reached startup", log)
        self.assertIn("Trainer SHA256:", log)
        self.assertIn("Python:", log)

    def test_missing_dependency_preserves_traceback_and_reports_setup(self) -> None:
        result, log, status = self.launch("import intentionally_missing_training_package\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Traceback (most recent call last)", log)
        self.assertIn("ModuleNotFoundError", log)
        self.assertNotIn("lost sys.stderr", result.stderr + log)
        self.assertEqual(status["state"], "failed")
        self.assertIn("setup_ai_training.cmd", status["message"])

    def test_existing_trainer_error_is_not_overwritten(self) -> None:
        result, log, status = self.launch("raise TypeError('reward_config is missing')\n", "failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TypeError: reward_config is missing", log)
        self.assertEqual(status["message"], "specific trainer error")


if __name__ == "__main__":
    unittest.main()
