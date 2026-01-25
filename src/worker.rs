use std::sync::{Condvar, Mutex};

use crate::chunk::Chunk;

pub struct WorkPkg {
    pub chunk: Chunk,
    pub yuv: Vec<u8>,
    pub frame_count: usize,
    pub width: u32,
    pub height: u32,
    #[cfg(feature = "vship")]
    pub tq_state: Option<TQState>,
}

#[cfg(feature = "vship")]
pub struct TQState {
    pub probes: Vec<crate::tq::Probe>,
    pub probe_sizes: Vec<(f64, u64)>,
    pub search_min: f64,
    pub search_max: f64,
    pub round: usize,
    pub target: f64,
    pub last_crf: f64,
    pub final_encode: bool,
}

impl WorkPkg {
    pub const fn new(
        chunk: Chunk,
        yuv: Vec<u8>,
        frame_count: usize,
        width: u32,
        height: u32,
    ) -> Self {
        Self {
            chunk,
            yuv,
            frame_count,
            width,
            height,
            #[cfg(feature = "vship")]
            tq_state: None,
        }
    }
}

pub struct Semaphore {
    state: Mutex<usize>,
    cvar: Condvar,
}

impl Semaphore {
    pub const fn new(permits: usize) -> Self {
        Self { state: Mutex::new(permits), cvar: Condvar::new() }
    }

    pub fn acquire_interruptible(&self, shutdown: &std::sync::atomic::AtomicBool) -> bool {
        let mut count = self.state.lock().unwrap();
        loop {
            if shutdown.load(std::sync::atomic::Ordering::Relaxed) {
                return false;
            }
            if *count > 0 {
                *count -= 1;
                return true;
            }
            // Use wait_timeout to periodically check the shutdown flag
            let (new_count, _) =
                self.cvar.wait_timeout(count, std::time::Duration::from_millis(100)).unwrap();
            count = new_count;
        }
    }

    pub fn release(&self) {
        *self.state.lock().unwrap() += 1;
        self.cvar.notify_one();
    }
}
