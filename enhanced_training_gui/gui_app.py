"""Core tkinter application with four tabs."""

from __future__ import annotations

import os
import sys
import subprocess
import time
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from pathlib import Path
from typing import Any

from training_session import (TrainingSession, DEFAULTS, DEFAULT_REWARD_CONFIG, default_python, default_godot,
    validate_settings, resume_settings, read_json, model_metadata, find_godot, write_json_atomic)
from worker_views import WorkerViewGrid

# ---------------------------------------------------------------------------
# Colour palette (matching the Godot dashboard)
# ---------------------------------------------------------------------------
BG = "#0e1e2a"
BG_CARD = "#112536"
BG_INPUT = "#172b3c"
FG = "#e6eef7"
MUTED = "#91a7bb"
TEAL = "#55d8c5"
BLUE = "#7caaff"
RED = "#ff9a9a"
YELLOW = "#efc475"
GREEN = "#5aeb82"


class EnhancedTrainingApp(tk.Tk):
    """One session/configuration, two training views, and a separate model watcher."""
    def __init__(self, project_root: Path, session=None):
        if os.name == 'nt':
            import ctypes
            ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
        super().__init__()
        self.project_root = project_root
        self.session = session or TrainingSession(project_root)
        self.preferences_path = self.session.status_path.parent / 'enhanced_gui_config.json'
        self.closing = False
        self.title("AI Training Studio - 2D Vehicle Simulation")
        self.geometry("1280x900")
        self.minsize(900, 650)
        self.configure(bg=BG)
        self._apply_theme()
        self.worker_warning = ttk.Label(self, foreground=YELLOW, wraplength=1100)
        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)
        self.headless_tab = HeadlessTrainingTab(self.notebook, project_root)
        self.visual_tab = VisualTrainingTab(self.notebook, project_root)
        self.setup_tab = RunSetupTab(self.notebook, project_root)
        self.present_tab = PresentTab(self.notebook, project_root)
        for tab, title in ((self.headless_tab, "Training overview"), (self.visual_tab, "Visual training"),
                           (self.setup_tab, "Run setup"), (self.present_tab, "Present models")):
            self.notebook.add(tab, text="  " + title + "  ")
        self.setup_tab.apply_config(read_json(self.preferences_path))
        if not self.setup_tab.params['godot_path'].get().strip():
            self.setup_tab.params['godot_path'].set(default_godot(project_root))
        self.setup_tab.params['workers'].trace_add('write', lambda *_: self.update_worker_warning())
        self.update_worker_warning()
        self.protocol('WM_DELETE_WINDOW', self._close)
        self._poll_status()

    def _apply_theme(self) -> None:
        style = ttk.Style(self)
        style.theme_use("clam")

        style.configure(".", background=BG, foreground=FG, fieldbackground=BG_INPUT,
                         borderwidth=0, font=("Segoe UI", 10))
        style.configure("TNotebook", background=BG, borderwidth=0)
        style.configure("TNotebook.Tab", background=BG_CARD, foreground=FG,
                         padding=(16, 8), font=("Segoe UI", 11, "bold"))
        style.map("TNotebook.Tab",
                  background=[("selected", BG_INPUT)],
                  foreground=[("selected", TEAL)])
        style.configure("TFrame", background=BG)
        style.configure("TLabel", background=BG, foreground=FG)
        style.configure("TButton", background=BG_CARD, foreground=FG,
                         padding=(12, 6), font=("Segoe UI", 10, "bold"))
        style.map("TButton",
                  background=[("disabled", "#142332"), ("active", BG_INPUT)],
                  foreground=[("disabled", "#526579"), ("active", TEAL)])
        style.configure("Accent.TButton", background=TEAL, foreground=BG,
                         font=("Segoe UI", 11, "bold"))
        style.map("Accent.TButton",
                  background=[("disabled", "#142332"), ("active", "#44c8b5")],
                  foreground=[("disabled", "#526579"), ("active", BG)])
        style.configure("Danger.TButton", background=RED, foreground=BG,
                         font=("Segoe UI", 11, "bold"))
        style.map("Danger.TButton",
                  background=[("active", "#ee8888")],
                  foreground=[("active", BG)])
        style.configure("TLabelframe", background=BG, foreground=TEAL,
                         font=("Segoe UI", 10, "bold"))
        style.configure("TLabelframe.Label", background=BG, foreground=TEAL)
        style.configure("TEntry", fieldbackground=BG_INPUT, foreground=FG,
                         insertcolor=FG)
        style.configure("TSpinbox", fieldbackground=BG_INPUT, foreground=FG,
                         arrowcolor=FG)
        style.configure("Treeview", background=BG_INPUT, foreground=FG,
                         fieldbackground=BG_INPUT, font=("Segoe UI", 10))
        style.configure("Treeview.Heading", background=BG_CARD, foreground=TEAL,
                         font=("Segoe UI", 10, "bold"))
        style.map("Treeview", background=[("selected", "#1a3a50")])
        style.configure("Horizontal.TProgressbar", background=TEAL,
                         troughcolor=BG_INPUT, borderwidth=0, thickness=10)
        style.configure("Card.TFrame", background=BG_CARD)
        style.configure("Card.TLabel", background=BG_CARD, foreground=FG)
        style.configure("CardTitle.TLabel", background=BG_CARD, foreground=MUTED,
                         font=("Segoe UI", 9))
        style.configure("CardValue.TLabel", background=BG_CARD, foreground=BLUE,
                         font=("Segoe UI", 16, "bold"))
        style.configure("CardValueTeal.TLabel", background=BG_CARD, foreground=TEAL,
                         font=("Segoe UI", 16, "bold"))
        style.configure("Heading.TLabel", foreground=TEAL,
                         font=("Segoe UI", 13, "bold"))
        style.configure("State.TLabel", foreground=TEAL,
                         font=("Segoe UI", 12, "bold"))
        style.configure("Muted.TLabel", foreground=MUTED,
                         font=("Segoe UI", 10))
        style.configure("Section.TLabel", foreground=TEAL,
                         font=("Segoe UI", 11, "bold"))


    def update_worker_warning(self):
        try:
            count = int(self.setup_tab.params['workers'].get())
        except ValueError:
            count = 0
        if count > 32:
            self.worker_warning.configure(text=f"Warning: {count} workers selected. Above 32 workers, CPU/RAM usage can be very high; training may slow down or run out of memory. You can still start.")
            self.worker_warning.pack(fill=tk.X, padx=12, pady=4, before=self.notebook)
        else:
            self.worker_warning.pack_forget()

    def start_training(self, visual=False):
        try:
            if self.session.is_active():
                raise ValueError('Training is already running. End and save it first.')
            config = validate_settings(self.project_root, self.setup_tab.get_config())
            parents = None
            if visual:
                self.notebook.select(self.visual_tab)
                self.update_idletasks()
                parents = self.visual_tab.views.build(config['workers'])
            config = self.session.start(config, parents)
            self.setup_tab.apply_config(config)
            try:
                write_json_atomic(self.preferences_path, config)
            except OSError:
                pass
            if not visual:
                self.notebook.select(self.headless_tab)
            self._refresh_status()
        except (OSError, ValueError) as error:
            messagebox.showerror('Cannot start training', str(error), parent=self)

    def send_command(self, command):
        try:
            self.session.command(command)
        except (OSError, ValueError) as error:
            messagebox.showerror('Training control', str(error), parent=self)

    def remember_executables(self):
        preferences = read_json(self.preferences_path)
        for key in ('python_path', 'godot_path'):
            preferences[key] = self.setup_tab.params[key].get().strip()
        try:
            write_json_atomic(self.preferences_path, preferences)
        except OSError:
            pass

    def _refresh_status(self):
        status = self.session.poll()
        active = self.session.is_active(status)
        if status:
            self.headless_tab.update_status(status)
            self.visual_tab.update_status(status)
        state = status.get('state', 'idle')
        for tab in (self.headless_tab, self.visual_tab):
            for button, enabled in ((tab.btn_pause, active and state == 'running'),
                                    (tab.btn_resume, active and state == 'paused'),
                                    (tab.btn_stop, active and state not in {'saving', 'stopping'})):
                button.configure(state=tk.NORMAL if enabled else tk.DISABLED)
        self.visual_tab.btn_start.configure(state=tk.DISABLED if active else tk.NORMAL)
        self.setup_tab.set_active(active)
        self.present_tab.poll()
        return active

    def _poll_status(self):
        active = self._refresh_status()
        if self.closing and not active:
            self.present_tab.stop()
            self.destroy()
            return
        self.after(500, self._poll_status)

    def _close(self):
        if self.session.is_active():
            visual = self.session.read_status().get('visual_training', False)
            if visual:
                if not messagebox.askokcancel('End and save training',
                    'The live worker views belong to this window. End and save training before closing?', parent=self):
                    return
            else:
                answer = messagebox.askyesnocancel('Training is running',
                    'End and save before closing?\nYes: save and stop.\nNo: leave headless training running.\nCancel: stay here.', parent=self)
                if answer is None:
                    return
                if not answer:
                    self.present_tab.stop()
                    self.destroy()
                    return
            self.send_command('stop')
            self.closing = True
            return
        self.present_tab.stop()
        self.destroy()



# ═══════════════════════════════════════════════════════════════════════════
#  Shared helpers
# ═══════════════════════════════════════════════════════════════════════════


def open_path(path):
    path = str(path)
    if os.name == "nt":
        os.startfile(path)
    else:
        subprocess.Popen(["open" if sys.platform == "darwin" else "xdg-open", path])





def _compact(value: int) -> str:
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    if value >= 1_000:
        return f"{value / 1_000:.1f}k"
    return str(value)


def _duration(seconds: float | None) -> str:
    if seconds is None:
        return "—"
    s = max(0, int(seconds))
    if s >= 3600:
        return f"{s // 3600}h {s % 3600 // 60:02d}m"
    return f"{s // 60}m {s % 60:02d}s"


def _percent(value: Any) -> str:
    if value is None:
        return "—"
    return f"{float(value) * 100:.1f}%"


def _make_card(parent: tk.Widget, title: str, accent: str = BLUE) -> ttk.Label:
    """Create a metric card returning the value label."""
    frame = ttk.Frame(parent, style="Card.TFrame", padding=10)
    frame.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=4, pady=4)
    ttk.Label(frame, text=title, style="CardTitle.TLabel").pack(anchor=tk.W)
    style_name = "CardValueTeal.TLabel" if accent == TEAL else "CardValue.TLabel"
    val = ttk.Label(frame, text="—", style=style_name)
    val.configure(foreground=accent)
    val.pack(anchor=tk.W, pady=(4, 0))
    return val


def _scrollable_frame(parent: tk.Widget) -> ttk.Frame:
    """Create a scrollable frame inside parent."""
    canvas = tk.Canvas(parent, bg=BG, highlightthickness=0)
    scrollbar = ttk.Scrollbar(parent, orient=tk.VERTICAL, command=canvas.yview)
    frame = ttk.Frame(canvas)
    frame.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
    window_id = canvas.create_window((0, 0), window=frame, anchor=tk.NW)
    canvas.bind("<Configure>", lambda e: canvas.itemconfigure(window_id, width=e.width))
    canvas.configure(yscrollcommand=scrollbar.set)

    def _on_mousewheel(event):
        if isinstance(event.widget, (ttk.Treeview, tk.Text)):
            return
        widget = event.widget
        while widget is not None and widget is not frame:
            widget = getattr(widget, "master", None)
        if widget is frame:
            canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

    canvas.bind_all("<MouseWheel>", _on_mousewheel, add="+")
    scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
    canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
    return frame


# ═══════════════════════════════════════════════════════════════════════════
#  Tab 1: Headless Training
# ═══════════════════════════════════════════════════════════════════════════

class HeadlessTrainingTab(ttk.Frame):
    """Mirrors the original Godot training dashboard for headless training."""

    def __init__(self, parent: tk.Widget, project_root: Path) -> None:
        super().__init__(parent)
        self.project_root = project_root
        self.run_id = ""
        self.process_id = -1
        self.latest_status: dict = {}
        self._build_ui()

    def _build_ui(self) -> None:
        # Header
        header = ttk.Frame(self)
        header.pack(fill=tk.X, padx=12, pady=(12, 4))
        ttk.Label(header, text="TRAINING CONTROL", style="Heading.TLabel").pack(side=tk.LEFT)
        self.state_label = ttk.Label(header, text="IDLE", style="State.TLabel")
        self.state_label.pack(side=tk.RIGHT)

        self.run_label = ttk.Label(self, text="Configure a new experiment in Run Setup",
                                    style="Muted.TLabel")
        self.run_label.pack(fill=tk.X, padx=12)

        # Progress bar
        self.progress = ttk.Progressbar(self, mode="determinate",
                                         style="Horizontal.TProgressbar")
        self.progress.pack(fill=tk.X, padx=12, pady=6)

        # Top metrics row
        metrics_row = ttk.Frame(self)
        metrics_row.pack(fill=tk.X, padx=8, pady=4)
        self.m_steps = _make_card(metrics_row, "TRAINING STEPS")
        self.m_fps = _make_card(metrics_row, "STEPS / SECOND")
        self.m_elapsed = _make_card(metrics_row, "ELAPSED")
        self.m_eta = _make_card(metrics_row, "TRAINING ETA")

        # Buttons
        btn_frame = ttk.Frame(self)
        btn_frame.pack(fill=tk.X, padx=12, pady=4)
        self.btn_pause = ttk.Button(btn_frame, text="⏸ Pause", command=self._pause)
        self.btn_pause.pack(side=tk.LEFT, padx=4)
        self.btn_resume = ttk.Button(btn_frame, text="▶ Resume", command=self._resume)
        self.btn_resume.pack(side=tk.LEFT, padx=4)
        self.btn_stop = ttk.Button(btn_frame, text="⏹ Stop", style="Danger.TButton",
                                    command=self._stop)
        self.btn_stop.pack(side=tk.LEFT, padx=4)

        self.status_label = ttk.Label(self, text="Ready for a new training run",
                                       style="Muted.TLabel", wraplength=800)
        self.status_label.pack(fill=tk.X, padx=12, pady=4)

        # Scrollable content area
        content_frame = ttk.Frame(self)
        content_frame.pack(fill=tk.BOTH, expand=True, padx=8, pady=4)
        self.content = _scrollable_frame(content_frame)

        # ---- Live training section ----
        ttk.Label(self.content, text="LIVE TRAINING", style="Section.TLabel").pack(
            anchor=tk.W, padx=8, pady=(8, 2))
        ttk.Label(self.content, text="Recent completed episodes across all workers.",
                  style="Muted.TLabel").pack(anchor=tk.W, padx=8)

        train_row = ttk.Frame(self.content)
        train_row.pack(fill=tk.X, padx=4, pady=4)
        self.m_success = _make_card(train_row, "SUCCESS", TEAL)
        self.m_crash = _make_card(train_row, "CRASH", RED)
        self.m_stall = _make_card(train_row, "STALL / TIMEOUT", YELLOW)
        self.m_return = _make_card(train_row, "MEAN RETURN")
        self.m_progress = _make_card(train_row, "TRIP PROGRESS")
        self.m_episodes = _make_card(train_row, "EPISODES IN WINDOW")

        # Training chart (simple text-based for now, replaced with canvas)
        self.chart_canvas = tk.Canvas(self.content, bg=BG_CARD, height=130,
                                       highlightthickness=0)
        self.chart_canvas.pack(fill=tk.X, padx=8, pady=4)
        self._chart_data: list[dict] = []
        self.chart_canvas.bind("<Configure>", lambda _event: self._draw_chart())

        # ---- Worker curriculum section ----
        ttk.Label(self.content, text="WORKER CURRICULUM", style="Section.TLabel").pack(
            anchor=tk.W, padx=8, pady=(12, 2))
        ttk.Label(self.content, text="First-turn practice progresses through 45, 75, then 150 km/h.",
                  style="Muted.TLabel").pack(anchor=tk.W, padx=8)

        cols = ("Worker", "Frontier / Trip", "Turn Practice", "Speed / Progress", "Recent Success")
        worker_frame = ttk.Frame(self.content)
        worker_frame.pack(fill=tk.X, padx=8, pady=4)
        self.worker_tree = ttk.Treeview(worker_frame, columns=cols, show="headings", height=5)
        for col in cols:
            self.worker_tree.heading(col, text=col)
            self.worker_tree.column(col, width=140, anchor=tk.CENTER)
        worker_scroll = ttk.Scrollbar(worker_frame, orient=tk.VERTICAL, command=self.worker_tree.yview)
        self.worker_tree.configure(yscrollcommand=worker_scroll.set)
        worker_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.worker_tree.pack(fill=tk.X, expand=True)

        self.runtime_label = ttk.Label(self.content,
            text="Reset timings appear when workers begin collecting experience.",
            style="Muted.TLabel", wraplength=800)
        self.runtime_label.pack(anchor=tk.W, padx=8, pady=2)

        # ---- Checkpoint evaluation section ----
        ttk.Label(self.content, text="CHECKPOINT EVALUATION", style="Section.TLabel").pack(
            anchor=tk.W, padx=8, pady=(12, 2))
        self.context_label = ttk.Label(self.content, text="Waiting for the first evaluation",
                                        style="Muted.TLabel", wraplength=800)
        self.context_label.pack(anchor=tk.W, padx=8)

        eval_cols = ("Stage", "Success", "Episodes", "Progress", "Crash / Stall", "95% Interval")
        self.eval_tree = ttk.Treeview(self.content, columns=eval_cols, show="headings", height=8)
        for col in eval_cols:
            self.eval_tree.heading(col, text=col)
            self.eval_tree.column(col, width=120, anchor=tk.CENTER)
        self.eval_tree.pack(fill=tk.X, padx=8, pady=4)

        # ---- Diagnostics section ----
        ttk.Label(self.content, text="LEARNING DIAGNOSTICS", style="Section.TLabel").pack(
            anchor=tk.W, padx=8, pady=(12, 2))
        self.diagnostic_label = ttk.Label(self.content,
            text="Optimizer statistics appear after the first update.",
            style="Muted.TLabel", wraplength=800)
        self.diagnostic_label.pack(anchor=tk.W, padx=8)

        self.model_label = ttk.Label(self.content, text="No checkpoint saved yet",
                                      style="Muted.TLabel", wraplength=800)
        self.model_label.pack(anchor=tk.W, padx=8, pady=(4, 2))

        # Link buttons
        link_row = ttk.Frame(self.content)
        link_row.pack(anchor=tk.W, padx=8, pady=4)
        ttk.Button(link_row, text="Open training log", command=self._open_log).pack(side=tk.LEFT, padx=4)
        ttk.Button(link_row, text="Open checkpoint folder", command=self._open_checkpoints).pack(side=tk.LEFT, padx=4)

    def update_status(self, status: dict) -> None:
        self.latest_status = status
        state = str(status.get("state", "idle"))
        phase = str(status.get("phase", state))
        self.state_label.configure(text=(phase if state == "running" else state).upper())
        self.state_label.configure(foreground=RED if state == "failed" else TEAL)

        run_name = status.get("run_name", "New experiment")
        workers = int(status.get("workers", 0))
        self.run_label.configure(text=f"{run_name}  /  {workers} workers")

        steps = int(status.get("timesteps", 0))
        total = max(1, int(status.get("total_steps", 1)))
        self.progress["maximum"] = total
        self.progress["value"] = min(steps, total)
        self.m_steps.configure(text=f"{_compact(steps)} / {_compact(total)}")

        perf = status.get("performance", {})
        fps = perf.get("steps_per_second")
        self.m_fps.configure(text=f"{fps:.0f}" if fps is not None else "—")
        self.m_elapsed.configure(text=_duration(perf.get("elapsed_seconds")))
        self.m_eta.configure(
            text=_duration(perf.get("eta_seconds")) if state == "running" else "—")

        t = status.get("training_metrics", {})
        self.m_success.configure(text=_percent(t.get("success_rate")))
        self.m_crash.configure(text=_percent(t.get("crash_rate")))
        stall_val = float(t.get("stall_rate", 0)) + float(t.get("timeout_rate", 0))
        self.m_stall.configure(text=_percent(stall_val) if t.get("episodes", 0) > 0 else "—")
        self.m_return.configure(
            text=f"{float(t['mean_return']):.2f}" if "mean_return" in t else "—")
        self.m_progress.configure(text=_percent(t.get("mean_progress")))
        self.m_episodes.configure(text=str(t.get("episodes", 0)))

        # Chart
        history = status.get("history", [])
        self._chart_data = history
        self._draw_chart()

        # Workers
        self.worker_tree.delete(*self.worker_tree.get_children())
        worker_metrics = status.get("worker_metrics", [])
        reset_ms = 0.0
        w_count = 0
        reused = 0
        speed_caps = ["45 km/h", "75 km/h", "Full speed"]
        for w in worker_metrics:
            if not w:
                continue
            w_count += 1
            reset_ms += float(w.get("reset_ms", 0))
            reused += int(w.get("map_reused", False))
            stage = int(w.get("stage", 0))
            turn_text = speed_caps[min(int(w.get("turn_level", 0)), 2)] if stage == 3 \
                else ("Upcoming" if stage < 3 else "Complete")
            self.worker_tree.insert("", tk.END, values=(
                f"Worker {int(w.get('worker', 0))}",
                f"{stage} / {int(w.get('episode_stage', 0))}",
                turn_text,
                f"{float(w.get('speed_kmh', 0)):.0f} km/h / {_percent(w.get('progress'))}",
                f"{_percent(w.get('recent_success_rate'))} ({int(w.get('recent_episodes', 0))}/20)",
            ))
        if w_count > 0:
            self.runtime_label.configure(
                text=f"Latest resets: {reset_ms / w_count:.1f} ms average | "
                     f"Cached maps: {reused} / {w_count} workers | "
                     f"Evaluation time: {_duration(perf.get('evaluation_seconds'))}")

        # Evaluation
        evaluation = status.get("final_evaluation") or status.get("last_evaluation", {})
        if not evaluation and status.get("phase") != "evaluating":
            self.context_label.configure(
                text=f"Next evaluation: {status.get('next_eval_step', 'not scheduled')} steps")
        elif status.get("phase") == "evaluating":
            ep = status.get("evaluation_progress", {})
            self.context_label.configure(
                text=f"Evaluating {int(ep.get('completed', 0))} / {int(ep.get('total', 0))} episodes "
                     f"across {int(ep.get('workers', 0))} worlds")
        else:
            self.context_label.configure(
                text=f"At {int(evaluation.get('timesteps', 0))} steps  •  "
                     f"{_percent(evaluation.get('success_rate'))} success  •  "
                     f"{_percent(evaluation.get('crash_rate'))} crash  •  "
                     f"{int(evaluation.get('episodes', 0))} episodes  •  "
                     f"{float(evaluation.get('duration_seconds', 0)):.1f}s\n"
                     f"Longest routes: {_percent(evaluation.get('longest_stage_success_rate'))}  •  "
                     f"Early-stop streak {int(evaluation.get('early_stop_streak', 0))} / "
                     f"{int(evaluation.get('early_stop_patience', 0))}")

        if evaluation.get('suite') == 'independent_holdout' and status.get('phase') != 'evaluating':
            self.context_label.configure(text=f"Independent final holdout: {_percent(evaluation.get('success_rate'))} success across "
                f"{evaluation.get('episodes', 0)} episodes. All-stage gate: {'PASS' if evaluation.get('gate_met') else 'NOT MET'}")
        self.eval_tree.delete(*self.eval_tree.get_children())
        for stage in evaluation.get("stages", []):
            interval = stage.get("success_interval", [0.0, 1.0])
            self.eval_tree.insert("", tk.END, values=(
                f"Stage {int(stage.get('stage', 0))}",
                _percent(stage.get("success_rate")),
                f"{int(stage.get('successes', 0))} / {int(stage.get('episodes', 0))}",
                _percent(stage.get("mean_progress")),
                f"{_percent(stage.get('crash_rate'))} / {_percent(stage.get('stall_rate'))}",
                f"{_percent(interval[0])}–{_percent(interval[1])}",
            ))

        # Diagnostics
        optimizer = status.get("optimizer", {})
        pieces = []
        for key in ["explained_variance", "approx_kl", "entropy_loss", "value_loss", "clip_fraction"]:
            if key in optimizer:
                pieces.append(f"{key.replace('_', ' ')}: {float(optimizer[key]):.4f}")
        self.diagnostic_label.configure(
            text="  |  ".join(pieces) if pieces else "Optimizer statistics appear after the first update.")

        model_text = f"Latest checkpoint: {status.get('last_model_path', status.get('last_checkpoint', 'not saved yet'))}"
        if "best_model_path" in status:
            model_text += f"\nBest checkpoint: {status['best_model_path']}"
        self.model_label.configure(text=model_text)

        self.status_label.configure(text=str(status.get("message", "")))

    def _draw_chart(self) -> None:
        c = self.chart_canvas
        c.delete("all")
        w = c.winfo_width() or 400
        h = c.winfo_height() or 130
        pad_l, pad_r, pad_t, pad_b = 45, 10, 12, 24
        pw = max(1, w - pad_l - pad_r)
        ph = max(1, h - pad_t - pad_b)

        # Grid lines
        for i in range(3):
            y = pad_t + ph * i / 2.0
            c.create_line(pad_l, y, w - pad_r, y, fill="#3a5a6f", dash=(2, 4))
            c.create_text(2, y + 4, text=f"{100 - i * 50}%", fill=MUTED, anchor=tk.W,
                          font=("Segoe UI", 9))

        valid = [s for s in self._chart_data if s.get("success") is not None]
        if len(valid) < 2:
            c.create_text(w // 2, h // 2, text="Episode results will appear here",
                          fill=MUTED, font=("Segoe UI", 11))
            return

        first_step = float(valid[0]["steps"])
        span = max(1.0, float(valid[-1]["steps"]) - first_step)
        points = []
        for s in valid:
            x = pad_l + pw * (float(s["steps"]) - first_step) / span
            y = pad_t + ph * (1.0 - float(s["success"]))
            points.append((x, y))

        if len(points) >= 2:
            flat = [coord for pt in points for coord in pt]
            c.create_line(*flat, fill=TEAL, width=2, smooth=True)
            lx, ly = points[-1]
            c.create_oval(lx - 3, ly - 3, lx + 3, ly + 3, fill=TEAL, outline=TEAL)

        c.create_text(pad_l, h - 3, text=f"{int(first_step)} steps", fill=MUTED,
                      anchor=tk.W, font=("Segoe UI", 9))
        c.create_text(w - pad_r, h - 3, text=f"{int(valid[-1]['steps'])} steps",
                      fill=MUTED, anchor=tk.E, font=("Segoe UI", 9))

    def _pause(self) -> None:
        self.winfo_toplevel().send_command("pause")

    def _resume(self) -> None:
        self.winfo_toplevel().send_command("run")

    def _stop(self) -> None:
        self.winfo_toplevel().send_command("stop")

    def _open_log(self) -> None:
        path = str(self.latest_status.get("log_path", ""))
        if path and os.path.exists(path):
            open_path(path)

    def _open_checkpoints(self) -> None:
        path = str(self.latest_status.get("last_model_path",
                   self.latest_status.get("last_checkpoint", "")))
        if path:
            folder = str(Path(path).parent)
        else:
            folder = str(self.project_root / "ai" / "models")
        if os.path.isdir(folder):
            open_path(folder)


# ═══════════════════════════════════════════════════════════════════════════
#  Tab 2: Visual Training (NEW)
# ═══════════════════════════════════════════════════════════════════════════

class VisualTrainingTab(ttk.Frame):
    """All actual training workers, embedded in one resizable native grid."""
    def __init__(self, parent, project_root):
        super().__init__(parent)
        self.project_root = project_root
        ttk.Label(self, text='LIVE WORKER VIEWS', style='Heading.TLabel').pack(anchor=tk.W, padx=12, pady=(12,4))
        ttk.Label(self, text='Uses Run setup. Every tile is a real Godot training worker sharing the same PPO policy. '
            'Visible simulation runs at normal speed and uses more GPU resources than headless training.',
            wraplength=1100, style='Muted.TLabel').pack(fill=tk.X, padx=12)
        buttons = ttk.Frame(self)
        buttons.pack(fill=tk.X, padx=12, pady=8)
        self.btn_start = ttk.Button(buttons, text='Start visual training', style='Accent.TButton',
            command=lambda: self.winfo_toplevel().start_training(visual=True))
        self.btn_start.pack(side=tk.LEFT, padx=4)
        for attr, label, command in (('btn_pause','Pause','pause'), ('btn_resume','Resume','run'), ('btn_stop','End and save','stop')):
            button = ttk.Button(buttons, text=label, command=lambda cmd=command:self.winfo_toplevel().send_command(cmd))
            button.pack(side=tk.LEFT,padx=4)
            setattr(self,attr,button)
        ttk.Button(buttons,text='Run setup',command=lambda:self.winfo_toplevel().notebook.select(self.winfo_toplevel().setup_tab)).pack(side=tk.RIGHT)
        self.state_label = ttk.Label(self,text='Choose the worker count in Run setup, then start visual training.',style='Muted.TLabel',wraplength=1100)
        self.state_label.pack(fill=tk.X,padx=12,pady=4)
        self.views = WorkerViewGrid(self)
        self.views.pack(fill=tk.BOTH,expand=True,padx=8,pady=4)

    def update_status(self,status):
        if status.get('visual_training'):
            self.state_label.configure(text=f"{status.get('run_name','')} | {status.get('phase',status.get('state','idle')).upper()} | "
                f"{status.get('timesteps',0):,} / {status.get('total_steps',0):,} steps | {status.get('message','')}")
            self.views.update_workers(status)
        else:
            self.state_label.configure(text='The current run is headless. See Training overview, or end it and start visual training to see all workers here.')



# ═══════════════════════════════════════════════════════════════════════════
#  Tab 3: Run Setup
# ═══════════════════════════════════════════════════════════════════════════

class RunSetupTab(ttk.Frame):
    def __init__(self,parent,project_root):
        super().__init__(parent)
        self.project_root=project_root
        self.inputs=[]
        self.browse_buttons=[]
        container=ttk.Frame(self)
        container.pack(fill=tk.BOTH,expand=True)
        content=_scrollable_frame(container)
        ttk.Label(content,text='RUN SETUP',style='Heading.TLabel').pack(anchor=tk.W,padx=12,pady=12)
        ttk.Label(content,text='Shared settings for headless and visual training. Resume must keep the saved worker count and PPO/reward settings.',
            wraplength=1000,style='Muted.TLabel').pack(anchor=tk.W,padx=12,pady=4)
        self.params={}
        fields=[('python_path','Python executable',default_python(project_root)),('godot_path','Godot executable',self._default_godot()),
            ('resume','Resume checkpoint',''),('output_root','Output folder (blank = project ai)','')]
        titles={'run_name':'Run name (blank = new run)','workers':'Parallel training workers (no upper cap)',
            'steps':'Total training steps','seed':'Training seed','learning_rate':'Learning rate','batch_size':'PPO batch size',
            'gamma':'Discount factor','entropy_coefficient':'Entropy coefficient','checkpoint_every':'Checkpoint interval',
            'eval_every':'Evaluation interval (0 disables)','eval_episodes':'Evaluation episodes','eval_workers':'Evaluation workers',
            'eval_seed':'Evaluation seed','success_threshold':'Early-stop success threshold','early_stop_patience':'Early-stop patience (0 disables)',
            'torch_threads':'PPO CPU threads'}
        titles['generator_type'] = 'Road generator (original / segmented)'
        titles.update(min_eval_stage_episodes='Minimum samples per stage for early stop',
                      final_eval_episodes='Independent final evaluation episodes (0 disables)',
                      final_eval_seed='Independent final evaluation seed')
        fields += [(key,titles[key],value) for key,value in DEFAULTS.items() if key not in {'resume','output_root'}]
        for key,title,default in fields:
            row=ttk.Frame(content)
            row.pack(fill=tk.X,padx=12,pady=3)
            ttk.Label(row,text=title+':',width=34,anchor=tk.W).pack(side=tk.LEFT)
            variable=tk.StringVar(value=str(default))
            self.params[key]=variable
            entry=ttk.Entry(row,textvariable=variable,width=60 if key.endswith('path') or key in {'resume','output_root'} else 24)
            entry.pack(side=tk.LEFT,fill=tk.X,expand=True,padx=4)
            self.inputs.append(entry)
            if key in {'python_path','godot_path','resume','output_root'}:
                button=ttk.Button(row,text='Browse',command=lambda k=key:self._browse(k))
                button.pack(side=tk.LEFT)
                self.browse_buttons.append(button)
        ttk.Label(content,text='Reward weights',style='Section.TLabel').pack(anchor=tk.W,padx=12,pady=(16,4))
        self.rewards={}
        for key,default in DEFAULT_REWARD_CONFIG.items():
            row=ttk.Frame(content)
            row.pack(fill=tk.X,padx=12,pady=2)
            ttk.Label(row,text=key.replace('_',' ').title(),width=34,anchor=tk.W).pack(side=tk.LEFT)
            variable=tk.StringVar(value=str(default))
            self.rewards[key]=variable
            entry=ttk.Entry(row,textvariable=variable,width=24)
            entry.pack(side=tk.LEFT,padx=4)
            self.inputs.append(entry)
        buttons=ttk.Frame(content)
        buttons.pack(fill=tk.X,padx=12,pady=16)
        self.start_headless=ttk.Button(buttons,text='Start headless training',style='Accent.TButton',command=lambda:self.winfo_toplevel().start_training())
        self.start_visual=ttk.Button(buttons,text='Start visual training',command=lambda:self.winfo_toplevel().start_training(visual=True))
        self.start_headless.pack(side=tk.LEFT,padx=4)
        self.start_visual.pack(side=tk.LEFT,padx=4)

    def _default_godot(self):
        return default_godot(self.project_root)

    def resolve_godot(self):
        candidate = self.params['godot_path'].get().strip() or self._default_godot()
        if candidate:
            try:
                return find_godot(candidate)
            except FileNotFoundError:
                pass
        path = filedialog.askopenfilename(parent=self,
            title='Select the Godot 4 executable to present this model',
            filetypes=[('Executable', '*.exe'), ('All files', '*')])
        if not path:
            raise FileNotFoundError('Select your Godot 4 executable in Run setup, then try Present model again.')
        godot = find_godot(path)
        self.params['godot_path'].set(godot)
        return godot

    def _browse(self,key):
        if key=='output_root':
            path=filedialog.askdirectory(parent=self)
        else:
            path=filedialog.askopenfilename(parent=self,filetypes=[('Checkpoint ZIP','*.zip')] if key=='resume' else [('Executable','*.exe'),('All files','*')])
        if not path:return
        self.params[key].set(path)
        if key in {'python_path','godot_path'}:
            self.winfo_toplevel().remember_executables()
        if key=='resume':
            try:
                config=resume_settings(path)
                steps=model_metadata(Path(path)).get('steps') or 0
                config['steps']=max(int(self.params['steps'].get() or 1000000),int(steps)+1024)
                self.apply_config(config)
            except (OSError,ValueError,KeyError) as error:
                messagebox.showerror('Resume checkpoint',str(error),parent=self)

    def get_config(self):
        config={key:var.get().strip() for key,var in self.params.items()}
        try:config['rewards']={key:float(var.get()) for key,var in self.rewards.items()}
        except ValueError:raise ValueError('Reward weights must be numeric.') from None
        return config

    def apply_config(self,config):
        for key,var in self.params.items():
            if key in config:var.set(str(config[key]))
        for key,value in config.get('rewards',{}).items():
            if key in self.rewards:self.rewards[key].set(str(value))

    def set_active(self,active):
        for widget in self.inputs+self.browse_buttons+[self.start_headless,self.start_visual]:
            widget.configure(state=tk.DISABLED if active else tk.NORMAL)



# ═══════════════════════════════════════════════════════════════════════════
#  Tab 4: Present (NEW)
# ═══════════════════════════════════════════════════════════════════════════

class PresentTab(ttk.Frame):
    def __init__(self,parent,project_root):
        super().__init__(parent)
        self.project_root=project_root
        self.models={}
        self.process=None
        self.stop_path=None
        self.log_path=None
        ttk.Label(self,text='MODEL SHOWCASE',style='Heading.TLabel').pack(anchor=tk.W,padx=12,pady=12)
        buttons=ttk.Frame(self)
        buttons.pack(fill=tk.X,padx=12,pady=4)
        ttk.Button(buttons,text='Refresh models',command=self._refresh_models).pack(side=tk.LEFT,padx=4)
        ttk.Button(buttons,text='Browse model',command=self._browse_model).pack(side=tk.LEFT,padx=4)
        ttk.Button(buttons,text='Open models folder',command=self._open_folder).pack(side=tk.LEFT,padx=4)
        table=ttk.Frame(self)
        table.pack(fill=tk.BOTH,expand=True,padx=12,pady=4)
        self.tree=ttk.Treeview(table,columns=('name','steps','size','modified'),show='headings')
        for key,title,width in [('name','Model',420),('steps','Training steps',130),('size','Size',100),('modified','Modified',180)]:
            self.tree.heading(key,text=title)
            self.tree.column(key,width=width)
        scrollbar=ttk.Scrollbar(table,orient=tk.VERTICAL,command=self.tree.yview)
        self.tree.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side=tk.RIGHT,fill=tk.Y)
        self.tree.pack(fill=tk.BOTH,expand=True)
        self.tree.bind('<<TreeviewSelect>>',self._select)
        self.details=ttk.Label(self,text='Select a model to see its path.',style='Muted.TLabel',wraplength=1100)
        self.details.pack(fill=tk.X,padx=12,pady=4)
        options=ttk.Frame(self)
        options.pack(fill=tk.X,padx=12,pady=8)
        ttk.Label(options,text='Route stage:').pack(side=tk.LEFT)
        self.stage_var=tk.StringVar(value='7')
        ttk.Combobox(options,textvariable=self.stage_var,values=[str(i) for i in range(8)],state='readonly',width=5).pack(side=tk.LEFT,padx=4)
        ttk.Label(options,text='Starting seed:').pack(side=tk.LEFT,padx=8)
        self.seed_var=tk.StringVar(value='30000')
        ttk.Entry(options,textvariable=self.seed_var,width=12).pack(side=tk.LEFT,padx=4)
        self.start_button=ttk.Button(options,text='Present model',style='Accent.TButton',command=self._present)
        self.start_button.pack(side=tk.LEFT,padx=12)
        self.stop_button=ttk.Button(options,text='Stop presentation',command=self.stop,state=tk.DISABLED)
        self.stop_button.pack(side=tk.LEFT,padx=4)
        ttk.Button(options,text='Open presentation log',command=self._open_log).pack(side=tk.LEFT,padx=4)
        self.status=ttk.Label(self,text='Uses the Python and Godot executables from Run setup.',style='Muted.TLabel',wraplength=1100)
        self.status.pack(fill=tk.X,padx=12,pady=8)
        self._refresh_models()

    def _model_folder(self):
        app=self.winfo_toplevel()
        output=app.setup_tab.params['output_root'].get().strip()
        return Path(output or self.project_root/'ai')/'models'

    def _add_model(self,path):
        try:
            model=model_metadata(path)
            iid=self.tree.insert('',tk.END,values=(model['name'],model['steps'] if model['steps'] is not None else 'Unknown',
                f"{model['size']/1024:.0f} KB",time.strftime('%Y-%m-%d %H:%M',time.localtime(model['modified']))))
            self.models[iid]=model
            return iid
        except OSError:return None

    def _refresh_models(self):
        self.tree.delete(*self.tree.get_children())
        self.models.clear()
        folder=self._model_folder()
        found=list(folder.glob('*.zip'))+list((folder/'checkpoints').glob('*.zip'))
        for path in sorted(found,key=lambda p:p.name):self._add_model(path)

    def _select(self,_event=None):
        selection=self.tree.selection()
        if selection:self.details.configure(text=self.models[selection[0]]['path'])

    def _browse_model(self):
        path=filedialog.askopenfilename(parent=self,filetypes=[('Model ZIP','*.zip')])
        if path:
            iid=self._add_model(Path(path))
            if iid:self.tree.selection_set(iid);self._select()

    def _present(self):
        try:
            if self.process and self.process.poll() is None:raise ValueError('A presentation is already running.')
            selection=self.tree.selection()
            if not selection:raise ValueError('Select a model first.')
            app=self.winfo_toplevel()
            settings={key:app.setup_tab.params[key].get().strip() for key in ('python_path','godot_path')}
            python=settings.get('python_path') or default_python(self.project_root)
            if not Path(python).is_file():raise ValueError('Select a valid Python executable in Run setup.')
            godot=app.setup_tab.resolve_godot()
            app.setup_tab.params['godot_path'].set(godot)
            app.remember_executables()
            stage,seed=int(self.stage_var.get()),int(self.seed_var.get())
            run_id=str(time.time_ns())
            runs=self.project_root/'ai/runs'
            runs.mkdir(parents=True,exist_ok=True)
            self.stop_path=runs/f'presentation_{run_id}.stop'
            self.log_path=runs/f'presentation_{run_id}.log'
            args=[python,'-u',str(self.project_root/'ai/watch_policy.py'),'--model',self.models[selection[0]]['path'],
                '--godot',godot,'--curriculum-stage',str(stage),'--seed',str(seed),'--stop-file',str(self.stop_path)]
            with self.log_path.open('w',encoding='utf-8') as log:
                self.process=subprocess.Popen(args,cwd=self.project_root,stdout=log,stderr=subprocess.STDOUT,
                    creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
            self.status.configure(text='Presentation running in its Godot window. Close that window or choose Stop presentation.')
        except (OSError,ValueError) as error:
            self.status.configure(text=f'Cannot present model: {error}')

    def stop(self):
        if self.process and self.process.poll() is None and self.stop_path:
            try:self.stop_path.touch()
            except OSError as error:self.status.configure(text=f'Cannot stop presentation: {error}')

    def poll(self):
        active=self.process is not None and self.process.poll() is None
        self.start_button.configure(state=tk.DISABLED if active else tk.NORMAL)
        self.stop_button.configure(state=tk.NORMAL if active else tk.DISABLED)
        if self.process is not None and not active:
            code=self.process.returncode
            self.status.configure(text='Presentation ended.' if code==0 else f'Presentation failed (exit {code}). Open the presentation log for details.')
            self.process=None

    def _open_log(self):
        if self.log_path:open_path(self.log_path)

    def _open_folder(self):
        folder=self._model_folder()
        folder.mkdir(parents=True,exist_ok=True)
        open_path(folder)
