# AI Training Studio

A standalone Python interface for the existing PPO trainer and Godot worlds.
It trains the same model as the in-game dashboard and shares its status/control
protocol. It does not require opening the Godot editor.

## Start

On Windows, run `setup_ai_training.cmd` once, then double-click
**`start_training_gui.cmd`** in the project root. In **Run setup**, choose the
installed Godot executable and your training settings. Python defaults to the
project's `.venv-ai` environment. Paths/settings are remembered locally.
Godot is detected from `GODOT_BIN`, PATH, or this project's recorded editor
location. If it cannot be found, **Present model** offers an executable picker
and remembers your selection; you can also change it in **Run setup**.

Alternatively, run `.venv-ai/Scripts/python.exe enhanced_training_gui/main_gui.py`
from the project root. The complete source project and a Godot 4 engine binary
are required. Python must include Tkinter/Tcl/Tk; the standard Windows Python
installer offers these components. No additional GUI pip packages are required.

## Four tabs

- **Training overview:** progress, speed, elapsed/ETA, recent success/crash/
  stall/timeout, reward/progress, success chart, worker curriculum, evaluation
  counts/confidence intervals, optimizer diagnostics, checkpoint and log links.
- **Visual training:** a grid of actual live Godot training windows. Eight
  workers give eight views, arranged four across and two down. All workers
  collect experience for one shared PPO model. Each tile shows its worker,
  stage, speed and route progress. Resizing the app resizes the native views.
- **Run setup:** shared configuration for both modes, including rewards,
  evaluation settings, output folder and resume. Training workers default to 1
  with no configured upper cap; values above 32 display a non-blocking warning.
- **Present models:** browse final/best/recovery/checkpoint ZIPs, inspect actual
  saved training steps, select a stage/seed, and launch a trained policy in a
  separate Godot window. Stop presentation closes its owned Godot process.

Embedded live views currently require **Windows**. Headless training does not
use embedded windows. Visual training runs in real time and renders every
worker, so it uses more GPU resources and is slower than headless training.
PPO's optimization still uses the CPU.

The live views show training workers only; evaluation worlds remain headless.
Workers stay still while paused, during policy updates, and while checkpoint
evaluation is running. Their phase is shown in the GUI.

## Controls and recovery

Only one training session can be launched at a time from the standalone GUI.
Both training tabs control that same run. Starting a second run is rejected,
and existing run names are protected from accidental overwrites. Inputs are
validated before training starts. File status/control updates use the existing
atomic writer with Windows sharing-violation retries.

**Browse resume checkpoint** loads its original run name, worker count,
PPO/reward settings and evaluation configuration from the adjacent training
manifest. Keep these settings when resuming. Version 1/2 environments cannot
resume into version 3. Headless and visual modes can resume version 3 models
with the same worker count. A resume starts new episodes, not mid-trip.

Closing during visual training offers to end and save before destroying the
worker views. During headless training, you can end/save or leave training
running after the GUI closes. Reopening reconnects to its status file. Model
presentation is separate from training and has its own stop control and log.

## Validation

Python tests cover configuration validation, uncapped worker counts, duplicate
run prevention, native-parent arguments, launch errors, resume settings,
checkpoint metadata and first-evaluation progress.

`tests/enhanced_gui_integration.py --godot PATH --workers 8` is an optional
Windows desktop test. It starts eight real PPO/Godot workers in an isolated
output directory, verifies eight distinct child processes, checks pause/resume,
clean stop/model save/worker-window cleanup, and launches/stops model
presentation. It also resumes the visual checkpoint in headless mode. It
captures only its own application window for visual review.
It does not modify the user's training status or model files.
