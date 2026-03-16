use std::{
    ffi::NulError,
    fmt::{Arguments, Display},
    io::{Error, Write as _, stderr, stdout},
    num::{ParseFloatError, ParseIntError},
    sync::atomic::{AtomicBool, Ordering::Relaxed},
};

use libc::_exit;
use thiserror::Error;

use crate::error::Xerr::Msg;

pub static IN_ALT_SCREEN: AtomicBool = AtomicBool::new(false);

#[derive(Error, Debug)]
pub enum Xerr {
    #[error("{0}")]
    Io(#[from] Error),

    #[error("{0}")]
    Ffi(#[from] NulError),

    #[error("{0}")]
    ParseInt(#[from] ParseIntError),

    #[error("{0}")]
    ParseFloat(#[from] ParseFloatError),

    #[error("{0}")]
    Msg(String),

    #[error("")]
    Help,

    #[error("")]
    Done,
}

impl From<&str> for Xerr {
    fn from(s: &str) -> Self {
        Msg(s.into())
    }
}

impl From<String> for Xerr {
    fn from(s: String) -> Self {
        Msg(s)
    }
}

pub fn restore_screen() {
    if IN_ALT_SCREEN.swap(false, Relaxed) {
        print!("\x1b[?25h\x1b[?1049l");
        _ = stdout().flush();
    }
}

#[cold]
#[inline(never)]
pub fn fatal<E: Display>(e: E) -> ! {
    restore_screen();
    _ = writeln!(stderr(), "{e}");
    unsafe { _exit(1) }
}

#[cold]
#[inline(never)]
pub fn eprint(args: Arguments<'_>) {
    restore_screen();
    _ = writeln!(stderr(), "{args}");
}
