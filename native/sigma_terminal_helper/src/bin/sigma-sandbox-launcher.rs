//! Trusted host-only JSON launcher; model arguments must never construct this config.
//! Exit 125 diagnoses launcher validation errors but is also a valid payload status.
//! It must never be treated as evidence that the payload did not execute.

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
mod linux {
    use anyhow::{bail, ensure, Context, Result};
    use serde::Deserialize;
    use std::collections::{BTreeMap, BTreeSet};
    use std::ffi::{CString, OsStr};
    use std::io::Write;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::{Component, Path, PathBuf};

    #[derive(Clone, Copy, Default, Deserialize)]
    #[serde(rename_all = "snake_case")]
    enum RuntimeLayout {
        #[default]
        NixClosure,
        MergedUsr,
    }

    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct RuntimeAliases {
        sh: PathBuf,
        env: PathBuf,
    }

    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Config {
        version: u32,
        workspace: PathBuf,
        cwd: PathBuf,
        executable: PathBuf,
        args: Vec<String>,
        runtime_roots: Vec<PathBuf>,
        #[serde(default)]
        runtime_layout: RuntimeLayout,
        #[serde(default)]
        runtime_aliases: Option<RuntimeAliases>,
        env: BTreeMap<String, String>,
        bwrap: PathBuf,
    }

    #[repr(C)]
    struct OpenHow {
        flags: u64,
        mode: u64,
        resolve: u64,
    }

    fn path_string(path: &Path) -> Result<CString> {
        Ok(CString::new(path.as_os_str().as_bytes())?)
    }

    fn absolute_clean(path: &Path) -> Result<()> {
        ensure!(
            path.is_absolute(),
            "path must be absolute: {}",
            path.display()
        );
        ensure!(
            !path
                .as_os_str()
                .as_bytes()
                .split(|byte| *byte == b'/')
                .any(|part| part == b"." || part == b".."),
            "dot components are forbidden: {}",
            path.display()
        );
        ensure!(
            path.components()
                .all(|part| matches!(part, Component::RootDir | Component::Normal(_))),
            "invalid path"
        );
        Ok(())
    }

    fn anchor(path: &Path, directory: bool) -> Result<OwnedFd> {
        absolute_clean(path)?;
        let how = OpenHow {
            flags: (libc::O_PATH | libc::O_CLOEXEC | if directory { libc::O_DIRECTORY } else { 0 })
                as u64,
            mode: 0,
            // RESOLVE_NO_MAGICLINKS | RESOLVE_NO_SYMLINKS. No fallback on old kernels.
            resolve: 0x02 | 0x04,
        };
        let name = path_string(path)?;
        let fd = unsafe {
            libc::syscall(
                libc::SYS_openat2,
                libc::AT_FDCWD,
                name.as_ptr(),
                &how,
                std::mem::size_of::<OpenHow>(),
            )
        };
        ensure!(
            fd >= 0,
            "cannot anchor {}: {}",
            path.display(),
            std::io::Error::last_os_error()
        );
        Ok(unsafe { OwnedFd::from_raw_fd(fd as i32) })
    }

    fn stat(fd: i32) -> Result<libc::stat> {
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        ensure!(
            unsafe { libc::fstat(fd, stat.as_mut_ptr()) } == 0,
            "fstat: {}",
            std::io::Error::last_os_error()
        );
        Ok(unsafe { stat.assume_init() })
    }

    fn inherit(fd: &OwnedFd) -> Result<()> {
        ensure!(
            unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, 0) } == 0,
            "cannot pass sandbox descriptor: {}",
            std::io::Error::last_os_error()
        );
        Ok(())
    }

    fn network_filter() -> Result<OwnedFd> {
        // Classic BPF seccomp_data: architecture at 4, syscall number at 0.
        let mut instructions: Vec<(u16, u8, u8, u32)> = vec![
            (0x20, 0, 0, 4),
            (0x15, 1, 0, 0xc000003e), // AUDIT_ARCH_X86_64 only.
            (0x06, 0, 0, 0x80000000), // KILL_PROCESS on compatibility ABIs.
            (0x20, 0, 0, 0),
            (0x35, 0, 1, 0x40000000), // Reject x32 syscall space.
            (0x06, 0, 0, 0x00050000 | libc::EPERM as u32),
        ];
        for syscall in [
            41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 288, 299, 307, 425, 426,
            427,
        ] {
            instructions.push((0x15, 0, 1, syscall));
            instructions.push((0x06, 0, 0, 0x00050000 | libc::EPERM as u32));
        }
        instructions.push((0x06, 0, 0, 0x7fff0000)); // ALLOW other native syscalls.
        let name = CString::new("sigma-network-denied")?;
        let raw = unsafe {
            libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING)
        };
        ensure!(
            raw >= 0,
            "seccomp memfd unavailable: {}",
            std::io::Error::last_os_error()
        );
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        let mut file = std::fs::File::from(fd);
        for (code, jt, jf, k) in instructions {
            file.write_all(&code.to_ne_bytes())?;
            file.write_all(&[jt, jf])?;
            file.write_all(&k.to_ne_bytes())?;
        }
        ensure!(
            unsafe { libc::lseek(file.as_raw_fd(), 0, libc::SEEK_SET) } == 0,
            "cannot rewind seccomp filter"
        );
        ensure!(
            unsafe {
                libc::fcntl(
                    file.as_raw_fd(),
                    libc::F_ADD_SEALS,
                    libc::F_SEAL_WRITE
                        | libc::F_SEAL_GROW
                        | libc::F_SEAL_SHRINK
                        | libc::F_SEAL_SEAL,
                )
            } == 0,
            "cannot seal seccomp filter"
        );
        Ok(file.into())
    }

    fn nix_root(path: &Path) -> bool {
        path.parent() == Some(Path::new("/nix/store"))
            && path
                .file_name()
                .and_then(OsStr::to_str)
                .is_some_and(|name| {
                    name.split_once('-').is_some_and(|(hash, suffix)| {
                        hash.len() == 32
                            && hash
                                .bytes()
                                .all(|byte| b"0123456789abcdfghijklmnpqrsvwxyz".contains(&byte))
                            && !suffix.is_empty()
                    })
                })
    }

    pub fn run() -> Result<()> {
        // Set parent death before parsing/opening. Exec preserves this PID; bwrap
        // also watches its parent and owns a private PID namespace/reaper.
        let parent = unsafe { libc::getppid() };
        ensure!(parent > 1, "launch owner is unavailable");
        ensure!(
            unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) } == 0,
            "parent-death monitoring unavailable"
        );
        ensure!(unsafe { libc::getppid() } == parent, "launch owner changed");
        for fd in 0..=2 {
            let metadata = stat(fd).context("stdio must be open")?;
            ensure!(
                metadata.st_mode & libc::S_IFMT != libc::S_IFSOCK,
                "socket stdio is forbidden (fd {fd})"
            );
        }
        // Includes inherited host sockets and pre-mount writable anchors. Do not
        // merely CLOEXEC these: later bwrap needs a small explicit descriptor set.
        ensure!(
            unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) } == 0,
            "close_range unavailable: {}",
            std::io::Error::last_os_error()
        );

        let arguments: Vec<_> = std::env::args_os().skip(1).collect();
        ensure!(
            arguments.len() == 2 && arguments[0] == "--config-json",
            "usage: sigma-sandbox-launcher --config-json JSON"
        );
        ensure!(
            arguments[1].len() <= 120 * 1024,
            "config exceeds argv limit"
        );
        let config: Config =
            serde_json::from_slice(arguments[1].as_bytes()).context("invalid config")?;
        ensure!(config.version == 1, "unsupported config version");
        absolute_clean(&config.workspace)?;
        ensure!(
            config.workspace.components().count() >= 3,
            "workspace root is too broad"
        );
        ensure!(
            !["/nix", "/proc", "/sys", "/dev", "/run", "/etc", "/usr", "/bin", "/sbin", "/lib"]
                .iter()
                .any(|root| config.workspace.starts_with(root)),
            "workspace overlaps a reserved root"
        );
        ensure!(
            !(config.workspace.starts_with("/home") && config.workspace.components().count() <= 3),
            "workspace must not expose a whole home"
        );
        absolute_clean(&config.cwd)?;
        ensure!(
            config.cwd.starts_with(&config.workspace),
            "cwd must remain inside workspace"
        );
        ensure!(
            !config.runtime_roots.is_empty() && config.runtime_roots.len() <= 4096,
            "runtime closure is empty or too large"
        );
        let roots: BTreeSet<_> = config.runtime_roots.iter().collect();
        for root in &roots {
            absolute_clean(root)?;
        }
        match config.runtime_layout {
            RuntimeLayout::NixClosure => {
                for root in &roots {
                    ensure!(
                        nix_root(root),
                        "runtime root must be one direct Nix store entry: {}",
                        root.display()
                    );
                }
            }
            RuntimeLayout::MergedUsr => {
                ensure!(
                    config.runtime_roots.len() == 1 && config.runtime_roots[0] == Path::new("/usr"),
                    "merged_usr requires runtime_roots exactly ['/usr']"
                );
            }
        }
        absolute_clean(&config.executable)?;
        ensure!(
            roots.iter().any(|root| config.executable.starts_with(root)),
            "executable is outside the runtime closure"
        );
        let executable = anchor(&config.executable, false)?;
        let executable_stat = stat(executable.as_raw_fd())?;
        ensure!(
            executable_stat.st_mode & libc::S_IFMT == libc::S_IFREG
                && executable_stat.st_mode & 0o111 != 0,
            "executable is not an executable regular file"
        );
        // The descriptor validates the complete symlink-free executable path;
        // the same explicit runtime root is mounted before path lookup. Host
        // administrators concurrently replacing runtime files are outside this
        // payload isolation boundary.
        drop(executable);
        if let Some(aliases) = &config.runtime_aliases {
            ensure!(
                matches!(config.runtime_layout, RuntimeLayout::NixClosure),
                "runtime aliases are only supported for Nix closures"
            );
            for path in [&aliases.sh, &aliases.env] {
                absolute_clean(path)?;
                ensure!(
                    roots.iter().any(|root| path.starts_with(root)),
                    "interpreter alias is outside the runtime closure"
                );
                let executable = anchor(path, false)?;
                let metadata = stat(executable.as_raw_fd())?;
                ensure!(
                    metadata.st_mode & libc::S_IFMT == libc::S_IFREG
                        && metadata.st_mode & 0o111 != 0,
                    "interpreter alias is not an executable regular file"
                );
            }
        }
        for (key, value) in &config.env {
            ensure!(
                ["PATH", "LANG", "LC_ALL", "TERM", "COLORTERM"].contains(&key.as_str()),
                "environment key is not allowed: {key}"
            );
            ensure!(!value.contains('\0'), "environment value contains NUL");
            if key == "PATH" {
                for entry in value.split(':') {
                    let path = Path::new(entry);
                    absolute_clean(path)?;
                    ensure!(
                        roots.iter().any(|root| path.starts_with(root)),
                        "PATH is outside the runtime closure"
                    );
                }
            }
        }

        let workspace = anchor(&config.workspace, true)?;
        let cwd = if config.cwd != config.workspace {
            Some(anchor(&config.cwd, true)?)
        } else {
            None
        };
        let runtime: Vec<_> = roots
            .iter()
            .map(|root| anchor(root, false))
            .collect::<Result<_>>()?;
        for fd in &runtime {
            let kind = stat(fd.as_raw_fd())?.st_mode & libc::S_IFMT;
            ensure!(
                kind == libc::S_IFDIR || kind == libc::S_IFREG,
                "runtime entries must be regular files or directories"
            );
        }
        let bwrap = anchor(&config.bwrap, false)?;
        let bwrap_stat = stat(bwrap.as_raw_fd())?;
        ensure!(
            bwrap_stat.st_mode & libc::S_IFMT == libc::S_IFREG && bwrap_stat.st_mode & 0o111 != 0,
            "bwrap is not an executable regular file"
        );
        ensure!(
            bwrap_stat.st_mode & (libc::S_ISUID | libc::S_ISGID) == 0,
            "privileged bwrap executables are unsupported"
        );
        let filter = network_filter()?;
        let mut argv: Vec<CString> = Vec::new();
        let mut push = |value: &OsStr| -> Result<()> {
            argv.push(CString::new(value.as_bytes())?);
            Ok(())
        };
        push(config.bwrap.as_os_str())?;
        for option in [
            "--unshare-user",
            "--unshare-pid",
            "--unshare-net",
            "--unshare-ipc",
            "--unshare-uts",
            "--die-with-parent",
            "--new-session",
            "--disable-userns",
            "--cap-drop",
            "ALL",
            "--hostname",
            "sigma",
            "--clearenv",
            "--proc",
            "/proc",
            "--dev",
            "/dev",
            "--tmpfs",
            "/tmp",
            "--dir",
            "/home",
            "--dir",
            "/home/sigma",
        ] {
            push(OsStr::new(option))?;
        }
        if let RuntimeLayout::NixClosure = config.runtime_layout {
            for option in ["--dir", "/nix", "--dir", "/nix/store"] {
                push(OsStr::new(option))?;
            }
        }
        for (root, fd) in roots.iter().zip(&runtime) {
            inherit(fd)?;
            push(OsStr::new("--ro-bind-fd"))?;
            push(OsStr::new(&fd.as_raw_fd().to_string()))?;
            push(root.as_os_str())?;
        }
        if let RuntimeLayout::MergedUsr = config.runtime_layout {
            // Fixed sandbox aliases, never host symlink mount sources. This
            // supports the standard merged-/usr ELF loader and script paths.
            for (target, path) in [
                ("usr/bin", "/bin"),
                ("usr/sbin", "/sbin"),
                ("usr/lib", "/lib"),
                ("usr/lib64", "/lib64"),
            ] {
                push(OsStr::new("--symlink"))?;
                push(OsStr::new(target))?;
                push(OsStr::new(path))?;
            }
        }
        if let Some(aliases) = &config.runtime_aliases {
            // These are sandbox-owned mount points, never host directories.
            // Preserve interpreter basenames (notably coreutils' env argv[0])
            // while resolving only into the already mounted read-only closure.
            for option in ["--tmpfs", "/bin", "--tmpfs", "/usr", "--dir", "/usr/bin"] {
                push(OsStr::new(option))?;
            }
            for (target, path) in [(&aliases.sh, "/bin/sh"), (&aliases.env, "/usr/bin/env")] {
                push(OsStr::new("--symlink"))?;
                push(target.as_os_str())?;
                push(OsStr::new(path))?;
            }
            // chmod alone cannot protect aliases from the mapped payload owner.
            for option in ["--remount-ro", "/bin", "--remount-ro", "/usr"] {
                push(OsStr::new(option))?;
            }
        }
        inherit(&workspace)?;
        push(OsStr::new("--bind-fd"))?;
        push(OsStr::new(&workspace.as_raw_fd().to_string()))?;
        push(config.workspace.as_os_str())?;
        if let Some(fd) = &cwd {
            inherit(fd)?;
            push(OsStr::new("--bind-fd"))?;
            push(OsStr::new(&fd.as_raw_fd().to_string()))?;
            push(config.cwd.as_os_str())?;
        }
        push(OsStr::new("--chdir"))?;
        push(config.cwd.as_os_str())?;
        for (key, value) in &config.env {
            push(OsStr::new("--setenv"))?;
            push(OsStr::new(key))?;
            push(OsStr::new(value))?;
        }
        push(OsStr::new("--setenv"))?;
        push(OsStr::new("HOME"))?;
        push(OsStr::new("/home/sigma"))?;
        inherit(&filter)?;
        push(OsStr::new("--seccomp"))?;
        push(OsStr::new(&filter.as_raw_fd().to_string()))?;
        push(OsStr::new("--"))?;
        push(config.executable.as_os_str())?;
        for argument in &config.args {
            push(OsStr::new(argument))?;
        }
        let mut pointers: Vec<_> = argv.iter().map(|value| value.as_ptr()).collect();
        pointers.push(std::ptr::null());
        let environment = [std::ptr::null::<libc::c_char>()];
        unsafe {
            libc::fexecve(bwrap.as_raw_fd(), pointers.as_ptr(), environment.as_ptr());
        }
        bail!("bwrap exec failed: {}", std::io::Error::last_os_error())
    }
}

fn main() {
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    let result = linux::run();
    #[cfg(not(all(target_os = "linux", target_arch = "x86_64")))]
    let result: anyhow::Result<()> = Err(anyhow::anyhow!("sandbox requires Linux x86_64"));
    if let Err(error) = result {
        eprintln!(
            "sigma-sandbox-launcher: {}",
            serde_json::json!({"error":format!("{error:#}")})
        );
        std::process::exit(125);
    }
}
