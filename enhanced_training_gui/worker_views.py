"""Live native Godot child windows tiled inside a Tk frame (Windows)."""
from __future__ import annotations

import math
import os
import tkinter as tk
from tkinter import ttk


class WorkerViewGrid(ttk.Frame):
    def __init__(self, parent):
        super().__init__(parent)
        self.cells = []
        self.labels = []
        self.hosts = []
        self.columns = 0
        self.worker_pids = {}
        self.bind("<Configure>", self._layout)

    def build(self, count: int) -> list[int]:
        if os.name != "nt":
            raise ValueError("Embedded Godot worker views currently require Windows.")
        for cell in self.cells:
            cell.destroy()
        self.cells, self.labels, self.hosts = [], [], []
        self.worker_pids = {}
        for index in range(count):
            cell = ttk.Frame(self, padding=3)
            label = ttk.Label(cell, text=f"Worker {index + 1} | Starting…")
            label.pack(fill=tk.X)
            host = tk.Frame(cell, bg="#07131d", container=True, width=320, height=180)
            host.pack(fill=tk.BOTH, expand=True)
            self.cells.append(cell)
            self.labels.append(label)
            self.hosts.append(host)
        self.columns = 0
        self._layout()
        self.update_idletasks()
        return [host.winfo_id() for host in self.hosts]

    def _layout(self, _event=None):
        if not self.cells:
            return
        count = len(self.cells)
        columns = min(count, max(1, min(4, math.ceil(math.sqrt(count)))))
        if count == 8:
            columns = 4
        if columns != self.columns:
            for i in range(max(self.columns, count)):
                self.columnconfigure(i, weight=0, minsize=0)
                self.rowconfigure(i, weight=0, minsize=0)
            for i, cell in enumerate(self.cells):
                cell.grid(row=i // columns, column=i % columns, sticky="nsew")
            for i in range(columns):
                self.columnconfigure(i, weight=1, uniform="workers")
            for i in range(math.ceil(count / columns)):
                self.rowconfigure(i, weight=1, uniform="worker_rows")
            self.columns = columns

    def update_workers(self, status: dict):
        state = status.get("state", "idle")
        self.worker_pids = {}
        if state not in {'starting', 'running', 'paused', 'stopping', 'saving'}:
            for index, label in enumerate(self.labels):
                label.configure(text=f"Worker {index+1} | {state.title()}")
            return
        for index, label in enumerate(self.labels):
            metrics = status.get("worker_metrics", [])
            worker = metrics[index] if index < len(metrics) else {}
            if worker:
                if worker.get('godot_pid'):
                    self.worker_pids[int(worker['godot_pid'])] = self.hosts[index].winfo_id()
                label.configure(text=f"Worker {index+1} | Stage {worker.get('episode_stage', 0)} | "
                    f"{worker.get('speed_kmh', 0):.0f} km/h | {worker.get('progress', 0):.0%}")
            else:
                label.configure(text=f"Worker {index+1} | {state.title()}")
        self.resize_children()

    def resize_children(self):
        if os.name != "nt":
            return
        import ctypes
        from ctypes import wintypes

        user = ctypes.WinDLL("user32", use_last_error=True)
        callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        user.EnumChildWindows.argtypes = [wintypes.HWND, callback_type, wintypes.LPARAM]
        user.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
        user.GetParent.argtypes = [wintypes.HWND]
        user.GetParent.restype = wintypes.HWND
        user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        user.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
        user.SetParent.argtypes = [wintypes.HWND, wintypes.HWND]
        user.SetParent.restype = wintypes.HWND
        user.GetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int]
        user.GetWindowLongPtrW.restype = ctypes.c_ssize_t
        user.SetWindowLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_ssize_t]
        user.SetWindowLongPtrW.restype = ctypes.c_ssize_t
        user.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                                      ctypes.c_int, ctypes.c_int, wintypes.UINT]
        # Godot's --wid initially creates an owned popup on Windows. Convert
        # that window to a true child so clipping/tab switching works correctly.
        parents = {host.winfo_id() for host in self.hosts}

        @callback_type
        def attach(window, _data):
            class_name = ctypes.create_unicode_buffer(256)
            user.GetClassNameW(window, class_name, 256)
            if class_name.value != 'Engine':
                return True
            owner = user.GetParent(window)
            pid = wintypes.DWORD()
            user.GetWindowThreadProcessId(window, ctypes.byref(pid))
            parent = self.worker_pids.get(pid.value, owner if owner in parents else None)
            if parent is not None:
                style = user.GetWindowLongPtrW(window, -16)
                user.SetWindowLongPtrW(window, -16, (style & ~0x80000000 & ~0x00C00000 & ~0x00040000) | 0x40000000)
                user.SetParent(window, parent)
                user.SetWindowPos(window, None, 0, 0, 1, 1, 0x0004 | 0x0010 | 0x0020 | 0x4000)
            return True

        user.EnumWindows(attach, 0)
        for host in self.hosts:
            parent_id = host.winfo_id()
            width, height = max(1, host.winfo_width()), max(1, host.winfo_height())

            @callback_type
            def resize(child, _data):
                if user.GetParent(child) == parent_id:
                    user.SetWindowPos(child, None, 0, 0, width, height, 0x0004 | 0x0010 | 0x4000)
                return True

            user.EnumChildWindows(parent_id, resize, 0)
