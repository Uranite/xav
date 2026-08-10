use core::time::Duration;
#[cfg(not(target_os = "linux"))]
use std::time::{Instant, SystemTime, UNIX_EPOCH};

#[cfg(target_os = "linux")]
use crate::sys::{clock_mono_ns, clock_real};

#[cfg(not(target_os = "linux"))]
use std::sync::OnceLock;

#[cfg(target_os = "linux")]
#[derive(Clone, Copy)]
pub struct Mono(u64);

#[cfg(not(target_os = "linux"))]
#[derive(Clone, Copy)]
pub struct Mono(Instant);

#[cfg(target_os = "linux")]
impl Mono {
    #[inline]
    pub fn now() -> Self {
        Self(clock_mono_ns())
    }

    #[inline]
    pub fn elapsed(self) -> Duration {
        Duration::from_nanos(clock_mono_ns() - self.0)
    }

    #[inline]
    pub const fn raw(self) -> u64 {
        self.0
    }
}

#[cfg(not(target_os = "linux"))]
static BASE: OnceLock<Instant> = OnceLock::new();

#[cfg(not(target_os = "linux"))]
impl Mono {
    #[inline]
    pub fn now() -> Self {
        Self(Instant::now())
    }

    #[inline]
    pub fn elapsed(self) -> Duration {
        self.0.elapsed()
    }

    #[inline]
    pub fn raw(self) -> u64 {
        let d = self.0.duration_since(*BASE.get_or_init(Instant::now));
        (d.as_secs() as u64) * 1_000_000_000 + u64::from(d.subsec_nanos())
    }
}

#[cfg(target_os = "linux")]
pub fn realtime() -> (u64, u32) {
    clock_real()
}

#[cfg(not(target_os = "linux"))]
pub fn realtime() -> (u64, u32) {
    let d = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    (d.as_secs(), d.subsec_nanos())
}
