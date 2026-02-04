//! Process host for spawning child processes with gRPC IPC
//!
//! Supports spawning Go/C++/Rust child processes and communicating via gRPC.
//! Uses socketpair on Unix for zero-copy IPC.

use crate::{Error, Result, ENV_VAR_IPC};
use std::process::{Child, Command, Stdio};
use tonic::transport::{Channel, Endpoint, Uri};

#[cfg(unix)]
use std::os::unix::io::{AsRawFd, FromRawFd, IntoRawFd, RawFd};

/// Process host for spawning and managing child processes
pub struct ProcessHost {
    child: Child,
    channel: Channel,
}

impl ProcessHost {
    /// Start a child process and establish gRPC connection
    ///
    /// On Unix: Uses socketpair, passes FD number in SYNURANG_IPC
    #[cfg(unix)]
    pub async fn start(executable: &str, args: &[&str]) -> Result<Self> {
        use nix::sys::socket::{socketpair, AddressFamily, SockFlag, SockType};
        use std::os::unix::process::CommandExt;
        use tokio::net::UnixStream;
        use tower::service_fn;

        // Create socketpair
        let (parent_fd, child_fd) = socketpair(
            AddressFamily::Unix,
            SockType::Stream,
            None,
            SockFlag::empty(),
        )
        .map_err(|e| Error::ProcessError(format!("socketpair failed: {}", e)))?;

        let child_raw: RawFd = child_fd.as_raw_fd();

        // Build command - child will inherit the FD
        let mut cmd = Command::new(executable);
        cmd.args(args);
        cmd.env(ENV_VAR_IPC, "3"); // FD 3 is first available after stdin/stdout/stderr
        cmd.stdin(Stdio::null());
        cmd.stdout(Stdio::inherit());
        cmd.stderr(Stdio::inherit());

        // Use pre_exec to dup the child_fd to fd 3
        unsafe {
            let child_fd_copy = child_raw;
            cmd.pre_exec(move || {
                // Dup child_fd to fd 3
                if child_fd_copy != 3 {
                    libc::dup2(child_fd_copy, 3);
                    libc::close(child_fd_copy);
                }
                Ok(())
            });
        }

        let child = cmd
            .spawn()
            .map_err(|e| Error::ProcessError(format!("spawn failed: {}", e)))?;

        // Close child fd in parent
        drop(child_fd);

        // Convert parent fd to tokio UnixStream (into_raw_fd transfers ownership)
        let std_stream = unsafe { std::os::unix::net::UnixStream::from_raw_fd(parent_fd.into_raw_fd()) };
        std_stream
            .set_nonblocking(true)
            .map_err(|e| Error::ProcessError(e.to_string()))?;

        let tokio_stream = UnixStream::from_std(std_stream)
            .map_err(|e| Error::ProcessError(e.to_string()))?;

        // Wrap in Arc<Mutex> for sharing in connector
        let stream = std::sync::Arc::new(tokio::sync::Mutex::new(Some(tokio_stream)));

        // Create connector that returns the stream once, wrapped for hyper
        let connector = service_fn(move |_: Uri| {
            let stream = stream.clone();
            async move {
                let mut guard = stream.lock().await;
                guard
                    .take()
                    .map(|s| hyper_util::rt::TokioIo::new(s))
                    .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "stream already used"))
            }
        });

        // Create channel
        let channel = Endpoint::try_from("http://[::]:50051")
            .map_err(|e| Error::ProcessError(e.to_string()))?
            .connect_with_connector(connector)
            .await
            .map_err(|e| Error::ProcessError(format!("connect failed: {}", e)))?;

        Ok(Self { child, channel })
    }

    /// Start a child process (Windows - uses named pipes)
    #[cfg(windows)]
    pub async fn start(executable: &str, args: &[&str]) -> Result<Self> {
        use std::ffi::OsStr;
        use std::os::windows::ffi::OsStrExt;
        use std::os::windows::io::{AsRawHandle, FromRawHandle, RawHandle};
        use tokio::net::windows::named_pipe::{ClientOptions, ServerOptions};
        use tower::service_fn;

        // Generate random pipe name
        let pipe_name = format!(
            r"\\.\pipe\synurang-{:016x}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );

        // Create named pipe server
        let server = ServerOptions::new()
            .first_pipe_instance(true)
            .create(&pipe_name)
            .map_err(|e| Error::ProcessError(format!("CreateNamedPipe failed: {}", e)))?;

        // Start child process with the pipe name
        let child = Command::new(executable)
            .args(args)
            .env(ENV_VAR_IPC, &pipe_name)
            .spawn()
            .map_err(|e| Error::ProcessError(format!("spawn failed: {}", e)))?;

        // Wait for child to connect
        server
            .connect()
            .await
            .map_err(|e| Error::ProcessError(format!("ConnectNamedPipe failed: {}", e)))?;

        // Wrap pipe for tonic connector
        let pipe = std::sync::Arc::new(tokio::sync::Mutex::new(Some(server)));

        let connector = service_fn(move |_: Uri| {
            let pipe = pipe.clone();
            async move {
                let mut guard = pipe.lock().await;
                guard
                    .take()
                    .map(|p| hyper_util::rt::TokioIo::new(p))
                    .ok_or_else(|| {
                        std::io::Error::new(std::io::ErrorKind::Other, "pipe already used")
                    })
            }
        });

        // Create channel
        let channel = Endpoint::try_from("http://[::]:50051")
            .map_err(|e| Error::ProcessError(e.to_string()))?
            .connect_with_connector(connector)
            .await
            .map_err(|e| Error::ProcessError(format!("connect failed: {}", e)))?;

        Ok(Self { child, channel })
    }

    /// Get the gRPC channel
    pub fn channel(&self) -> Channel {
        self.channel.clone()
    }

    /// Check if child is still running
    pub fn is_running(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    /// Wait for child to exit
    pub fn wait(&mut self) -> Result<i32> {
        let status = self
            .child
            .wait()
            .map_err(|e| Error::ProcessError(e.to_string()))?;
        Ok(status.code().unwrap_or(-1))
    }

    /// Terminate the child process
    pub fn terminate(&mut self) -> Result<()> {
        self.child
            .kill()
            .map_err(|e| Error::ProcessError(e.to_string()))
    }
}

impl Drop for ProcessHost {
    fn drop(&mut self) {
        // Kill and wait to prevent zombie processes
        let _ = self.child.kill();
        let _ = self.child.wait();  // Reap the zombie
    }
}

/// Get the IPC address from environment (for child process side)
///
/// On Unix: Returns the FD number as a string
/// On Windows: Returns the TCP address
pub fn new_ipc_listener() -> Result<String> {
    std::env::var(ENV_VAR_IPC).map_err(|_| {
        Error::ProcessError(format!(
            "{} environment variable not set",
            ENV_VAR_IPC
        ))
    })
}
