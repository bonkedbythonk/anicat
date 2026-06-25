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
        "--onefile",
        "--name", binary_name,
        "--hidden-import", "curl_cffi",
        "--hidden-import", "selectolax",
        "--collect-all", "curl_cffi",
        "--collect-all", "selectolax",
        "main.py"
    ]
    
    if use_uv:
        cmd = ["uv", "run"] + pyinstaller_cmd
    else:
        cmd = pyinstaller_cmd
        
    print("Compiling Python scraper to a standalone binary...")
    run_cmd(cmd, cwd=scraper_dir)
    
    # Locate built binary
    ext = ".exe" if platform.system() == "Windows" else ""
    built_bin = os.path.join(scraper_dir, "dist", f"{binary_name}{ext}")
    dest_bin = os.path.join(target_dir, f"{binary_name}{ext}")
    
    if not os.path.exists(built_bin):
        raise FileNotFoundError(f"Could not find compiled binary at {built_bin}")
        
    print(f"Moving compiled binary to {dest_bin}")
    shutil.move(built_bin, dest_bin)
    print("Scraper binary compilation and bundling complete!")

if __name__ == "__main__":
    main()
