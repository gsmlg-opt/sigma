#![cfg(all(target_os = "linux", target_arch = "x86_64"))]

use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fs;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::symlink;
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};
use wait_timeout::ChildExt;

static NEXT: AtomicUsize = AtomicUsize::new(0);

struct Fixture {
    root: PathBuf,
    workspace: PathBuf,
    config: Value,
    python: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "sigma-native-sandbox-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let workspace = root.join("workspace");
        fs::create_dir_all(&workspace).unwrap();
        let python = resolve_program("python3");
        let bwrap = resolve_program("bwrap");
        let nix = python.starts_with("/nix/store");
        let roots: Vec<String> = if nix {
            let store_root = PathBuf::from("/nix/store").join(
                python
                    .strip_prefix("/nix/store")
                    .unwrap()
                    .components()
                    .next()
                    .unwrap(),
            );
            let closure = Command::new("nix-store")
                .args(["--query", "--requisites"])
                .arg(store_root)
                .output()
                .expect("Nix closure query is a required acceptance prerequisite");
            assert!(closure.status.success(), "{:?}", closure);
            std::str::from_utf8(&closure.stdout)
                .unwrap()
                .lines()
                .map(str::to_string)
                .collect()
        } else {
            assert!(
                python.starts_with("/usr"),
                "unsupported acceptance runtime: {python:?}"
            );
            vec!["/usr".to_string()]
        };
        let mut config = json!({
            "version": 1,
            "workspace": workspace,
            "cwd": workspace,
            "executable": python,
            "args": [],
            "runtime_roots": roots,
            "env": {},
            "bwrap": bwrap,
        });
        if !nix {
            config["runtime_layout"] = json!("merged_usr");
        }
        Self {
            root,
            workspace,
            config,
            python,
        }
    }

    fn command(&self, script: &str) -> Command {
        self.command_with(&self.config, script)
    }

    fn command_with(&self, config: &Value, script: &str) -> Command {
        let mut config = config.clone();
        config["args"] = json!(["-c", script]);
        let mut command = Command::new(env!("CARGO_BIN_EXE_sigma-sandbox-launcher"));
        command.arg("--config-json").arg(config.to_string());
        command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }

    fn run(&self, script: &str) -> Output {
        finish(self.command(script).spawn().unwrap())
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn resolve_program(program: &str) -> PathBuf {
    std::env::split_paths(&std::env::var_os("PATH").unwrap())
        .map(|directory| directory.join(program))
        .find(|path| path.is_file())
        .unwrap_or_else(|| panic!("{program} is a required acceptance prerequisite"))
        .canonicalize()
        .unwrap()
}

fn finish(mut child: Child) -> Output {
    if child
        .wait_timeout(Duration::from_secs(15))
        .unwrap()
        .is_none()
    {
        child.kill().unwrap();
        let output = child.wait_with_output().unwrap();
        panic!("sandbox timed out: {:?}", output);
    }
    child.wait_with_output().unwrap()
}

fn success(output: Output) -> Value {
    assert!(output.status.success(), "sandbox failed: {:?}", output);
    serde_json::from_slice(&output.stdout).unwrap()
}

fn rejected(fixture: &Fixture, config: Value) {
    let output = finish(
        fixture
            .command_with(&config, "raise RuntimeError('payload executed')")
            .spawn()
            .unwrap(),
    );
    assert_eq!(output.status.code(), Some(125), "{:?}", output);
    assert!(String::from_utf8_lossy(&output.stderr).contains("sigma-sandbox-launcher:"));
    assert!(!String::from_utf8_lossy(&output.stderr).contains("payload executed"));
}

#[test]
fn workspace_is_writable_and_home_sibling_runtime_and_environment_are_isolated() {
    let fixture = Fixture::new();
    fs::write(fixture.root.join("private"), "private").unwrap();
    fs::write(fixture.workspace.join("input"), "workspace").unwrap();
    symlink(
        std::env::var("HOME").unwrap(),
        fixture.workspace.join("home-link"),
    )
    .unwrap();
    let script = format!(
        r#"
import json, os, pathlib, socket
p=pathlib.Path('output'); p.write_text(pathlib.Path('input').read_text())
try:
 fd=os.open({python:?},os.O_WRONLY); os.close(fd); readonly=False
except OSError:
 readonly=True
print(json.dumps({{'written':p.read_text(),'cwd':os.getcwd(),'home':os.environ.get('HOME'),'ambient':os.environ.get('SIGMA_SANDBOX_SECRET'),'host_home':pathlib.Path({home:?}).exists(),'home_link':pathlib.Path('home-link').exists(),'sibling':pathlib.Path({sibling:?}).exists(),'readonly':readonly,'hostname':socket.gethostname()}}))
"#,
        python = fixture.python.to_str().unwrap(),
        home = std::env::var("HOME").unwrap(),
        sibling = fixture.root.join("private").to_str().unwrap()
    );
    let mut command = fixture.command(&script);
    command.env("SIGMA_SANDBOX_SECRET", "must-not-leak");
    let result = success(finish(command.spawn().unwrap()));
    assert_eq!(result["written"], "workspace");
    assert_eq!(result["cwd"], fixture.workspace.to_str().unwrap());
    assert_eq!(result["home"], "/home/sigma");
    assert_eq!(result["ambient"], Value::Null);
    assert_eq!(result["host_home"], false);
    assert_eq!(result["home_link"], false);
    assert_eq!(result["sibling"], false);
    assert_eq!(result["readonly"], true);
    assert_eq!(result["hostname"], "sigma");
}

#[test]
fn descendant_cwd_and_explicit_environment_are_preserved_inside_workspace() {
    let fixture = Fixture::new();
    let cwd = fixture.workspace.join("child");
    fs::create_dir(&cwd).unwrap();
    let mut config = fixture.config.clone();
    config["cwd"] = json!(cwd);
    config["env"] = json!({"LANG":"C.UTF-8","TERM":"xterm-256color"});
    let output = finish(fixture.command_with(&config, "import json,os,pathlib;pathlib.Path('written').write_text('ok');print(json.dumps({'cwd':os.getcwd(),'lang':os.environ['LANG'],'term':os.environ['TERM']}))").spawn().unwrap());
    let result = success(output);
    assert_eq!(result["cwd"], cwd.to_str().unwrap());
    assert_eq!(result["lang"], "C.UTF-8");
    assert_eq!(result["term"], "xterm-256color");
    assert_eq!(fs::read_to_string(cwd.join("written")).unwrap(), "ok");
}

#[test]
fn explicit_runtime_layout_preserves_the_existing_runtime_policy() {
    let fixture = Fixture::new();
    let mut config = fixture.config.clone();
    config["runtime_layout"] = if fixture.python.starts_with("/nix/store") {
        json!("nix_closure")
    } else {
        json!("merged_usr")
    };
    let output = finish(
        fixture
            .command_with(&config, "import json;print(json.dumps({'ok':True}))")
            .spawn()
            .unwrap(),
    );
    assert_eq!(success(output)["ok"], true);
}

#[test]
fn runtime_layouts_reject_unknown_mixed_broad_or_duplicate_catalogs() {
    let fixture = Fixture::new();
    for layout in ["unknown", "merged_usr", "nix_closure"] {
        for roots in [
            json!(["/"]),
            json!(["/usr", "/nix/store"]),
            json!(["/usr", "/usr"]),
        ] {
            let mut config = fixture.config.clone();
            config["runtime_layout"] = json!(layout);
            config["runtime_roots"] = roots;
            rejected(&fixture, config);
        }
    }
    let mut config = fixture.config.clone();
    config["runtime_layout"] = json!("merged_usr");
    config["runtime_roots"] = json!(["/nix/store"]);
    rejected(&fixture, config);
}

fn interpreter_config(fixture: &Fixture) -> Value {
    let mut config = fixture.config.clone();
    if fixture.python.starts_with("/nix/store") {
        let shell = fs::canonicalize("/bin/sh").unwrap();
        let env = fs::canonicalize("/usr/bin/env").unwrap();
        let roots: Vec<_> = [&shell, &env]
            .iter()
            .map(|path| {
                Path::new("/nix/store").join(
                    path.strip_prefix("/nix/store")
                        .unwrap()
                        .components()
                        .next()
                        .unwrap(),
                )
            })
            .collect();
        let closure = Command::new("nix-store")
            .args(["--query", "--requisites"])
            .args(roots)
            .output()
            .unwrap();
        assert!(closure.status.success(), "{:?}", closure);
        let mut roots: BTreeSet<String> = config["runtime_roots"]
            .as_array()
            .unwrap()
            .iter()
            .map(|root| root.as_str().unwrap().to_owned())
            .collect();
        roots.extend(
            std::str::from_utf8(&closure.stdout)
                .unwrap()
                .lines()
                .map(str::to_owned),
        );
        config["runtime_roots"] = json!(roots);
        config["runtime_aliases"] = json!({"sh":shell,"env":env});
        config["env"] = json!({"PATH": roots.iter().map(|root| format!("{root}/bin")).collect::<Vec<_>>().join(":")});
    } else {
        config["env"] = json!({"PATH":"/usr/bin:/usr/sbin"});
    }
    config
}

#[test]
fn kernel_shebangs_use_fixed_shell_and_multicall_env_with_readonly_alias_directories() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Fixture::new();
    for (name, text) in [
        ("shell-script", "#!/bin/sh\nprintf shell-ok\n"),
        ("env-script", "#!/usr/bin/env sh\nprintf env-ok\n"),
    ] {
        let path = fixture.workspace.join(name);
        fs::write(&path, text).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let config = interpreter_config(&fixture);
    let output = finish(fixture.command_with(&config, r#"
import errno,json,os,pathlib,subprocess
results=[subprocess.check_output([p],text=True) for p in ['./shell-script','./env-script']]
readonly=[]
for directory in ['/bin','/usr','/usr/bin']:
 try:
  os.chmod(directory,0o777)
  pathlib.Path(directory+'/sigma-alias-escape').symlink_to(os.getcwd())
  readonly.append(False)
 except OSError as e:
  readonly.append(e.errno==errno.EROFS)
print(json.dumps({'results':results,'readonly':readonly,'shell':os.path.realpath('/bin/sh'),'env':os.path.realpath('/usr/bin/env')}))
"#).spawn().unwrap());
    let result = success(output);
    assert_eq!(result["results"], json!(["shell-ok", "env-ok"]));
    assert_eq!(result["readonly"], json!([true, true, true]));
    assert_eq!(
        result["shell"],
        fs::canonicalize("/bin/sh").unwrap().to_str().unwrap()
    );
    assert_eq!(
        result["env"],
        fs::canonicalize("/usr/bin/env").unwrap().to_str().unwrap()
    );
}

#[test]
fn interpreter_aliases_reject_unknown_incomplete_untrusted_and_shadowed_sources() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Fixture::new();
    let base = interpreter_config(&fixture);
    let sh = fs::canonicalize("/bin/sh").unwrap();
    let env = fs::canonicalize("/usr/bin/env").unwrap();
    let untrusted = fixture.workspace.join("env");
    fs::write(&untrusted, "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&untrusted, fs::Permissions::from_mode(0o700)).unwrap();
    for aliases in [
        json!({"sh":sh}),
        json!({"sh":sh,"env":env,"python":sh}),
        json!({"sh":sh,"env":untrusted}),
        json!({"sh":"/bin/sh","env":env}),
        json!({"sh":sh,"env":env.parent().unwrap()}),
    ] {
        let mut config = base.clone();
        config["runtime_aliases"] = aliases;
        rejected(&fixture, config);
    }
    for workspace in [
        "/bin/sh",
        "/bin/sigma-workspace",
        "/usr/bin",
        "/usr/bin/sigma-workspace",
    ] {
        let mut config = base.clone();
        config["workspace"] = json!(workspace);
        config["cwd"] = json!(workspace);
        rejected(&fixture, config);
    }
    let mut merged = fixture.config.clone();
    merged["runtime_layout"] = json!("merged_usr");
    merged["runtime_roots"] = json!(["/usr"]);
    merged["runtime_aliases"] = json!({"sh":sh,"env":env});
    rejected(&fixture, merged);
}

#[test]
fn network_filter_blocks_workspace_unix_sockets_all_socket_families_and_io_uring() {
    let fixture = Fixture::new();
    let _listener = UnixListener::bind(fixture.workspace.join("host.sock")).unwrap();
    let result = success(fixture.run(r#"
import ctypes, errno, json, mmap, os, pathlib, signal, socket
libc=ctypes.CDLL(None,use_errno=True); libc.syscall.restype=ctypes.c_long
r={}
for name,nr,args in [('socket',41,(1,1,0)),('socketpair',53,(1,1,0,0)),('connect',42,(-1,0,0)),('io_uring_setup',425,(0,0)),('io_uring_enter',426,(-1,0,0,0,0,0)),('io_uring_register',427,(-1,0,0,0)),('x32_getpid',0x40000027,())]:
 ctypes.set_errno(0); value=libc.syscall(nr,*args); r[name]=[value,ctypes.get_errno()]
try:
 s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect('host.sock'); r['escape']=True
except OSError as e:
 r['escape']=e.errno
r['status']=[l for l in pathlib.Path('/proc/self/status').read_text().splitlines() if l.startswith(('NoNewPrivs:','Seccomp:'))]
# Execute a real i386-ABI syscall in a child, without any 32-bit libraries.
# mov eax,20; int 0x80; ret: getpid succeeds without the architecture guard.
page=mmap.mmap(-1,mmap.PAGESIZE,prot=mmap.PROT_READ|mmap.PROT_WRITE|mmap.PROT_EXEC)
page.write(bytes.fromhex('b8 14 00 00 00 cd 80 c3'))
compat=ctypes.CFUNCTYPE(ctypes.c_long)(ctypes.addressof(ctypes.c_char.from_buffer(page)))
pid=os.fork()
if pid==0:
 compat(); os._exit(0)
_,status=os.waitpid(pid,0)
r['compat_sigsys']=os.WIFSIGNALED(status) and os.WTERMSIG(status)==signal.SIGSYS
print(json.dumps(r))
"#));
    for name in [
        "socket",
        "socketpair",
        "connect",
        "io_uring_setup",
        "io_uring_enter",
        "io_uring_register",
        "x32_getpid",
    ] {
        assert_eq!(result[name], json!([-1, libc::EPERM]), "{name}");
    }
    assert_eq!(result["escape"], libc::EPERM);
    assert_eq!(result["compat_sigsys"], true);
    assert_eq!(result["status"], json!(["NoNewPrivs:\t1", "Seccomp:\t2"]));
}

#[test]
fn inherited_socket_and_readonly_source_anchor_descriptors_do_not_enter_payload() {
    let fixture = Fixture::new();
    let (mut peer, socket) = UnixStream::pair().unwrap();
    peer.write_all(b"host-channel").unwrap();
    let marker = socket.as_raw_fd();
    let mut command = fixture.command(&format!(
        r#"
import json, os
try:
 os.fstat({marker}); inherited=True
except OSError:
 inherited=False
fds=[]
for name in os.listdir('/proc/self/fd'):
 try:
  fd=int(name)
  if fd>2: fds.append([fd,os.readlink('/proc/self/fd/'+name)])
 except OSError: pass
print(json.dumps({{'inherited':inherited,'fds':fds}}))
"#
    ));
    unsafe {
        command.pre_exec(move || {
            if libc::fcntl(marker, libc::F_SETFD, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let result = success(finish(command.spawn().unwrap()));
    assert_eq!(result["inherited"], false);
    assert_eq!(result["fds"], json!([]));
    let mut data = [0; 12];
    let mut socket = socket;
    socket.read_exact(&mut data).unwrap();
    assert_eq!(&data, b"host-channel");
}

#[test]
fn socket_stdio_is_rejected_and_payload_exit_status_is_unchanged() {
    let fixture = Fixture::new();
    for index in 0..=2 {
        let (_peer, socket) = UnixStream::pair().unwrap();
        let fd: std::os::fd::OwnedFd = socket.into();
        let mut command = fixture.command("raise SystemExit(0)");
        match index {
            0 => {
                command.stdin(Stdio::from(fd));
            }
            1 => {
                command.stdout(Stdio::from(fd));
            }
            _ => {
                command.stderr(Stdio::from(fd));
            }
        }
        let output = finish(command.spawn().unwrap());
        assert_eq!(output.status.code(), Some(125), "socket stdio {index}");
        if index != 2 {
            assert!(String::from_utf8_lossy(&output.stderr).contains("socket"));
        }
    }
    assert_eq!(fixture.run("raise SystemExit(37)").status.code(), Some(37));
    assert_eq!(
        fixture.run("raise SystemExit(125)").status.code(),
        Some(125)
    );
}

#[test]
fn symlink_ancestors_external_cwd_and_broad_runtime_roots_are_rejected() {
    let fixture = Fixture::new();
    let alias = fixture.root.join("alias");
    symlink(&fixture.workspace, &alias).unwrap();
    for field in ["workspace", "cwd"] {
        let mut config = fixture.config.clone();
        config[field] = json!(alias);
        rejected(&fixture, config);
    }
    let mut config = fixture.config.clone();
    config["cwd"] = json!(fixture.root);
    rejected(&fixture, config);
    for root in ["/", "/nix/store", "/home", "/tmp"] {
        let mut config = fixture.config.clone();
        config["runtime_roots"] = json!([root]);
        rejected(&fixture, config);
    }
    let mut config = fixture.config.clone();
    config["executable"] = json!("/bin/sh");
    rejected(&fixture, config);
    let mut config = fixture.config.clone();
    config["env"] = json!({"LD_PRELOAD":"/workspace/evil.so"});
    rejected(&fixture, config);
}

#[test]
fn absent_bwrap_and_invalid_config_fail_closed_without_payload_effects() {
    let fixture = Fixture::new();
    let mut config = fixture.config.clone();
    config["bwrap"] = json!(fixture.root.join("missing-bwrap"));
    rejected(&fixture, config);
    for change in [json!({"version":2}), json!({"unknown":true})] {
        let mut config = fixture.config.clone();
        for (key, value) in change.as_object().unwrap() {
            config[key] = value.clone();
        }
        rejected(&fixture, config);
    }
}

fn process_tree(pid: u32) -> Vec<(u32, String)> {
    let mut result = Vec::new();
    if let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) {
        let fields: Vec<_> = stat
            .rsplit_once(") ")
            .unwrap()
            .1
            .split_whitespace()
            .collect();
        result.push((pid, fields[19].to_string()));
        if let Ok(children) = fs::read_to_string(format!("/proc/{pid}/task/{pid}/children")) {
            for child in children.split_whitespace() {
                result.extend(process_tree(child.parse().unwrap()));
            }
        }
    }
    result
}

fn wait_stopped(tree: &[(u32, String)]) {
    let started = Instant::now();
    loop {
        let live: Vec<_> = tree
            .iter()
            .filter(|(pid, start)| {
                fs::read_to_string(format!("/proc/{pid}/stat")).is_ok_and(|stat| {
                    let fields: Vec<_> = stat
                        .rsplit_once(") ")
                        .unwrap()
                        .1
                        .split_whitespace()
                        .collect();
                    fields[19] == start && fields[0] != "Z"
                })
            })
            .collect();
        if live.is_empty() {
            return;
        }
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "live owned processes: {live:?}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn await_file(path: &Path, child: &mut Child) {
    let started = Instant::now();
    while !path.exists() {
        assert!(
            child.try_wait().unwrap().is_none(),
            "launcher exited before payload readiness"
        );
        if started.elapsed() >= Duration::from_secs(10) {
            let tree = process_tree(child.id());
            let _ = child.kill();
            let _ = child.wait();
            wait_stopped(&tree);
            panic!("payload readiness timeout");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

struct RetainedSandbox(Option<Child>);

impl RetainedSandbox {
    fn child(&mut self) -> &mut Child {
        self.0.as_mut().unwrap()
    }

    fn finish(mut self, kill: bool) -> Output {
        let mut child = self.0.take().unwrap();
        if kill {
            child.kill().unwrap();
        }
        finish(child)
    }
}

impl Drop for RetainedSandbox {
    fn drop(&mut self) {
        if let Some(child) = &mut self.0 {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn concurrent_round(workspace: &Path, commands: &mut [(String, RetainedSandbox)], phase: usize) {
    // Send to every retained command before waiting for any acknowledgement.
    for (token, command) in commands.iter_mut() {
        let input = command.child().stdin.as_mut().unwrap();
        serde_json::to_writer(
            &mut *input,
            &json!({"phase":phase,"text":format!("  中文 {token}\n\t")}),
        )
        .unwrap();
        input.write_all(b"\n").unwrap();
        input.flush().unwrap();
    }
    for (token, command) in commands {
        let ack = workspace.join(format!("{token}.ack-{phase}"));
        await_file(&ack, command.child());
        let result: Value = serde_json::from_slice(&fs::read(ack).unwrap()).unwrap();
        assert_eq!(result["token"], *token);
        assert_eq!(result["home"], *token);
        assert_eq!(result["tmp"], *token);
        assert_eq!(result["phase"], phase);
        assert_eq!(result["text"], format!("  中文 {token}\n\t"));
        assert_eq!(
            result["peers"],
            json!(["worker-0", "worker-1", "worker-2", "worker-3"])
        );
        assert!(command.child().try_wait().unwrap().is_none());
    }
}

#[test]
fn concurrent_commands_share_workspace_but_isolate_private_state_and_cleanup() {
    let fixture = Fixture::new();
    let mut commands: Vec<_> = (0..4)
        .map(|index| {
            let token = format!("worker-{index}");
            let script = format!(
                r#"
import json, os, pathlib, sys, time
token={token:?}
home=pathlib.Path.home()/'concurrent-state'
tmp=pathlib.Path('/tmp/concurrent-state')
assert not home.exists() and not tmp.exists()
home.write_text(token); tmp.write_text(token)
if os.fork()==0:
 os.setsid()
 pathlib.Path(token+'.descendant').write_text('ready')
 time.sleep(60)
 os._exit(0)
namespaces={{name:os.readlink('/proc/self/ns/'+name) for name in ['mnt','pid','net']}}
ready=pathlib.Path(token+'.ready')
pending=ready.with_suffix('.pending')
pending.write_text(json.dumps(namespaces)); pending.replace(ready)
for line in sys.stdin:
 request=json.loads(line)
 if request.get('exit'):
  pathlib.Path(token+'.done').write_text(token)
  raise SystemExit({status})
 result={{'token':token,'home':home.read_text(),'tmp':tmp.read_text(),**request,
 'peers':sorted(p.name.removesuffix('.ready') for p in pathlib.Path('.').glob('worker-*.ready'))}}
 encoded=json.dumps(result,ensure_ascii=False)
 print(encoded,flush=True)
 ack=pathlib.Path(token+'.ack-'+str(request['phase']))
 pending=ack.with_suffix(ack.suffix+'.pending')
 pending.write_text(encoded); pending.replace(ack)
"#,
                status = 20 + index
            );
            let child = fixture
                .command(&script)
                .stdin(Stdio::piped())
                .spawn()
                .unwrap();
            (token, RetainedSandbox(Some(child)))
        })
        .collect();

    let mut namespaces = Vec::new();
    let mut trees = Vec::new();
    for (token, command) in &mut commands {
        let ready = fixture.workspace.join(format!("{token}.ready"));
        await_file(&ready, command.child());
        await_file(
            &fixture.workspace.join(format!("{token}.descendant")),
            command.child(),
        );
        namespaces.push(serde_json::from_slice::<Value>(&fs::read(ready).unwrap()).unwrap());
        let tree = process_tree(command.child().id());
        assert!(tree.len() >= 3, "missing owned process tree: {tree:?}");
        trees.push(tree);
    }
    for name in ["mnt", "pid", "net"] {
        let distinct: BTreeSet<_> = namespaces
            .iter()
            .map(|value| value[name].as_str().unwrap())
            .collect();
        assert_eq!(distinct.len(), commands.len(), "shared {name} namespace");
    }

    concurrent_round(&fixture.workspace, &mut commands, 1);
    let (token, cancelled) = commands.remove(0);
    let output = cancelled.finish(true);
    assert_eq!(output.status.signal(), Some(libc::SIGKILL));
    assert!(output.stderr.is_empty(), "{output:?}");
    let responses: Vec<Value> = serde_json::Deserializer::from_slice(&output.stdout)
        .into_iter::<Value>()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(responses.len(), 1);
    assert_eq!(responses[0]["token"], token);
    wait_stopped(&trees[0]);

    // Cancellation of one namespace must not close another command's pipes or tree.
    concurrent_round(&fixture.workspace, &mut commands, 2);
    for (index, (token, mut command)) in commands.into_iter().enumerate() {
        command
            .child()
            .stdin
            .as_mut()
            .unwrap()
            .write_all(b"{\"exit\":true}\n")
            .unwrap();
        let output = command.finish(false);
        assert_eq!(output.status.code(), Some(21 + index as i32), "{output:?}");
        assert!(output.stderr.is_empty(), "{output:?}");
        let responses: Vec<Value> = serde_json::Deserializer::from_slice(&output.stdout)
            .into_iter::<Value>()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(responses.len(), 2);
        assert_eq!(responses[0]["phase"], 1);
        assert_eq!(responses[1]["phase"], 2);
        assert!(responses.iter().all(|value| value["token"] == token));
        assert_eq!(
            fs::read_to_string(fixture.workspace.join(format!("{token}.done"))).unwrap(),
            token
        );
        wait_stopped(&trees[index + 1]);
    }
    assert!(!fixture.workspace.join("worker-0.done").exists());
    let fresh = success(fixture.run(
        r#"
import json, pathlib
print(json.dumps({'home':(pathlib.Path.home()/'concurrent-state').exists(),
'tmp':pathlib.Path('/tmp/concurrent-state').exists(),
'done':sorted(p.read_text() for p in pathlib.Path('.').glob('worker-*.done'))}))
"#,
    ));
    assert_eq!(
        fresh,
        json!({"home":false,"tmp":false,"done":["worker-1","worker-2","worker-3"]})
    );
}

#[test]
fn launcher_sigkill_cleans_setsid_descendants() {
    let fixture = Fixture::new();
    let mut child = fixture
        .command(
            r#"
import os, pathlib, time
if os.fork()==0:
 os.setsid(); pathlib.Path('descendant-ready').write_text('ready'); time.sleep(60)
else:
 time.sleep(60)
"#,
        )
        .spawn()
        .unwrap();
    await_file(&fixture.workspace.join("descendant-ready"), &mut child);
    let tree = process_tree(child.id());
    child.kill().unwrap();
    child.wait().unwrap();
    wait_stopped(&tree);
    assert!(
        tree.len() >= 3,
        "expected launcher, namespace payload and descendant: {tree:?}"
    );
}

#[test]
fn launcher_owner_death_cleans_setsid_descendants() {
    let fixture = Fixture::new();
    let mut config = fixture.config.clone();
    config["args"] = json!(["-c", "import os,pathlib,time\nif os.fork()==0:\n os.setsid();pathlib.Path('owner-ready').write_text('ready');time.sleep(60)\nelse:\n time.sleep(60)"]);
    let mut owner = Command::new(&fixture.python)
        .args(["-c", "import subprocess,sys,time; p=subprocess.Popen(sys.argv[1:],stdin=subprocess.DEVNULL); time.sleep(60)", env!("CARGO_BIN_EXE_sigma-sandbox-launcher"), "--config-json", &config.to_string()])
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
    await_file(&fixture.workspace.join("owner-ready"), &mut owner);
    let tree = process_tree(owner.id());
    owner.kill().unwrap();
    owner.wait().unwrap();
    wait_stopped(&tree);
    assert!(
        tree.len() >= 4,
        "expected owner, launcher, payload and descendant: {tree:?}"
    );
}
