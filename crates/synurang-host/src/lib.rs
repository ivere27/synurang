//! Synurang Host Library
//!
//! This crate provides functionality for C++/Rust applications to:
//! - Load Go/C++/Rust plugins via FFI (Plugin Mode)
//! - Spawn child processes and communicate via gRPC over IPC (Process Mode)
//!
//! # Plugin Mode Example
//! ```no_run
//! use synurang_host::PluginHost;
//!
//! let plugin = PluginHost::load("./libmyplugin.so")?;
//! let response = plugin.invoke("MyService", "/pkg.MyService/Method", &request_data)?;
//! plugin.close();
//! # Ok::<(), synurang_host::Error>(())
//! ```
//!
//! # Process Mode Example
//! ```no_run
//! use synurang_host::ProcessHost;
//!
//! let process = ProcessHost::start("./child-process", &[])?;
//! let channel = process.channel();
//! // Use channel with tonic generated clients...
//! process.terminate();
//! # Ok::<(), synurang_host::Error>(())
//! ```

mod plugin;
mod process;

pub use plugin::{PluginHost, PluginStream};
pub use process::{new_ipc_listener, ProcessHost};

use thiserror::Error;

/// Environment variable name for IPC address
pub const ENV_VAR_IPC: &str = "SYNURANG_IPC";

#[derive(Debug, Clone)]
pub struct FfiError {
    pub message: String,
    pub code: i32,
    pub grpc_code: i32,
    pub payload: Vec<u8>,
}

impl FfiError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            code: 0,
            grpc_code: 2, // UNKNOWN
            payload: Vec::new(),
        }
    }
}

/// Error type for synurang-host operations
#[derive(Error, Debug)]
pub enum Error {
    #[error("Failed to load plugin: {0}")]
    LoadError(String),

    #[error("Plugin is closed")]
    PluginClosed,

    #[error("Symbol not found: {0}")]
    SymbolNotFound(String),

    #[error("Service not found: {0}")]
    ServiceNotFound(String),

    #[error("Plugin error: {}", .0.message)]
    PluginError(FfiError),

    #[error("Stream error: {}", .0.message)]
    StreamError(FfiError),

    #[error("Process error: {0}")]
    ProcessError(String),

    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("End of stream")]
    Eof,
}

pub type Result<T> = std::result::Result<T, Error>;
