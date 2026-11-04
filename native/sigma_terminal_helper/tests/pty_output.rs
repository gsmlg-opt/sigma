use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;
use wait_timeout::ChildExt;

fn completed_output(script: &str, expected_status: u32) -> Vec<u8> {
    let mut child = Command::new(env!("CARGO_BIN_EXE_sigma-terminal-helper"))
        .args(["--", "/bin/sh", "-c", script])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    // Waiting on Child may close its stdin; keep the helper control channel open.
    let mut input = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let reader = thread::spawn(move || {
        BufReader::new(stdout)
            .lines()
            .map(|line| serde_json::from_str::<Value>(&line.unwrap()).unwrap())
            .collect::<Vec<_>>()
    });
    let status = child.wait_timeout(Duration::from_secs(10)).unwrap();
    if status.is_none() {
        input.write_all(b"{\"op\":\"close\"}\n").unwrap();
        input.flush().unwrap();
        if child
            .wait_timeout(Duration::from_secs(6))
            .unwrap()
            .is_none()
        {
            child.kill().unwrap();
            child.wait().unwrap();
        }
    }
    let events = reader.join().unwrap();
    assert!(status.is_some(), "helper did not finish: {events:?}");
    assert!(status.unwrap().success(), "helper failed: {events:?}");
    assert_eq!(events.first().unwrap()["event"], "started");
    assert_eq!(events[events.len() - 2]["event"], "shell_exit");
    assert_eq!(events[events.len() - 2]["status"], expected_status);
    assert_eq!(events.last().unwrap()["event"], "cleanup");
    assert_eq!(events.last().unwrap()["result"]["complete"], true);

    let mut bytes = Vec::new();
    for (index, event) in events[1..events.len() - 2].iter().enumerate() {
        assert_eq!(event["event"], "output");
        assert_eq!(event["seq"], index + 1);
        bytes.extend(BASE64.decode(event["data"].as_str().unwrap()).unwrap());
    }
    bytes
}

#[test]
fn fast_exit_preserves_unicode_crlf_and_nonzero_status() {
    for status in [0, 7, 23] {
        for _ in 0..8 {
            let script = format!("stty -opost; printf '汉字🙂\\r\\nEND\\r\\n'; exit {status}");
            assert_eq!(
                completed_output(&script, status),
                "汉字🙂\r\nEND\r\n".as_bytes()
            );
        }
    }
}

#[test]
fn drains_a_long_tail_before_reporting_shell_exit() {
    let chunk = "汉字🙂\r\n".repeat(1_000);
    let script = format!(
        "stty -opost; i=0; while [ \"$i\" -lt 100 ]; do printf '%s' '{chunk}'; i=$((i+1)); done; printf 'TAIL-END\\r\\n'; exit 17"
    );
    let expected = format!("{}TAIL-END\r\n", chunk.repeat(100)).into_bytes();
    let actual = completed_output(&script, 17);
    assert_eq!(actual.len(), expected.len(), "PTY output was truncated");
    assert_eq!(actual, expected);
}

#[test]
fn empty_output_still_reports_exit_and_cleanup() {
    assert!(completed_output("exit 0", 0).is_empty());
}

#[test]
fn shell_exit_cleans_up_remaining_slave_holders_before_draining() {
    assert_eq!(
        completed_output(
            "stty -opost; (trap '' HUP; exec sleep 30) >/dev/null 2>&1 & printf 'TAIL\\r\\n'; exit 19",
            19
        ),
        b"TAIL\r\n"
    );
}

#[test]
fn echoing_slave_holder_never_adds_a_shutdown_input_newline() {
    assert_eq!(
        completed_output(
            "stty echo; (trap '' HUP; exec sleep 30) </dev/tty >/dev/tty 2>&1 & printf 'TAIL\\n'; exit 19",
            19
        ),
        b"TAIL\r\n"
    );
}
