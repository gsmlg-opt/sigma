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
use std::time::{Duration, Instant};

#[derive(Debug)]
struct Options {
    cwd: PathBuf,
    rows: u16,
    cols: u16,
    command: Vec<String>,
    terminal_state: bool,
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
const SHUTDOWN_BUDGET: Duration = Duration::from_secs(5);

#[derive(Clone, Copy)]
enum ScreenTransition {
    EnterAlternate,
    ExitAlternate,
}

#[derive(Default)]
struct DeviceResponses {
    enabled: bool,
    pending: Vec<Vec<u8>>,
}

impl vt100::Callbacks for DeviceResponses {
    fn unhandled_csi(
        &mut self,
        screen: &mut vt100::Screen,
        first: Option<u8>,
        second: Option<u8>,
        params: &[&[u16]],
        command: char,
    ) {
        if !self.enabled || second.is_some() || params.len() != 1 {
            return;
        }
        match (first, command, params[0]) {
            (None, 'n', [5]) => self.pending.push(b"\x1b[0n".to_vec()),
            (None | Some(b'?'), 'n', [6]) => {
                let (row, col) = screen.cursor_position();
                let prefix = if first == Some(b'?') { "?" } else { "" };
                self.pending
                    .push(format!("\x1b[{prefix}{};{}R", row + 1, col + 1).into_bytes());
            }
            (None, 'c', [0]) => self.pending.push(b"\x1b[?1;2c".to_vec()),
            (Some(b'>'), 'c', [0]) => self.pending.push(b"\x1b[>0;276;0c".to_vec()),
            _ => {}
        }
    }
}

#[derive(Clone, Copy, Default)]
enum PendingState {
    #[default]
    Ground,
    Utf8(u8),
    Escape,
    EscapeIntermediate,
    Csi,
    Osc,
    String,
}

impl PendingState {
    fn advance(self, byte: u8) -> Self {
        use PendingState::*;
        if matches!(byte, 0x18 | 0x1a) {
            return Ground;
        }
        match self {
            Ground => match byte {
                0x1b => Escape,
                0xc2..=0xdf => Utf8(1),
                0xe0..=0xef => Utf8(2),
                0xf0..=0xf4 => Utf8(3),
                _ => Ground,
            },
            Utf8(remaining) if (0x80..=0xbf).contains(&byte) => {
                if remaining == 1 {
                    Ground
                } else {
                    Utf8(remaining - 1)
                }
            }
            Utf8(_) => Ground.advance(byte),
            Osc => match byte {
                0x07 => Ground,
                0x1b => Escape,
                _ => Osc,
            },
            String => {
                if byte == 0x1b {
                    Escape
                } else {
                    String
                }
            }
            _ if byte == 0x1b => Escape,
            Escape => match byte {
                b'[' => Csi,
                b']' => Osc,
                b'P' | b'X' | b'^' | b'_' => String,
                0x20..=0x2f => EscapeIntermediate,
                0x30..=0x7e => Ground,
                _ => Escape,
            },
            EscapeIntermediate => {
                if (0x30..=0x7e).contains(&byte) {
                    Ground
                } else {
                    EscapeIntermediate
                }
            }
            Csi => {
                if (0x40..=0x7e).contains(&byte) {
                    Ground
                } else {
                    Csi
                }
            }
        }
    }
}

struct TerminalState {
    parser: vt100::Parser<DeviceResponses>,
    normal_screen: Option<vt100::Screen>,
    pending: Vec<u8>,
    pending_state: PendingState,
    pending_overflow: bool,
}

impl TerminalState {
    fn new(rows: u16, cols: u16) -> Self {
        Self {
            parser: vt100::Parser::new_with_callbacks(
                rows,
                cols,
                SCROLLBACK_ROWS,
                DeviceResponses::default(),
            ),
            normal_screen: None,
            pending: Vec::new(),
            pending_state: PendingState::Ground,
            pending_overflow: false,
        }
    }

    fn process(&mut self, bytes: &[u8]) {
        let mut plain = Vec::new();
        for &byte in bytes {
            self.pending_state = self.pending_state.advance(byte);
            self.pending.push(byte);
            let complete = matches!(self.pending_state, PendingState::Ground);
            if self.pending.len() > MAX_CHECKPOINT_BYTES {
                self.pending_overflow = true;
            }
            if complete || self.pending_overflow {
                let transition = match self.pending.as_slice() {
                    b"\x1b[?47h" | b"\x1b[?1047h" | b"\x1b[?1049h" => {
                        Some(ScreenTransition::EnterAlternate)
                    }
                    b"\x1b[?47l" | b"\x1b[?1047l" | b"\x1b[?1049l" => {
                        Some(ScreenTransition::ExitAlternate)
                    }
                    _ => None,
                };
                if let Some(transition) = transition {
                    self.parser.process(&plain);
                    plain.clear();
                    let was_alternate = self.parser.screen().alternate_screen();
                    let normal_candidate = (!was_alternate).then(|| self.parser.screen().clone());
                    self.parser.process(&self.pending);
                    match (
                        transition,
                        was_alternate,
                        self.parser.screen().alternate_screen(),
                    ) {
                        (ScreenTransition::EnterAlternate, false, true) => {
                            self.normal_screen = normal_candidate
                        }
                        (ScreenTransition::ExitAlternate, true, false) => self.normal_screen = None,
                        _ => {}
                    }
                } else {
                    plain.extend_from_slice(&self.pending);
                }
                self.pending.clear();
                if complete {
                    self.pending_overflow = false;
                }
            }
        }
        self.parser.process(&plain);
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
        if self.pending_overflow {
            bail!("snapshot_too_large");
        }
        let pending = self.pending.as_slice();

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
    terminal_state.parser.callbacks_mut().enabled = options.terminal_state;
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

    let mut output_closed = false;
    let run_result = run_loop(
        &run_rx,
        &mut stdout,
        &mut writer,
        master.as_ref(),
        &mut terminal_state,
        &mut sequence,
        &mut output_closed,
    );

    let shutdown_deadline = Instant::now() + SHUTDOWN_BUDGET;
    let cleanup = cleanup_session(&identity, SHUTDOWN_BUDGET);
    let drain_result = match &run_result {
        Ok(Some(status)) => {
            // Cleanup closes any remaining slave holders before waiting for EOF.
            let drained = drain_output(
                &run_rx,
                &mut stdout,
                &mut terminal_state,
                &mut sequence,
                output_closed,
                shutdown_deadline,
            );
            let final_snapshot = if options.terminal_state && drained.is_ok() {
                write_checkpoint(&mut stdout, &terminal_state, sequence, "final")
            } else {
                Ok(())
            };
            let exited = write_event(
                &mut stdout,
                &json!({
                    "event": "shell_exit",
                    "status": status.exit_code(),
                    "signal": status.signal()
                }),
            );
            drained.and(final_snapshot).and(exited)
        }
        _ => Ok(()),
    };
    // portable-pty's writer sends a newline and EOF on drop. Keep it until the
    // slave holders have closed and output has drained, so echoed input cannot
    // become synthetic command output during shutdown.
    drop(writer);
    let cleanup_result = write_event(&mut stdout, &json!({"event": "cleanup", "result": cleanup}));
    run_result.map(|_| ()).and(drain_result).and(cleanup_result)
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
    rx: &Receiver<RunEvent>,
    stdout: &mut impl Write,
    writer: &mut impl Write,
    master: &dyn portable_pty::MasterPty,
    terminal_state: &mut TerminalState,
    sequence: &mut u64,
    output_closed: &mut bool,
) -> Result<Option<ExitStatus>> {
    while let Ok(event) = rx.recv() {
        match event {
            RunEvent::Output(bytes) => {
                write_output(stdout, terminal_state, sequence, &bytes)?;
                for response in std::mem::take(&mut terminal_state.parser.callbacks_mut().pending) {
                    writer.write_all(&response)?;
                }
                writer.flush()?;
            }
            RunEvent::OutputClosed => *output_closed = true,
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
                write_checkpoint(stdout, terminal_state, *sequence, &request_id)?;
            }
            RunEvent::Control(Command::Close) | RunEvent::ControlClosed => break,
            RunEvent::ControlError(error) => bail!(error),
            RunEvent::ShellExited(status) => {
                let status = status.context("failed waiting for PTY child")?;
                return Ok(Some(status));
            }
        }
    }
    Ok(None)
}

fn drain_output(
    rx: &Receiver<RunEvent>,
    stdout: &mut impl Write,
    terminal_state: &mut TerminalState,
    sequence: &mut u64,
    mut output_closed: bool,
    deadline: Instant,
) -> Result<()> {
    while !output_closed {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .context("timed out draining PTY output after child exit")?;
        match rx
            .recv_timeout(remaining)
            .context("PTY output did not close after child exit")?
        {
            RunEvent::Output(bytes) => write_output(stdout, terminal_state, sequence, &bytes)?,
            RunEvent::OutputClosed => output_closed = true,
            _ => {}
        }
    }
    Ok(())
}

fn write_output(
    stdout: &mut impl Write,
    terminal_state: &mut TerminalState,
    sequence: &mut u64,
    bytes: &[u8],
) -> Result<()> {
    terminal_state.process(bytes);
    *sequence += 1;
    write_event(
        stdout,
        &json!({"event": "output", "seq": *sequence, "data": BASE64.encode(bytes)}),
    )
}

fn write_checkpoint(
    stdout: &mut impl Write,
    terminal_state: &TerminalState,
    sequence: u64,
    request_id: &str,
) -> Result<()> {
    let (rows, cols) = terminal_state.screen().size();
    match terminal_state.checkpoint() {
        Ok(state) => write_event(
            stdout,
            &json!({
                "event": "checkpoint", "request_id": request_id, "seq": sequence,
                "rows": rows, "cols": cols, "data": BASE64.encode(state)
            }),
        ),
        Err(error) => write_event(
            stdout,
            &json!({
                "event": "checkpoint_failed", "request_id": request_id,
                "error": if error.to_string() == "snapshot_too_large" { "snapshot_too_large" } else { "snapshot_unavailable" },
                "maximum_bytes": MAX_CHECKPOINT_BYTES
            }),
        ),
    }
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
    let mut terminal_state = false;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--terminal-state" => terminal_state = true,
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
        terminal_state,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checkpoint_restores_every_partial_parser_boundary() {
        let cases: &[&[u8]] = &[
            "BEFORE€AFTER".as_bytes(),
            b"BEFORE\x1b[31mRED\x1b[0mAFTER",
            b"BEFORE\x1b]2;window title\x07AFTER",
            b"BEFORE\x1b]2;window title\x1b\\AFTER",
            b"BEFORE\x1b]2;title\x1b[31mRED",
            b"BEFORE\x1bPignored\x1b\\AFTER",
            b"BEFORE\x1b[31\r\nmRED",
            b"BEFORE\x1b[?1049hALT\x1b[?1049lAFTER",
            b"BEFORE\xe2INVALID\x1b[31mRED",
        ];
        for &bytes in cases {
            for split in 0..=bytes.len() {
                let mut original = TerminalState::new(6, 40);
                original.process(&bytes[..split]);
                let snapshot = original.checkpoint().unwrap();
                original.process(&bytes[split..]);
                let mut continuous = vt100::Parser::new(6, 40, SCROLLBACK_ROWS);
                continuous.process(bytes);
                assert_eq!(original.screen().contents(), continuous.screen().contents());
                assert_eq!(
                    original.screen().cursor_position(),
                    continuous.screen().cursor_position()
                );
                let mut restored = vt100::Parser::new(6, 40, SCROLLBACK_ROWS);
                restored.process(&snapshot);
                restored.process(&bytes[split..]);
                assert_eq!(
                    restored.screen().contents(),
                    original.screen().contents(),
                    "split={split} bytes={bytes:?}"
                );
                assert_eq!(
                    restored.screen().cursor_position(),
                    original.screen().cursor_position()
                );
                assert_eq!(restored.screen().fgcolor(), original.screen().fgcolor());
                assert_eq!(
                    restored.screen().alternate_screen(),
                    original.screen().alternate_screen()
                );
            }
        }
    }

    #[test]
    fn checkpoint_survives_wrapping_in_a_single_row() {
        let mut terminal = TerminalState::new(3, 10);
        terminal.resize(1, 10);
        terminal.process(b"0123456789wrapped");

        let checkpoint = terminal.checkpoint().unwrap();
        let mut restored = vt100::Parser::new(1, 10, SCROLLBACK_ROWS);
        restored.process(&checkpoint);
        assert_eq!(terminal.screen().contents(), "wrapped");
        assert_eq!(restored.screen().contents(), "wrapped");
        assert_eq!(
            restored.screen().cursor_position(),
            terminal.screen().cursor_position()
        );
    }

    #[test]
    fn checkpoint_keeps_partial_sequences_across_resize() {
        let mut original = TerminalState::new(6, 40);
        original.process(b"BEFORE\x1b[31");
        original.resize(8, 50);
        let snapshot = original.checkpoint().unwrap();
        original.process(b"mRED");
        let mut restored = vt100::Parser::new(8, 50, SCROLLBACK_ROWS);
        restored.process(&snapshot);
        restored.process(b"mRED");
        assert_eq!(restored.screen().contents(), original.screen().contents());
        assert_eq!(restored.screen().fgcolor(), original.screen().fgcolor());
        assert_eq!(restored.screen().size(), original.screen().size());
    }

    #[test]
    fn checkpoint_bounds_unfinished_control_strings_and_recovers_after_termination() {
        let mut terminal = TerminalState::new(6, 40);
        terminal.process(b"\x1b]2;");
        terminal.process(&vec![b'x'; MAX_CHECKPOINT_BYTES]);
        assert!(terminal.pending.len() <= MAX_CHECKPOINT_BYTES);
        assert_eq!(
            terminal.checkpoint().unwrap_err().to_string(),
            "snapshot_too_large"
        );
        terminal.process(b"\x07AFTER");
        assert!(terminal.checkpoint().is_ok());
        assert!(terminal.screen().contents().contains("AFTER"));
    }

    #[test]
    fn terminal_queries_use_server_cursor_and_are_generated_once() {
        let mut terminal = TerminalState::new(6, 40);
        terminal.parser.callbacks_mut().enabled = true;
        terminal.process(b"\x1b[3;7H\x1b[5n\x1b[6n\x1b[c\x1b[?6n\x1b[>c");
        assert_eq!(
            terminal.parser.callbacks().pending,
            vec![
                b"\x1b[0n".to_vec(),
                b"\x1b[3;7R".to_vec(),
                b"\x1b[?1;2c".to_vec(),
                b"\x1b[?3;7R".to_vec(),
                b"\x1b[>0;276;0c".to_vec()
            ]
        );
        terminal.checkpoint().unwrap();
        assert_eq!(terminal.parser.callbacks().pending.len(), 5);
        terminal.process(&vec![b'X'; 40]);
        let (row, col) = terminal.screen().cursor_position();
        terminal.process(b"\x1b[6n");
        assert_eq!(
            terminal.parser.callbacks().pending.last().unwrap(),
            format!("\x1b[{};{}R", row + 1, col + 1).as_bytes()
        );
    }
}
