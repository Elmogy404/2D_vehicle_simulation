"""Enhanced Training GUI — main entry point.

A standalone tkinter GUI that replicates all functionality from the Godot
training dashboard and adds two new tabs:
  • Visual Training — headed (visible) training
  • Present — showcase trained models in a nice presentation view
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure the ai/ directory is importable so we can reuse training_control, etc.
PROJECT_ROOT = Path(__file__).resolve().parents[1]
AI_DIR = PROJECT_ROOT / "ai"
sys.path.insert(0, str(AI_DIR))

def main() -> None:
    try:
        from gui_app import EnhancedTrainingApp
        app = EnhancedTrainingApp(PROJECT_ROOT)
    except ImportError as error:
        print(f"GUI dependencies are missing: {error}\nRun setup_ai_training.cmd first and launch start_training_gui.cmd.")
        raise SystemExit(1) from error
    except Exception as error:
        if type(error).__name__ == "TclError":
            print(f"Tkinter could not start: {error}\nRepair Python with Tcl/Tk support, then rerun setup_ai_training.cmd.")
            raise SystemExit(1) from error
        raise
    app.mainloop()


if __name__ == "__main__":
    main()
