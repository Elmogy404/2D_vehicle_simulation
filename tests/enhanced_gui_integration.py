"""Optional Windows desktop test: real embedded PPO workers and model presentation.

Run with the project venv and --godot PATH. Keeps user training files untouched.
"""
from __future__ import annotations
import argparse
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import sys
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'enhanced_training_gui'))
from gui_app import EnhancedTrainingApp
from training_session import TrainingSession, model_metadata, resume_settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True)
    parser.add_argument('--workers', type=int, default=8)
    args = parser.parse_args()
    output = ROOT / 'ai/runs/enhanced_gui_validation'
    output.mkdir(parents=True, exist_ok=True)
    session = TrainingSession(ROOT, status_path=output / 'status.json')
    app = EnhancedTrainingApp(ROOT, session=session)
    app.geometry('1280x900+20+20')

    def wait_for(predicate, description, seconds=60):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            app.update()
            if predicate():
                return
            status = session.read_status()
            if status.get('state') == 'failed':
                raise AssertionError(f'{description}: {status.get("message")} / {status.get("log_path")}')
            time.sleep(.01)
        raise AssertionError(f'Timeout: {description}; {session.read_status()}')

    # Native Godot child handles must exist separately for every worker.
    def native_children():
        user = ctypes.WinDLL('user32', use_last_error=True)
        callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        user.EnumChildWindows.argtypes = [wintypes.HWND, callback_type, wintypes.LPARAM]
        user.GetParent.argtypes = [wintypes.HWND]
        user.GetParent.restype = wintypes.HWND
        user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        children = []
        for host in app.visual_tab.views.hosts:
            parent = host.winfo_id()
            found = []
            @callback_type
            def visit(child, _data):
                pid = wintypes.DWORD()
                user.GetWindowThreadProcessId(child, ctypes.byref(pid))
                if user.GetParent(child) == parent and pid.value != os.getpid():
                    found.append(pid.value)
                return True
            user.EnumChildWindows(parent, visit, 0)
            children.append(found)
        return children

    try:
        name = f'enhanced_visual_{time.time_ns()}'
        app.setup_tab.apply_config(dict(python_path=sys.executable, godot_path=args.godot,
            output_root=str(output), run_name=name, resume='', workers=args.workers,
            steps=100000, eval_every=0, early_stop_patience=0, checkpoint_every=1024))
        app.start_training(visual=True)
        wait_for(lambda: session.read_status().get('timesteps', 0) >= args.workers * 8, 'collecting experience')
        wait_for(lambda: all(native_children()), 'native worker window attachment', seconds=15)
        children = native_children()
        if not all(children):
            user = ctypes.WinDLL('user32')
            callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
            user.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
            user.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
            user.GetParent.argtypes = [wintypes.HWND]
            user.GetParent.restype = wintypes.HWND
            windows = []
            @callback_type
            def inspect(window, _data):
                name = ctypes.create_unicode_buffer(256)
                user.GetClassNameW(window, name, 256)
                if name.value == 'Engine':
                    windows.append((window, user.GetParent(window)))
                return True
            user.EnumWindows(inspect, 0)
            print('DEBUG PARENTS:', [h.winfo_id() for h in app.visual_tab.views.hosts], 'ENGINE WINDOWS:', windows, flush=True)
        assert len(children) == args.workers and all(len(x) == 1 for x in children), children
        assert len(set(x[0] for x in children)) == args.workers, children
        print('LIVE GRID:', args.workers, 'distinct embedded Godot processes', flush=True)
        app.update()
        capture = r'''
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class TrainingWindowCapture { [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags); }'
$bounds = $env:TRAINING_VIEW_RECT.Split(',')
$bitmap = New-Object System.Drawing.Bitmap ([int]$bounds[2]),([int]$bounds[3])
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $dc = $graphics.GetHdc()
    try { $ok = [TrainingWindowCapture]::PrintWindow([IntPtr]([long]$env:TRAINING_VIEW_HANDLE),$dc,3) }
    finally { $graphics.ReleaseHdc($dc) }
    if (-not $ok) { throw 'Training window capture failed' }
    $bitmap.Save($env:TRAINING_VIEW_CAPTURE,[System.Drawing.Imaging.ImageFormat]::Png)
} finally { $graphics.Dispose(); $bitmap.Dispose() }
'''
        capture_process = subprocess.Popen(['powershell','-NoProfile','-NonInteractive','-Command',capture],
            env={**os.environ,'TRAINING_VIEW_CAPTURE':str(output/'live_workers.png'),
                 'TRAINING_VIEW_HANDLE':str(app.winfo_id()),
                 'TRAINING_VIEW_RECT':','.join(str(x) for x in (app.winfo_rootx(),app.winfo_rooty(),app.winfo_width(),app.winfo_height()))},
            creationflags=subprocess.CREATE_NO_WINDOW)
        wait_for(lambda: capture_process.poll() is not None, 'window capture', seconds=15)
        assert capture_process.returncode == 0
        app.send_command('pause')
        wait_for(lambda: session.read_status().get('state') == 'paused', 'pause')
        paused_steps = session.read_status()['timesteps']
        until = time.monotonic() + .5
        while time.monotonic() < until:
            app.update()
            time.sleep(.01)
        assert session.read_status()['timesteps'] == paused_steps
        app.send_command('run')
        wait_for(lambda: session.read_status().get('timesteps', 0) > paused_steps, 'resume')
        app.send_command('stop')
        wait_for(lambda: session.read_status().get('state') == 'stopped' and not session.is_active(), 'save/stop')
        path = output / 'models' / (name + '.zip')
        assert path.is_file() and model_metadata(path)['steps'] > 0
        assert all(not group for group in native_children()), 'worker windows survived clean stop'
        print('PAUSE / RESUME / SAVE / CHILD CLEANUP: passed', flush=True)
        previous_steps = model_metadata(path)['steps']
        resumed = resume_settings(path)
        resumed.update(steps=previous_steps+2048, eval_every=0, early_stop_patience=0)
        app.setup_tab.apply_config(resumed)
        app.start_training(visual=False)
        wait_for(lambda: session.read_status().get('timesteps',0)>previous_steps, 'headless checkpoint resume')
        app.send_command('stop')
        wait_for(lambda: session.read_status().get('state')=='stopped' and not session.is_active(), 'headless resume save/stop')
        assert model_metadata(path)['steps']>previous_steps
        print('RESUME VISUAL CHECKPOINT IN HEADLESS MODE: passed', flush=True)
        app.present_tab._refresh_models()
        chosen = next(iid for iid, model in app.present_tab.models.items() if model['path'] == str(path))
        app.present_tab.tree.selection_set(chosen)
        app.present_tab._present()
        assert app.present_tab.process is not None
        until = time.monotonic() + 3
        while time.monotonic() < until:
            app.update()
            time.sleep(.01)
        assert app.present_tab.process.poll() is None, app.present_tab.log_path
        app.present_tab.stop()
        wait_for(lambda: app.present_tab.process is None, 'presentation stop', seconds=30)
        assert 'Presentation ended' in app.present_tab.status.cget('text')
        print('MODEL PRESENTATION / STOP: passed', flush=True)
    finally:
        if session.is_active():
            session.command('stop')
            deadline = time.monotonic()+30
            while session.is_active() and time.monotonic() < deadline:
                app.update()
                time.sleep(.02)
        app.present_tab.stop()
        app.destroy()


if __name__ == '__main__':
    main()
