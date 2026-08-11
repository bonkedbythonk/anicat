//! Per-install secret that keys the mobile auth tokens.
//!
//! Both auth models derive a client's token from live state rather than keeping
//! a server-side session store, and that design is worth preserving: it needs
//! no expiry bookkeeping, survives a restart, and gets invalidation for free
//! (change the PIN and every issued token stops matching). What it must not
//! also do is make the token a *derivation of the PIN alone*.
//!
//! It used to. The token was `sha256(pin)`, unsalted, over a 4-8 digit numeric
//! PIN — a space small enough to exhaust offline in well under a second. So a
//! token leaking anywhere it plausibly could (a shared phone, a log, a device
//! backup) handed over the PIN itself, and the login throttle is no help
//! against an attack that never touches the login endpoint. Mixing this secret
//! in keeps every property above while making the token useless for recovering
//! the PIN: inverting it now means guessing 244 bits, not 10,000.
//!
//! Kept deliberately out of `config.toml`. `AppConfig` is `Serialize` and gets
//! rewritten wholesale by `save_config`, and `MobileConfig` is already surfaced
//! in desktop Settings — a secret that round-trips through a settings UI would
//! be worse than the hash it replaces. It lives next to `registry.db` instead,
//! 0600, and nothing reads it but this module.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

static SECRET: OnceLock<String> = OnceLock::new();

fn secret_path(db_path: &str) -> PathBuf {
    Path::new(db_path)
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("session-secret")
}

#[cfg(unix)]
fn harden(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
}

#[cfg(not(unix))]
fn harden(_path: &Path) {}

/// Loads the install's token secret, generating and persisting one on first
/// use. Read once per process — the file is never rewritten after creation, so
/// tokens stay valid across restarts.
///
/// Two v4 UUIDs, so 244 bits from the OS CSPRNG. `uuid` is already a
/// dependency, which is why this doesn't pull in a crate just to read random
/// bytes.
///
/// If the file cannot be written (read-only home, permissions), the generated
/// secret is still used for this process's lifetime. Auth keeps working; the
/// only consequence is that a restart invalidates outstanding tokens and
/// clients re-enter their PIN.
pub fn server_secret(db_path: &str) -> &'static str {
    SECRET.get_or_init(|| {
        let path = secret_path(db_path);
        if let Ok(existing) = std::fs::read_to_string(&path) {
            let existing = existing.trim().to_string();
            if !existing.is_empty() {
                harden(&path);
                return existing;
            }
        }
        let generated = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        match std::fs::write(&path, &generated) {
            Ok(()) => {
                harden(&path);
                log::info!("Generated a new mobile session secret at {:?}", path);
            }
            Err(e) => log::warn!(
                "Could not persist the mobile session secret to {:?} ({}); \
                 tokens will be invalidated on restart",
                path, e
            ),
        }
        generated
    })
}

/// Derives a token from the secret plus a caller-supplied context.
///
/// `sha256(secret | context | value)` rather than HMAC: the construction only
/// needs to be one-way and unguessable without the secret, and there is no
/// length-extension exposure here because an attacker never controls a prefix
/// and verification recomputes the exact digest for the one input it accepts.
/// `context` keeps the two token families (shared PIN vs. per-user) from
/// colliding.
pub(crate) fn derive_token(secret: &str, context: &str, value: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(secret.as_bytes());
    hasher.update(b"|");
    hasher.update(context.as_bytes());
    hasher.update(b"|");
    hasher.update(value.as_bytes());
    format!("{:x}", hasher.finalize())
}

/// Length-independent-time equality for token comparison.
///
/// The realistic attack here is offline brute force, not remote timing, so this
/// is belt-and-braces — but a token check is exactly the place where the cheap
/// version costs nothing.
pub(crate) fn tokens_match(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn context_separates_the_two_token_families() {
        // The shared-PIN and per-user tokens must not collide even when the
        // secret and the value happen to be identical.
        assert_ne!(derive_token("s", "pin", "1234"), derive_token("s", "user", "1234"));
    }

    #[test]
    fn a_different_secret_yields_a_different_token() {
        // This is the whole point: without the secret, a token cannot be
        // computed from the PIN, so a leaked token cannot be inverted to one.
        assert_ne!(derive_token("secret-a", "pin", "1234"), derive_token("secret-b", "pin", "1234"));
        assert_eq!(derive_token("secret-a", "pin", "1234"), derive_token("secret-a", "pin", "1234"));
    }

    #[test]
    fn tokens_match_compares_correctly() {
        assert!(tokens_match("abc", "abc"));
        assert!(!tokens_match("abc", "abd"));
        assert!(!tokens_match("abc", "ab"));
        assert!(!tokens_match("", "a"));
        assert!(tokens_match("", ""));
    }

    #[test]
    fn secret_path_sits_next_to_the_registry_db() {
        assert_eq!(
            secret_path("/home/u/.config/anicat/registry.db"),
            Path::new("/home/u/.config/anicat/session-secret")
        );
    }
}
