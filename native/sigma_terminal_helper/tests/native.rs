use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};
use wait_timeout::ChildExt;

struct Helper {
    child: Child,
    input: Option<ChildStdin>,
    output: BufReader<ChildStdout>,
}

impl Helper {
    fn start(script: &str, rows: u16, cols: u16) -> Self {
        Self::start_with_args(&[
            "--rows",
            &rows.to_string(),
            "--cols",
            &cols.to_string(),
            "--",
            "/bin/sh",
            "-c",
            script,
        ])
    }

    fn start_default(rows: u16, cols: u16) -> Self {
        Self::start_with_args(&["--rows", &rows.to_string(), "--cols", &cols.to_string()])
    }

    fn start_with_args(args: &[&str]) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_sigma-terminal-helper"))
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        Self {
            child,
            input: Some(input),
            output,
        }
    }

    fn send(&mut self, value: Value) {
        let input = self.input.as_mut().unwrap();
        serde_json::to_writer(&mut *input, &value).unwrap();
        input.write_all(b"\n").unwrap();
        input.flush().unwrap();
    }

    fn event(&mut self, name: &str) -> Value {
        let started = Instant::now();
        loop {
            assert!(
                started.elapsed() < Duration::from_secs(5),
                "timed out waiting for {name}"
            );
            let mut line = String::new();
            self.output.read_line(&mut line).unwrap();
            assert!(!line.is_empty(), "helper closed before {name}");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["event"] == name {
                return value;
            }
        }
    }

    fn output_until(&mut self, expected: &str) -> String {
        let mut output = Vec::new();
        loop {
            let event = self.event("output");
            output.extend(BASE64.decode(event["data"].as_str().unwrap()).unwrap());
            let text = String::from_utf8_lossy(&output).into_owned();
            if text.contains(expected) {
                return text;
            }
        }
    }

    fn output_until_with_seq(&mut self, expected: &str) -> (String, u64) {
        let mut output = Vec::new();
        loop {
            let event = self.event("output");
            output.extend(BASE64.decode(event["data"].as_str().unwrap()).unwrap());
            let text = String::from_utf8_lossy(&output).into_owned();
            if text.contains(expected) {
                return (text, event["seq"].as_u64().unwrap());
            }
        }
    }

    fn close_input(&mut self) {
        self.input.take();
    }
}

fn checkpoint_bytes(helper: &mut Helper, request_id: &str) -> Vec<u8> {
    helper.send(json!({"op": "checkpoint", "request_id": request_id}));
    let checkpoint = helper.event("checkpoint");
    BASE64.decode(checkpoint["data"].as_str().unwrap()).unwrap()
}

fn scrollback_contains(parser: &mut vt100::Parser, expected: &str) -> bool {
    parser.screen_mut().set_scrollback(usize::MAX);
    let history_len = parser.screen().scrollback();
    (1..=history_len).any(|offset| {
        parser.screen_mut().set_scrollback(offset);
        parser.screen().contents().contains(expected)
    })
}

#[test]
fn launches_the_default_interactive_shell_and_accepts_input() {
    let mut helper = Helper::start_default(24, 120);
    helper.event("started");
    helper.send(json!({
        "op": "input",
        "data": BASE64.encode(b"printf 'DEFAULT-SHELL\\n'\nexit\n")
    }));
    assert!(helper
        .output_until("DEFAULT-SHELL")
        .contains("DEFAULT-SHELL"));
    helper.event("shell_exit");
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
}

#[test]
fn natural_shell_exit_reports_status_and_reaps_remaining_members() {
    let mut helper = Helper::start(
        "(trap '' HUP TERM; while :; do sleep 1; done) & exit 7",
        24,
        80,
    );
    let started = helper.event("started");
    let sid = started["sid"].as_u64().unwrap() as i32;
    let exited = helper.event("shell_exit");
    assert_eq!(exited["status"], 7);
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
    assert!(helper
        .child
        .wait_timeout(Duration::from_secs(1))
        .unwrap()
        .is_some());
    assert_eq!(unsafe { libc::getsid(sid) }, -1);
}

#[test]
fn cleanup_reaps_a_foreground_pipeline() {
    let mut helper = Helper::start("sleep 30 | cat", 24, 80);
    helper.event("started");
    helper.send(json!({"op": "close"}));
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
}

#[test]
fn fragmented_utf8_and_csi_are_included_at_the_checkpoint_watermark() {
    let mut helper = Helper::start(
        "printf '\\342'; sleep .05; printf '\\202\\254\\033['; sleep .05; printf '31mRED'; sleep 30",
        24,
        80,
    );
    helper.event("started");
    let (_output, last_seq) = helper.output_until_with_seq("RED");
    helper.send(json!({"op": "checkpoint", "request_id": "fragmented"}));
    let checkpoint = helper.event("checkpoint");
    assert_eq!(checkpoint["seq"].as_u64(), Some(last_seq));
    let bytes = BASE64.decode(checkpoint["data"].as_str().unwrap()).unwrap();
    let mut restored = vt100::Parser::new(24, 80, 0);
    restored.process(&bytes);
    assert!(restored.screen().contents().contains("€RED"));
    helper.send(json!({"op": "close"}));
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
}

#[test]
fn full_screen_program_observes_live_resize() {
    let mut helper = Helper::start(
        "tput smcup; echo TUI-READY; trap 'stty size' WINCH; while :; do sleep 1; done",
        24,
        80,
    );
    helper.event("started");
    helper.output_until("TUI-READY");
    helper.send(json!({"op": "resize", "rows": 30, "cols": 100}));
    helper.event("resized");
    assert!(helper.output_until("30 100").contains("30 100"));
    helper.send(json!({"op": "close"}));
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
}

#[test]
fn preserves_non_utf8_pty_bytes_and_records_session_identity() {
    let mut helper = Helper::start(
        "stty raw -echo; printf '\\377\\000A\\033[31m'; sleep 30",
        24,
        80,
    );
    let started = helper.event("started");
    assert_eq!(started["pid"], started["sid"]);
    let output = helper.event("output");
    let bytes = BASE64.decode(output["data"].as_str().unwrap()).unwrap();
    assert!(bytes
        .windows(7)
        .any(|bytes| bytes == [0xff, 0, b'A', 0x1b, b'[', b'3', b'1']));
    helper.send(json!({"op": "close"}));
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
    assert!(helper
        .child
        .wait_timeout(Duration::from_secs(1))
        .unwrap()
        .is_some());
}

#[test]
fn kernel_resize_is_observed_through_stty() {
    let mut helper = Helper::start(
        "trap 'stty size' WINCH; echo READY; while :; do sleep 1; done",
        24,
        80,
    );
    helper.event("started");
    helper.event("output");
    helper.send(json!({"op": "resize", "rows": 41, "cols": 132}));
    let resized = helper.event("resized");
    assert_eq!(
        (resized["rows"].as_u64(), resized["cols"].as_u64()),
        (Some(41), Some(132))
    );
    let output = helper.event("output");
    let bytes = BASE64.decode(output["data"].as_str().unwrap()).unwrap();
    assert!(String::from_utf8_lossy(&bytes).contains("41 132"));
    helper.send(json!({"op": "close"}));
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
}

#[test]
fn checkpoint_restores_alternate_screen_while_control_is_detached() {
    let script = "printf '\\033[?1049h\\033[?2004h\\033[?1h\\033[2JALT-SCREEN'; sleep 30";
    let mut helper = Helper::start(script, 24, 80);
    helper.event("started");
    helper.event("output");
    helper.send(json!({"op": "checkpoint", "request_id": "detached-1"}));
    let checkpoint = helper.event("checkpoint");
    let bytes = BASE64.decode(checkpoint["data"].as_str().unwrap()).unwrap();
    let mut restored = vt100::Parser::new(24, 80, 0);
    restored.process(&bytes);
    assert!(restored.screen().contents().contains("ALT-SCREEN"));
    assert!(restored.screen().alternate_screen());
    assert!(restored.screen().bracketed_paste());
    assert!(restored.screen().application_cursor());
    helper.send(json!({"op": "close"}));
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
}

#[test]
fn checkpoint_restores_bounded_normal_scrollback_and_current_state() {
    let script =
        "i=1; while [ $i -le 30 ]; do printf 'LINE-%03d\\n' $i; i=$((i+1)); done; printf '\\033[?2004h\\033[?1hCURRENT\\033[31m\\033[3;7HXY'; sleep 30";
    let mut helper = Helper::start(script, 6, 40);
    helper.event("started");
    helper.output_until("CURRENT");

    let bytes = checkpoint_bytes(&mut helper, "normal-history");
    assert!(bytes.len() <= 2 * 1024 * 1024);
    let mut restored = vt100::Parser::new(6, 40, 1_000);
    restored.process(&bytes);

    assert!(restored.screen().contents().contains("CURRENT"));
    assert!(restored.screen().bracketed_paste());
    assert!(restored.screen().application_cursor());
    assert_eq!(restored.screen().cursor_position(), (2, 8));
    assert_eq!(restored.screen().fgcolor(), vt100::Color::Idx(1));
    assert!(scrollback_contains(&mut restored, "LINE-010"));

    helper.send(json!({"op": "close"}));
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
}

#[test]
fn alternate_checkpoint_restores_inactive_normal_screen_and_history() {
    let script = "i=1; while [ $i -le 16 ]; do printf 'NORMAL-%03d\\n' $i; i=$((i+1)); done; printf 'NORMAL-CURRENT\\033[?1049hALT-CONTENT'; sleep 30";
    let mut helper = Helper::start(script, 6, 40);
    helper.event("started");
    helper.output_until("ALT-CONTENT");
    helper.send(json!({"op": "resize", "rows": 8, "cols": 50}));
    helper.event("resized");

    let bytes = checkpoint_bytes(&mut helper, "dual-buffer");
    let mut restored = vt100::Parser::new(8, 50, 1_000);
    restored.process(&bytes);
    assert!(restored.screen().alternate_screen());
    assert!(restored.screen().contents().contains("ALT-CONTENT"));

    restored.process(b"\x1b[?1049l");
    assert!(!restored.screen().alternate_screen());
    assert!(restored.screen().contents().contains("NORMAL-CURRENT"));
    assert!(scrollback_contains(&mut restored, "NORMAL-004"));

    helper.send(json!({"op": "close"}));
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
}

#[test]
fn fragmented_alternate_entry_preserves_the_normal_buffer() {
    let script = "printf 'NORMAL-BEFORE\\033[?10'; sleep .05; printf '49hALT-AFTER'; sleep 30";
    let mut helper = Helper::start(script, 6, 40);
    helper.event("started");
    helper.output_until("ALT-AFTER");

    let bytes = checkpoint_bytes(&mut helper, "fragmented-alt");
    let mut restored = vt100::Parser::new(6, 40, 1_000);
    restored.process(&bytes);
    assert!(restored.screen().alternate_screen());
    assert!(restored.screen().contents().contains("ALT-AFTER"));
    restored.process(b"\x1b[?1049l");
    assert!(restored.screen().contents().contains("NORMAL-BEFORE"));

    helper.send(json!({"op": "close"}));
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
}

#[test]
fn oversized_formatted_screen_returns_a_bounded_checkpoint_failure() {
    let script = r#"awk 'BEGIN { for (i=0; i<75000; i++) printf "\033[38;2;255;0;0mX\033[38;2;0;255;0mY"; printf "DONE" }'; sleep 30"#;
    let mut helper = Helper::start(script, 300, 500);
    helper.event("started");
    helper.output_until("DONE");
    helper.send(json!({"op": "checkpoint", "request_id": "too-large"}));
    let failed = helper.event("checkpoint_failed");
    assert_eq!(failed["request_id"], "too-large");
    assert_eq!(failed["error"], "snapshot_too_large");
    assert_eq!(failed["maximum_bytes"], 2 * 1024 * 1024);

    helper.send(json!({"op": "close"}));
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
}

#[test]
fn control_channel_loss_reaps_signal_resistant_session_members() {
    let script =
        "trap '' HUP TERM; (trap '' HUP TERM; while :; do sleep 1; done) & echo CHILD:$!; wait";
    let mut helper = Helper::start(script, 24, 80);
    let started = helper.event("started");
    let sid = started["sid"].as_u64().unwrap() as i32;
    helper.event("output");
    helper.close_input();
    let cleanup = helper.event("cleanup");
    assert_eq!(cleanup["result"]["complete"], true, "{cleanup}");
    assert!(helper
        .child
        .wait_timeout(Duration::from_secs(1))
        .unwrap()
        .is_some());
    assert_eq!(unsafe { libc::getsid(sid) }, -1);
}

#[test]
fn cleanup_spans_job_control_process_groups_in_the_managed_session() {
    let script = r#"bash -c 'set -m; sleep 30 & bg=$!; shell_group=$(ps -o pgid= -p $$ | tr -d " "); bg_group=$(ps -o pgid= -p "$bg" | tr -d " "); echo GROUPS:$shell_group:$bg_group; wait'"#;
    let mut helper = Helper::start(script, 24, 80);
    helper.event("started");
    let output = helper.output_until("GROUPS:");
    let groups = output
        .lines()
        .find(|line| line.contains("GROUPS:"))
        .unwrap()
        .split("GROUPS:")
        .nth(1)
        .unwrap();
    let [shell_group, background_group] = groups.trim().split(':').collect::<Vec<_>>()[..] else {
        panic!("unexpected group report: {groups}");
    };
    assert_ne!(shell_group, background_group);
    helper.send(json!({"op": "close"}));
    assert_eq!(helper.event("cleanup")["result"]["complete"], true);
}
