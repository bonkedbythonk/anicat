//! Brute-force protection for the two login endpoints (`mobile_auth::authenticate`
//! and `session::login`). Deliberately absent when the only boundary was "stop
//! a sibling stumbling in on the home LAN" — but on a Tailscale-shared headless
//! deployment the people who can reach the login form are invited friends, and
//! a 4-8 digit numeric PIN with no rate limit is trivially scriptable. This
//! caps failed attempts per source IP so a friend can't hammer the owner's (or
//! anyone's) account.
//!
//! In-memory only: a restart clears all counters, which is fine — a restart
//! also can't be triggered by a remote client, and losing lockout state on a
//! deploy is harmless. Keyed by the peer IP, which on a tailnet is a stable
//! per-device address, so one misbehaving device locks only itself out.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

/// Consecutive failures before a lockout kicks in.
const MAX_FAILS: u32 = 5;
/// How long an IP stays locked out once it trips `MAX_FAILS`.
const LOCKOUT: Duration = Duration::from_secs(60);

#[derive(Default)]
struct Attempt {
    fails: u32,
    locked_until: Option<Instant>,
}

#[derive(Clone, Default)]
pub struct LoginThrottle {
    inner: Arc<Mutex<HashMap<IpAddr, Attempt>>>,
}

impl LoginThrottle {
    pub fn new() -> Self {
        Self::default()
    }

    /// If `ip` is currently locked out, returns the remaining seconds; the
    /// caller should reject the login without even checking credentials.
    /// A lock that has expired is cleared here so the next attempt starts fresh.
    pub async fn check(&self, ip: IpAddr) -> Option<u64> {
        let mut map = self.inner.lock().await;
        if let Some(a) = map.get_mut(&ip) {
            if let Some(until) = a.locked_until {
                let now = Instant::now();
                if now < until {
                    return Some((until - now).as_secs() + 1);
                }
                a.locked_until = None;
                a.fails = 0;
            }
        }
        None
    }

    /// Record a failed credential check. Trips a lockout at `MAX_FAILS`.
    pub async fn record_failure(&self, ip: IpAddr) {
        let mut map = self.inner.lock().await;
        let a = map.entry(ip).or_default();
        a.fails += 1;
        if a.fails >= MAX_FAILS {
            a.locked_until = Some(Instant::now() + LOCKOUT);
        }
    }

    /// A successful login clears the IP's failure history entirely.
    pub async fn record_success(&self, ip: IpAddr) {
        let mut map = self.inner.lock().await;
        map.remove(&ip);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn locks_out_after_max_fails() {
        let t = LoginThrottle::new();
        let ip: IpAddr = "100.64.0.1".parse().unwrap();
        for _ in 0..MAX_FAILS {
            assert!(t.check(ip).await.is_none());
            t.record_failure(ip).await;
        }
        // Now locked.
        assert!(t.check(ip).await.is_some());
    }

    #[tokio::test]
    async fn success_clears_failures() {
        let t = LoginThrottle::new();
        let ip: IpAddr = "100.64.0.2".parse().unwrap();
        t.record_failure(ip).await;
        t.record_failure(ip).await;
        t.record_success(ip).await;
        // Fresh slate — would take MAX_FAILS again to lock.
        for _ in 0..(MAX_FAILS - 1) {
            t.record_failure(ip).await;
        }
        assert!(t.check(ip).await.is_none());
    }

    #[tokio::test]
    async fn distinct_ips_are_independent() {
        let t = LoginThrottle::new();
        let a: IpAddr = "100.64.0.3".parse().unwrap();
        let b: IpAddr = "100.64.0.4".parse().unwrap();
        for _ in 0..MAX_FAILS {
            t.record_failure(a).await;
        }
        assert!(t.check(a).await.is_some());
        assert!(t.check(b).await.is_none());
    }
}
