/// Find a binary on the system PATH, returning its full path if present.
/// Uses `which` on Unix and `where` on Windows so a user-installed mpv/uv/yt-dlp
/// (Homebrew, winget, scoop, choco) is discovered the same way on both.
pub fn find_on_path(bin: &str) -> Option<String> {
    let finder = if cfg!(target_os = "windows") { "where" } else { "which" };
    let mut cmd = std::process::Command::new(finder);
    cmd.arg(bin);
    suppress_console(&mut cmd);
    let out = cmd.output().ok()?;
    if !out.status.success() {
        return None;
    }
    // `where` can return several lines; take the first that actually exists.
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| l.trim())
        .find(|p| !p.is_empty() && std::path::Path::new(p).exists())
        .map(|s| s.to_string())
}

/// Stop a console window from flashing when the GUI app spawns a subprocess on
/// Windows (CREATE_NO_WINDOW). No-op on other platforms.
pub fn suppress_console(cmd: &mut std::process::Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    {
        let _ = cmd;
    }
}

/// tokio::process::Command variant of [`suppress_console`].
pub fn suppress_console_tokio(cmd: &mut tokio::process::Command) {
    #[cfg(windows)]
    {
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    {
        let _ = cmd;
    }
}

/// Kill a child process *and its descendants*, then reap it.
///
/// On Windows the bundled scraper is a PyInstaller `--onefile` binary: the
/// `.exe` we spawn is a bootloader that extracts itself to a temp dir and
/// launches a *child* process to actually run the server. `Child::kill`
/// (TerminateProcess) only terminates the bootloader, orphaning that child —
/// which is why scraper processes accumulated. `taskkill /T` walks the whole
/// process tree, so the extracted child goes down with the parent.
pub fn kill_child_tree(child: &mut std::process::Child) {
    #[cfg(windows)]
    {
        let mut cmd = std::process::Command::new("taskkill");
        cmd.args(["/PID", &child.id().to_string(), "/T", "/F"]);
        suppress_console(&mut cmd);
        let _ = cmd.output();
    }
    // Fallback / non-Windows: kill the process directly and reap it so it does
    // not linger as a zombie.
    let _ = child.kill();
    let _ = child.wait();
}

pub fn percent_encode(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(byte as char);
            }
            b' ' => result.push('+'),
            _ => result.push_str(&format!("%{:02X}", byte)),
        }
    }
    result
}
