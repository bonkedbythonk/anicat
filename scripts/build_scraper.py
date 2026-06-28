import os
import sys
import shutil
import subprocess
import platform

def run_cmd(cmd, cwd=None):
    print(f"Executing: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=cwd)
    if result.returncode != 0:
        raise RuntimeError(f"Command failed with exit code {result.returncode}")

def main():
    # Get project root (parent of scripts directory)
    current_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.abspath(os.path.join(current_dir, ".."))
    
    scraper_dir = os.path.join(project_root, "scraper")
    target_dir = os.path.join(project_root, "web", "src-tauri", "resources", "scraper-bin")
    
    os.makedirs(target_dir, exist_ok=True)
    
    # Check if we should use uv or system python/pyinstaller
    use_uv = shutil.which("uv") is not None
    
    # Build command
    binary_name = "anicat-scraper"
    pyinstaller_cmd = [
        "pyinstaller",
        "--noconfirm",
        "--clean",
        "--onedir",
        "--name", binary_name,
        "--hidden-import", "curl_cffi",
        "--hidden-import", "selectolax",
        "--collect-all", "curl_cffi",
        "--collect-all", "selectolax",
        "--exclude-module", "setuptools",
        "main.py"
    ]

    if use_uv:
        cmd = ["uv", "run"] + pyinstaller_cmd
    else:
        cmd = pyinstaller_cmd

    print("Compiling Python scraper to a standalone binary...")
    run_cmd(cmd, cwd=scraper_dir)

    # --onedir produces dist/anicat-scraper/ (a directory).
    # Copy the whole directory into scraper-bin/ so the layout is:
    #   scraper-bin/anicat-scraper/anicat-scraper  (the executable)
    #   scraper-bin/anicat-scraper/_internal/...   (Python runtime + libs)
    built_dir = os.path.join(scraper_dir, "dist", binary_name)
    dest_dir = os.path.join(target_dir, binary_name)

    if not os.path.isdir(built_dir):
        raise FileNotFoundError(f"Could not find compiled directory at {built_dir}")

    if os.path.isdir(dest_dir):
        shutil.rmtree(dest_dir)
    elif os.path.exists(dest_dir):
        os.remove(dest_dir)

    print(f"Moving compiled directory to {dest_dir}")
    shutil.move(built_dir, dest_dir)
    print("Scraper compilation and bundling complete!")

if __name__ == "__main__":
    main()
