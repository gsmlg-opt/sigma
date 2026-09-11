use anyhow::{bail, Context, Result};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use portable_pty::{CommandBuilder, ExitStatus, NativePtySystem, PtySize, PtySystem};
use serde::Deserialize;
use serde_json::{json, Value};
use sigma_terminal_helper::{cleanup_session, verify_session_leader, wait_for_session_identity};
use std::env;
use std::io::{self, BufRead, Read, Write};
use std::path::PathBuf;
use std::process::Command as ProcessCommand;
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::thread;
use std::time::Duration;

#[derive(Debug)]
struct Options {
    cwd: PathBuf,
    rows: u16,
    cols: u16,
    command: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Command {
    Input { data: String },
    Resize { rows: u16, cols: u16 },
    Checkpoint { request_id: String },
    Close,
}

enum RunEvent {
    Output(Vec<u8>),
    OutputClosed,
    Control(Command),
    ControlClosed,
    ControlError(String),
    ShellExited(io::Result<ExitStatus>),
}

const CHANNEL_CAPACITY: usize = 64;
const MAX_INPUT_BYTES: usize = 16 * 1024;
const MIN_COLS: u16 = 2;
const MAX_COLS: u16 = 500;
const MIN_ROWS: u16 = 1;
const MAX_ROWS: u16 = 300;
const SCROLLBACK_ROWS: usize = 1_000;
const MAX_CHECKPOINT_BYTES: usize = 2 * 1024 * 1024;

#[derive(Clone, Copy)]
enum ScreenTransition {
    EnterAlternate,
    ExitAlternate,
}

struct TerminalState {
    parser: vt100::Parser,
    normal_screen: Option<vt100::Screen>,
    transition_prefix: Vec<u8>,
}

impl TerminalState {
    fn new(rows: u16, cols: u16) -> Self {
        Self {
            parser: vt100::Parser::new(rows, cols, SCROLLBACK_ROWS),
            normal_screen: None,
            transition_prefix: Vec::new(),
        }
    }

    fn process(&mut self, bytes: &[u8]) {
        for (segment, transition) in transition_segments(&mut self.transition_prefix, bytes) {
            let was_alternate = self.parser.screen().alternate_screen();
            let normal_candidate = (!was_alternate).then(|| self.parser.screen().clone());
            self.parser.process(&segment);
            let is_alternate = self.parser.screen().alternate_screen();

            match (transition, was_alternate, is_alternate) {
                (Some(ScreenTransition::EnterAlternate), false, true) => {
                    self.normal_screen = normal_candidate;
                }
                (Some(ScreenTransition::ExitAlternate), true, false) => {
                    self.normal_screen = None;
                }
                _ => {}
            }
        }
    }

    fn resize(&mut self, rows: u16, cols: u16) {
        self.parser.screen_mut().set_size(rows, cols);
        if let Some(normal_screen) = self.normal_screen.as_mut() {
            normal_screen.set_size(rows, cols);
        }
    }

    fn screen(&self) -> &vt100::Screen {
        self.parser.screen()
    }

    fn checkpoint(&self) -> Result<Vec<u8>> {
        let screen = self.screen();
        let pending = self.transition_prefix.as_slice();

        let mut state = if screen.alternate_screen() {
            let active = screen.state_formatted();
            let reserved = active.len() + pending.len() + b"\x1b[?1049h".len();
            if reserved > MAX_CHECKPOINT_BYTES {
                bail!("snapshot_too_large");
            }

            let normal = self
                .normal_screen
                .as_ref()
                .context("alternate screen has no captured normal buffer")?;
            let mut state = serialize_normal_screen(normal, MAX_CHECKPOINT_BYTES - reserved)?;
            state.extend_from_slice(b"\x1b[?1049h");
            state.extend(active);
            state
        } else {
            serialize_normal_screen(screen, MAX_CHECKPOINT_BYTES - pending.len())?
        };

        state.extend_from_slice(pending);
        if state.len() > MAX_CHECKPOINT_BYTES {
            bail!("snapshot_too_large");
        }
        Ok(state)
    }
}

fn transition_segments(
    prefix: &mut Vec<u8>,
    bytes: &[u8],
) -> Vec<(Vec<u8>, Option<ScreenTransition>)> {
    const TRANSITIONS: [(&[u8], ScreenTransition); 6] = [
        (b"\x1b[?47h", ScreenTransition::EnterAlternate),
        (b"\x1b[?1047h", ScreenTransition::EnterAlternate),
        (b"\x1b[?1049h", ScreenTransition::EnterAlternate),
        (b"\x1b[?47l", ScreenTransition::ExitAlternate),
        (b"\x1b[?1047l", ScreenTransition::ExitAlternate),
        (b"\x1b[?1049l", ScreenTransition::ExitAlternate),
    ];

    let mut segments = Vec::new();
    let mut plain = Vec::new();

    for byte in bytes {
        prefix.push(*byte);

        loop {
            if let Some((_, transition)) = TRANSITIONS.iter().find(|(code, _)| *code == prefix) {
                if !plain.is_empty() {
                    segments.push((std::mem::take(&mut plain), None));
                }
                segments.push((std::mem::take(prefix), Some(*transition)));
                break;
            }

            if TRANSITIONS.iter().any(|(code, _)| code.starts_with(prefix)) {
                break;
            }

            plain.push(prefix.remove(0));
            if prefix.is_empty() {
                break;
            }
        }
    }

    if !plain.is_empty() {
        segments.push((plain, None));
    }
    segments
}

fn serialize_normal_screen(screen: &vt100::Screen, maximum: usize) -> Result<Vec<u8>> {
    let state = screen.state_formatted();
    if state.len() > maximum {
        bail!("snapshot_too_large");
    }

    let mut oldest = screen.clone();
    oldest.set_scrollback(usize::MAX);
    let history_len = oldest.scrollback();
    if history_len == 0 {
        return Ok(state);
    }

    let (_, cols) = screen.size();
    let mut history = Vec::with_capacity(history_len);
    for offset in (1..=history_len).rev() {
        oldest.set_scrollback(offset);
        let row = oldest.rows(0, cols).next().unwrap_or_default();
        history.push(safe_row(&row));
    }

    let mut current = screen.clone();
    current.set_scrollback(0);
    let current_rows = current
        .rows(0, cols)
        .map(|row| safe_row(&row))
        .collect::<Vec<_>>();
    let current_bytes = rendered_rows_size(&current_rows);
    if current_bytes + state.len() > maximum {
        bail!("snapshot_too_large");
    }

    let history_budget = maximum - current_bytes - state.len();
    let mut retained = Vec::new();
    let mut retained_bytes = 0;
    for row in history.into_iter().rev() {
        let row_bytes = row.len() + 2;
        if retained_bytes + row_bytes > history_budget {
            break;
        }
        retained_bytes += row_bytes;
        retained.push(row);
    }
    retained.reverse();
    retained.extend(current_rows);

    let mut serialized = render_rows(&retained);
    serialized.extend(state);
    Ok(serialized)
}

fn safe_row(row: &str) -> Vec<u8> {
    row.chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .into_bytes()
}

fn rendered_rows_size(rows: &[Vec<u8>]) -> usize {
    rows.iter().map(Vec::len).sum::<usize>() + rows.len().saturating_sub(1) * 2
}

fn render_rows(rows: &[Vec<u8>]) -> Vec<u8> {
    let mut rendered = Vec::with_capacity(rendered_rows_size(rows));
    for (index, row) in rows.iter().enumerate() {
        if index > 0 {
            rendered.extend_from_slice(b"\r\n");
        }
        rendered.extend_from_slice(row);
    }
    rendered
}

fn main() {
    if env::args().nth(1).as_deref() == Some("--child-bootstrap") {
        child_bootstrap();
    }

    if let Err(error) = run() {
        let event = json!({"event": "fatal", "error": format!("{error:#}")});
        let stdout = io::stdout();
        let mut stdout = stdout.lock();
        let _ = write_event(&mut stdout, &event);
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let options = parse_options()?;
    let pty_system = NativePtySystem::default();
    let pair = pty_system.openpty(pty_size(options.rows, options.cols))?;
    let current_exe = env::current_exe().context("could not locate terminal helper executable")?;
    let mut command = CommandBuilder::new(current_exe);
    command.arg("--child-bootstrap");
    command.arg("--");
    command.args(&options.command);
    command.cwd(options.cwd);
    command.env("TERM", "xterm-256color");
    command.env("COLORTERM", "truecolor");
    let mut writer = pair.master.take_writer()?;
    let mut reader = pair.master.try_clone_reader()?;
    let mut child = pair.slave.spawn_command(command)?;
    drop(pair.slave);

    let pid = child
        .process_id()
        .context("PTY backend did not expose child PID")?;
    let identity = match wait_for_session_identity(pid, Duration::from_secs(1)) {
        Ok(identity) => identity,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error.context("PTY child identity could not be established"));
        }
    };
    verify_session_leader(&identity)?;
    resume_child(&identity)?;
    let master = pair.master;
    let mut terminal_state = TerminalState::new(options.rows, options.cols);
    let mut sequence = 0_u64;
    let stdout = io::stdout();
    let mut stdout = stdout.lock();

    write_event(
        &mut stdout,
        &json!({
            "event": "started",
            "pid": identity.pid,
            "sid": identity.sid,
            "started_at": identity.started_at,
            "rows": options.rows,
            "cols": options.cols
        }),
    )?;

    let (run_tx, run_rx) = mpsc::sync_channel(CHANNEL_CAPACITY);
    let output_tx = run_tx.clone();
    thread::spawn(move || {
        let mut buffer = [0_u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) | Err(_) => {
                    let _ = output_tx.send(RunEvent::OutputClosed);
                    break;
                }
                Ok(count) => {
                    if output_tx
                        .send(RunEvent::Output(buffer[..count].to_vec()))
                        .is_err()
                    {
                        break;
                    }
                }
            }
        }
    });

    spawn_control_reader(run_tx.clone());
    thread::spawn(move || {
        let _ = run_tx.send(RunEvent::ShellExited(child.wait()));
    });

    let run_result = run_loop(
        run_rx,
        &mut stdout,
        &mut writer,
        master.as_ref(),
        &mut terminal_state,
        &mut sequence,
    );

    drop(writer);
    let cleanup = cleanup_session(&identity, Duration::from_secs(5));
    let cleanup_result = write_event(&mut stdout, &json!({"event": "cleanup", "result": cleanup}));
    run_result.and(cleanup_result)
}

#[cfg(unix)]
fn child_bootstrap() -> ! {
    use std::os::unix::process::CommandExt;

    let command = env::args().skip(3).collect::<Vec<_>>();
    if command.is_empty() {
        eprintln!("child bootstrap received no command");
        std::process::exit(127);
    }

    unsafe {
        libc::raise(libc::SIGSTOP);
    }

    let error = ProcessCommand::new(&command[0]).args(&command[1..]).exec();
    eprintln!("failed to exec terminal command: {error}");
    std::process::exit(127);
}

#[cfg(not(unix))]
fn child_bootstrap() -> ! {
    eprintln!("terminal child bootstrap is unsupported on this platform");
    std::process::exit(127);
}

fn resume_child(identity: &sigma_terminal_helper::ProcessIdentity) -> Result<()> {
    let current = sigma_terminal_helper::process_identity(identity.pid)?;
    if current.sid != identity.sid || current.started_at != identity.started_at {
        bail!("PTY child identity changed before startup acknowledgement");
    }
    if unsafe { libc::kill(identity.pid as libc::pid_t, libc::SIGCONT) } == -1 {
        return Err(io::Error::last_os_error()).context("failed to resume PTY child");
    }
    Ok(())
}

fn spawn_control_reader(tx: SyncSender<RunEvent>) {
    thread::spawn(move || {
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            let event = match line {
                Ok(line) => match serde_json::from_str(&line) {
                    Ok(command) => RunEvent::Control(command),
                    Err(error) => RunEvent::ControlError(format!("invalid control frame: {error}")),
                },
                Err(error) => {
                    RunEvent::ControlError(format!("failed to read control channel: {error}"))
                }
            };

            if tx.send(event).is_err() {
                return;
            }
        }
        let _ = tx.send(RunEvent::ControlClosed);
    });
}

fn run_loop(
    rx: Receiver<RunEvent>,
    stdout: &mut impl Write,
    writer: &mut impl Write,
    master: &dyn portable_pty::MasterPty,
    terminal_state: &mut TerminalState,
    sequence: &mut u64,
) -> Result<()> {
    while let Ok(event) = rx.recv() {
        match event {
            RunEvent::Output(bytes) => {
                terminal_state.process(&bytes);
                *sequence += 1;
                write_event(
                    stdout,
                    &json!({"event": "output", "seq": *sequence, "data": BASE64.encode(bytes)}),
                )?;
            }
            RunEvent::OutputClosed => {}
            RunEvent::Control(Command::Input { data }) => {
                let bytes = BASE64.decode(data)?;
                if bytes.len() > MAX_INPUT_BYTES {
                    bail!("input frame exceeds {MAX_INPUT_BYTES} bytes");
                }
                writer.write_all(&bytes)?;
                writer.flush()?;
            }
            RunEvent::Control(Command::Resize { rows, cols }) => {
                validate_size(rows, cols)?;
                master.resize(pty_size(rows, cols))?;
                terminal_state.resize(rows, cols);
                write_event(
                    stdout,
                    &json!({"event": "resized", "rows": rows, "cols": cols}),
                )?;
            }
            RunEvent::Control(Command::Checkpoint { request_id }) => {
                let screen = terminal_state.screen();
                let (rows, cols) = screen.size();
                match terminal_state.checkpoint() {
                    Ok(state) => write_event(
                        stdout,
                        &json!({
                            "event": "checkpoint",
                            "request_id": request_id,
                            "seq": *sequence,
                            "rows": rows,
                            "cols": cols,
                            "data": BASE64.encode(state)
                        }),
                    )?,
                    Err(error) => {
                        let error = if error.to_string() == "snapshot_too_large" {
                            "snapshot_too_large"
                        } else {
                            "snapshot_unavailable"
                        };
                        write_event(
                            stdout,
                            &json!({
                                "event": "checkpoint_failed",
                                "request_id": request_id,
                                "error": error,
                                "maximum_bytes": MAX_CHECKPOINT_BYTES
                            }),
                        )?
                    }
                }
            }
            RunEvent::Control(Command::Close) | RunEvent::ControlClosed => break,
            RunEvent::ControlError(error) => bail!(error),
            RunEvent::ShellExited(status) => {
                let status = status.context("failed waiting for PTY child")?;
                write_event(
                    stdout,
                    &json!({
                        "event": "shell_exit",
                        "status": status.exit_code(),
                        "signal": status.signal()
                    }),
                )?;
                break;
            }
        }
    }
    Ok(())
}

fn write_event(writer: &mut impl Write, event: &Value) -> Result<()> {
    serde_json::to_writer(&mut *writer, event)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}

fn pty_size(rows: u16, cols: u16) -> PtySize {
    PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    }
}

fn validate_size(rows: u16, cols: u16) -> Result<()> {
    if !(MIN_ROWS..=MAX_ROWS).contains(&rows) || !(MIN_COLS..=MAX_COLS).contains(&cols) {
        bail!(
            "PTY dimensions must be {MIN_COLS}..{MAX_COLS} columns and {MIN_ROWS}..{MAX_ROWS} rows"
        );
    }
    Ok(())
}

fn parse_options() -> Result<Options> {
    let mut args = env::args().skip(1);
    let mut cwd = env::current_dir()?;
    let mut rows = 24;
    let mut cols = 80;
    let mut command = Vec::new();

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--cwd" => cwd = PathBuf::from(args.next().context("--cwd requires a value")?),
            "--rows" => rows = args.next().context("--rows requires a value")?.parse()?,
            "--cols" => cols = args.next().context("--cols requires a value")?.parse()?,
            "--" => {
                command.extend(args);
                break;
            }
            _ => bail!("unknown option: {arg}"),
        }
    }

    validate_size(rows, cols)?;
    if command.is_empty() {
        let shell = env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        command = vec![shell, "-i".to_string()];
    }
    Ok(Options {
        cwd,
        rows,
        cols,
        command,
    })
}
