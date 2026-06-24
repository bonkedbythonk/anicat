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
