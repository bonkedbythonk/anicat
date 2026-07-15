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

use axum::http::HeaderMap;
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

/// The IP to throttle a login attempt against. Behind `tailscale serve` (which
/// terminates TLS and proxies to 127.0.0.1) the TCP peer is loopback for every
/// friend, which would otherwise collapse them all into one shared lockout
/// bucket — one person fat-fingering their PIN 5x would lock out everyone. So
/// when the peer is loopback we trust the first `X-Forwarded-For` hop, which
/// serve sets to the caller's real tailnet IP. A non-loopback peer is a direct
/// hit on `0.0.0.0:13370`, so its own address is authoritative and any
/// client-supplied `X-Forwarded-For` is ignored — otherwise an attacker
/// reaching the port directly could forge the header to dodge the throttle.
pub fn client_ip(peer: IpAddr, headers: &HeaderMap) -> IpAddr {
    if peer.is_loopback() {
        if let Some(first) = headers
            .get("x-forwarded-for")
            .and_then(|v| v.to_str().ok())
            .and_then(|xff| xff.split(',').next())
        {
            if let Ok(ip) = first.trim().parse::<IpAddr>() {
                return ip;
            }
        }
    }
    peer
}

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

    #[test]
    fn client_ip_trusts_xff_only_from_loopback() {
        let mut h = HeaderMap::new();
        h.insert("x-forwarded-for", "100.64.0.9, 10.0.0.1".parse().unwrap());
        // Loopback peer (behind serve): trust the first XFF hop.
        let lo: IpAddr = "127.0.0.1".parse().unwrap();
        assert_eq!(client_ip(lo, &h).to_string(), "100.64.0.9");
        // Direct non-loopback hit: ignore XFF, use the real peer.
        let direct: IpAddr = "192.168.1.50".parse().unwrap();
        assert_eq!(client_ip(direct, &h), direct);
        // Loopback with no XFF (desktop mpv): falls back to the peer.
        assert_eq!(client_ip(lo, &HeaderMap::new()), lo);
        // Garbage XFF from loopback: ignored, falls back to the peer.
        let mut bad = HeaderMap::new();
        bad.insert("x-forwarded-for", "not-an-ip".parse().unwrap());
        assert_eq!(client_ip(lo, &bad), lo);
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
