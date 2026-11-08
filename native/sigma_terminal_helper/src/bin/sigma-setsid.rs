//! Portable subset of util-linux `setsid --fork --wait COMMAND [ARG...]`.
//!
//! Hosts without util-linux (macOS) use this to start hook commands in a new
//! session/process group. The parent stays alive as the waiter and exits with
//! the child's status (128 + signal for signalled children).

use std::ffi::CString;
use std::process::exit;

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();

    while matches!(
        args.first().map(String::as_str),
        Some("--fork" | "--wait" | "-f" | "-w")
    ) {
        args.remove(0);
    }

    if args.first().map(String::as_str) == Some("--") {
        args.remove(0);
    }

    if args.is_empty() {
        eprintln!("usage: sigma-setsid --fork --wait COMMAND [ARG...]");
        exit(64);
    }

    let argv: Vec<CString> = match args.iter().map(|a| CString::new(a.as_bytes())).collect() {
        Ok(argv) => argv,
        Err(_) => {
            eprintln!("sigma-setsid: argument contains NUL");
            exit(64);
        }
    };

    let mut pointers: Vec<*const libc::c_char> = argv.iter().map(|a| a.as_ptr()).collect();
    pointers.push(std::ptr::null());

    // SAFETY: fork/setsid/execvp/waitpid are used with valid, NUL-terminated
    // arguments; the child only calls async-signal-safe functions before exec.
    unsafe {
        match libc::fork() {
            -1 => {
                eprintln!(
                    "sigma-setsid: fork failed: {}",
                    std::io::Error::last_os_error()
                );
                exit(1);
            }
            0 => {
                if libc::setsid() == -1 {
                    libc::_exit(1);
                }
                libc::execvp(pointers[0], pointers.as_ptr());
                libc::_exit(127);
            }
            child => {
                let mut status: libc::c_int = 0;
                loop {
                    if libc::waitpid(child, &mut status, 0) == child {
                        break;
                    }
                    if std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                        exit(1);
                    }
                }
                if libc::WIFEXITED(status) {
                    exit(libc::WEXITSTATUS(status));
                }
                if libc::WIFSIGNALED(status) {
                    exit(128 + libc::WTERMSIG(status));
                }
                exit(1);
            }
        }
    }
}
