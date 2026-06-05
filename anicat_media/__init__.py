import sys

# Reconfigure stdout and stderr on Windows to UTF-8 to prevent any potential Unicode encoding issues
if sys.platform == "win32":
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    if hasattr(sys.stderr, "reconfigure"):
        try:
            sys.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass

    # Monkeypatch subprocess.Popen on Windows to always set CREATE_NO_WINDOW creation flags.
    # This prevents console window popups when subprocesses (like git or tasklist) are executed.
    import subprocess
    _original_popen = subprocess.Popen
    class SafePopen(_original_popen):
        def __init__(self, args, *orig_args, **kwargs):
            # CREATE_NO_WINDOW = 0x08000000
            kwargs["creationflags"] = kwargs.get("creationflags", 0) | 0x08000000
            super().__init__(args, *orig_args, **kwargs)
    subprocess.Popen = SafePopen

if sys.version_info < (3, 11):
    raise ImportError(
        "You are using an unsupported version of Python. Only Python 3.11 or newer is supported by Anicat"
    )




