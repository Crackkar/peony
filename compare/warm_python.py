"""A started CPython process that executes independent corpus jobs."""

import io
import json
import os
import sys
import threading
import time
import tracemalloc

if sys.platform != "win32":
    raise RuntimeError("the comparison harness currently requires Windows")

import ctypes
from ctypes import wintypes


class MemoryCounters(ctypes.Structure):
    _fields_ = [
        ("cb", wintypes.DWORD),
        ("PageFaultCount", wintypes.DWORD),
        ("PeakWorkingSetSize", ctypes.c_size_t),
        ("WorkingSetSize", ctypes.c_size_t),
        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
        ("PagefileUsage", ctypes.c_size_t),
        ("PeakPagefileUsage", ctypes.c_size_t),
    ]


kernel = ctypes.WinDLL("kernel32", use_last_error=True)
memory_api = ctypes.WinDLL("psapi", use_last_error=True)
kernel.GetCurrentProcess.restype = wintypes.HANDLE
memory_api.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(MemoryCounters), wintypes.DWORD]
memory_api.GetProcessMemoryInfo.restype = wintypes.BOOL


def memory_bytes():
    counters = MemoryCounters()
    counters.cb = ctypes.sizeof(counters)
    if not memory_api.GetProcessMemoryInfo(kernel.GetCurrentProcess(), ctypes.byref(counters), counters.cb):
        raise OSError(ctypes.get_last_error(), "GetProcessMemoryInfo failed")
    return int(counters.WorkingSetSize), int(counters.PeakWorkingSetSize)


def respond(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


class RssSampler:
    def __init__(self):
        self.active = threading.Event()
        self.peak = 0
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()

    def sample(self):
        while True:
            self.active.wait()
            current, _ = memory_bytes()
            if current > self.peak:
                self.peak = current
            time.sleep(0.001)

    def start(self):
        baseline, self.previous_high_water = memory_bytes()
        self.peak = baseline
        self.active.set()
        return baseline

    def finish(self):
        self.active.clear()
        current, high_water = memory_bytes()
        peak = max(self.peak, current)
        if high_water > self.previous_high_water:
            peak = max(peak, high_water)
        return current, peak


source = None
filename = None
baseline_modules = set(sys.modules)
sys.path.insert(0, "")
sampler = RssSampler()
respond({"ready": True, "rss_bytes": memory_bytes()[0]})
for line in sys.stdin:
    try:
        request = json.loads(line)
        if request["op"] == "setup":
            source = request["source"]
            filename = request["filename"]
            respond({"ok": True})
            continue
        if request["op"] != "run" or source is None:
            raise ValueError("expected a configured run")
        if request.get("measure") not in ("time", "rss", "runtime"):
            raise ValueError("run requires time, rss, or runtime measurement mode")
        for name in tuple(sys.modules):
            if name not in baseline_modules:
                del sys.modules[name]
        os.chdir(request["cwd"])
        sys.path[0] = request["cwd"]
        captured_stdout = io.StringIO()
        captured_stderr = io.StringIO()
        real_stdout, real_stderr = sys.stdout, sys.stderr
        rss_pass = request["measure"] == "rss"
        runtime_pass = request["measure"] == "runtime"
        if rss_pass:
            baseline_rss = sampler.start()
        else:
            baseline_rss = memory_bytes()[0]
        if runtime_pass:
            tracemalloc.start()
        status = "completed"
        error = ""
        started = time.perf_counter_ns()
        try:
            sys.stdout, sys.stderr = captured_stdout, captured_stderr
            sys.argv = [filename, *request["argv"]]
            namespace = {"__name__": "__main__", "__file__": filename, "__builtins__": __builtins__}
            exec(compile(source, filename, "exec"), namespace, namespace)
        except BaseException as exception:
            status = "error"
            error = type(exception).__name__ + ": " + str(exception)
        finally:
            elapsed_ns = time.perf_counter_ns() - started
            sys.stdout, sys.stderr = real_stdout, real_stderr
        if rss_pass:
            current, peak = sampler.finish()
        else:
            current, _ = memory_bytes()
            peak = max(baseline_rss, current)
        if runtime_pass:
            _, runtime_peak = tracemalloc.get_traced_memory()
            tracemalloc.stop()
        else:
            runtime_peak = 0
        respond({"ok": True, "status": status, "error": error,
                 "stdout": captured_stdout.getvalue(), "stderr": captured_stderr.getvalue(),
                 "elapsed_ns": elapsed_ns, "rss_bytes": current,
                 "baseline_rss_bytes": baseline_rss, "peak_rss_bytes": peak,
                 "runtime_peak_bytes": runtime_peak,
                 "runtime_job_bytes": runtime_peak})
    except BaseException as exception:
        respond({"ok": False, "error": type(exception).__name__ + ": " + str(exception)})
