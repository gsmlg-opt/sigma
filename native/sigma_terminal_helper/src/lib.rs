use anyhow::{bail, Context, Result};
use libc::{SIGHUP, SIGKILL, SIGTERM};
use serde::Serialize;
use std::io;
use std::thread;
use std::time::{Duration, Instant};
use sysinfo::{Pid, ProcessRefreshKind, RefreshKind, System};

#[derive(Clone, Debug, Serialize)]
pub struct ProcessIdentity {
    pub pid: u32,
    pub sid: u32,
    pub started_at: u64,
}

#[derive(Debug, Serialize)]
pub struct CleanupResult {
    pub complete: bool,
    pub elapsed_ms: u128,
    pub remaining: Vec<ProcessIdentity>,
    pub identity_conflict: bool,
}

pub fn process_identity(pid: u32) -> Result<ProcessIdentity> {
    let system = process_system();
    identity_from(&system, pid)
}

pub fn wait_for_session_identity(pid: u32, budget: Duration) -> Result<ProcessIdentity> {
    let started = Instant::now();
    loop {
        let mut status = 0;
        let waited = unsafe {
            libc::waitpid(
                pid as libc::pid_t,
                &mut status,
                libc::WUNTRACED | libc::WNOHANG,
            )
        };

        if waited == pid as libc::pid_t {
            if libc::WIFSTOPPED(status) {
                return process_identity(pid);
            }
            bail!("PTY child exited before startup handshake");
        }

        if waited == -1 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error).context("failed waiting for PTY child startup handshake");
            }
        }

        if started.elapsed() >= budget {
            bail!("PTY child did not stop for startup handshake");
        }
        thread::sleep(Duration::from_millis(5));
    }
}

pub fn session_members(identity: &ProcessIdentity) -> Vec<ProcessIdentity> {
    let system = process_system();
    members_from(&system, identity.sid)
}

pub fn cleanup_session(identity: &ProcessIdentity, budget: Duration) -> CleanupResult {
    let started = Instant::now();
    let graceful_deadline = started + budget.mul_f32(0.6);
    let mut identity_conflict = false;
    identity_conflict |= signal_session(identity, SIGHUP);
    identity_conflict |= signal_session(identity, SIGTERM);

    while started.elapsed() < budget {
        let (remaining, conflict) = verified_session_members(identity);
        identity_conflict |= conflict;
        if remaining.is_empty() {
            return CleanupResult {
                complete: !identity_conflict,
                elapsed_ms: started.elapsed().as_millis(),
                remaining,
                identity_conflict,
            };
        }

        if Instant::now() >= graceful_deadline && !conflict {
            signal_members(&remaining, SIGKILL);
        }
        thread::sleep(Duration::from_millis(20));
    }

    let (remaining, conflict) = verified_session_members(identity);
    identity_conflict |= conflict;
    CleanupResult {
        complete: remaining.is_empty() && !identity_conflict,
        elapsed_ms: started.elapsed().as_millis(),
        remaining,
        identity_conflict,
    }
}

pub fn verify_session_leader(identity: &ProcessIdentity) -> Result<()> {
    if identity.pid != identity.sid {
        bail!(
            "PTY child {} is not its session leader (sid {})",
            identity.pid,
            identity.sid
        );
    }
    Ok(())
}

fn process_system() -> System {
    System::new_with_specifics(RefreshKind::nothing().with_processes(process_refresh_kind()))
}

fn process_refresh_kind() -> ProcessRefreshKind {
    ProcessRefreshKind::nothing().without_tasks()
}

fn members_from(system: &System, sid: u32) -> Vec<ProcessIdentity> {
    system
        .processes()
        .values()
        .filter_map(|process| {
            let process_sid = process.session_id()?.as_u32();
            (process_sid == sid).then(|| ProcessIdentity {
                pid: process.pid().as_u32(),
                sid: process_sid,
                started_at: process.start_time(),
            })
        })
        .collect()
}

fn identity_from(system: &System, pid: u32) -> Result<ProcessIdentity> {
    let process = system
        .process(Pid::from_u32(pid))
        .with_context(|| format!("process {pid} disappeared before identity was recorded"))?;
    let sid = process
        .session_id()
        .context("platform did not report a session id")?
        .as_u32();

    Ok(ProcessIdentity {
        pid,
        sid,
        started_at: process.start_time(),
    })
}

fn verified_session_members(identity: &ProcessIdentity) -> (Vec<ProcessIdentity>, bool) {
    let members = session_members(identity);
    let leader_conflict = members
        .iter()
        .any(|member| member.pid == identity.pid && member.started_at != identity.started_at);

    (members, leader_conflict)
}

fn signal_session(identity: &ProcessIdentity, signal: libc::c_int) -> bool {
    let (members, conflict) = verified_session_members(identity);
    if conflict {
        true
    } else {
        signal_members(&members, signal);
        false
    }
}

fn signal_members(members: &[ProcessIdentity], signal: libc::c_int) {
    for member in members {
        // The snapshot verifies start time, and getsid narrows the remaining
        // scan-to-signal race without another expensive process-table scan.
        let current_sid = unsafe { libc::getsid(member.pid as libc::pid_t) };
        if current_sid == member.sid as libc::pid_t {
            unsafe {
                libc::kill(member.pid as libc::pid_t, signal);
            }
        }
    }
}
