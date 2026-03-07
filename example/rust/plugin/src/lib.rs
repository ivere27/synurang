use synurang_service::example::v1::*;
use synurang_service::GreeterLogic;

const ERROR_TRIGGER_NAME: &str = "trigger_error";

#[allow(unused_imports)]
#[allow(dead_code)]
mod ffi_impl {
    // Include the generated FFI code FIRST so inner attributes are valid
    include!("example_ffi_plugin.rs");

    // Import types needed by the included code
    // Although defined after, Rust resolves module items non-linearly
    use super::*;
}

use ffi_impl::*;

struct RustPlugin {
    logic: GreeterLogic,
}

impl RustPlugin {
    fn new() -> Self {
        Self {
            logic: GreeterLogic::new("rust-plugin"),
        }
    }

    fn is_error_trigger(name: &str) -> bool {
        name == ERROR_TRIGGER_NAME
    }
}

fn ffi_test_error(message: &str, code: i32) -> FfiError {
    FfiError::new(message, code, 10)
}

impl GoGreeterServicePlugin for RustPlugin {
    fn bar(&self, request: HelloRequest) -> Result<HelloResponse, FfiError> {
        if Self::is_error_trigger(&request.name) {
            return Err(ffi_test_error("rust unary ffi error", 4301));
        }
        let (msg, from) = self.logic.bar(&request.name);
        Ok(HelloResponse {
            message: msg,
            from,
            timestamp: None,
        })
    }

    fn bar_server_stream(
        &self,
        request: HelloRequest,
        stream: &dyn PluginStreamSender<HelloResponse>,
    ) -> Result<(), FfiError> {
        if Self::is_error_trigger(&request.name) {
            return Err(ffi_test_error("rust server stream ffi error", 4302));
        }
        self.logic.bar_server_stream(&request.name, |msg, from| {
            let resp = HelloResponse {
                message: msg,
                from,
                timestamp: None,
            };
            stream.send(resp)
        });
        Ok(())
    }

    fn bar_client_stream(
        &self,
        stream: &dyn PluginStreamReceiver<HelloRequest>,
    ) -> Result<HelloResponse, FfiError> {
        let mut requests = Vec::new();
        while let Some(req) = stream.recv() {
            if Self::is_error_trigger(&req.name) {
                return Err(ffi_test_error("rust client stream ffi error", 4303));
            }
            requests.push(req.name);
        }
        let (msg, from) = self.logic.bar_client_stream(requests.into_iter());
        Ok(HelloResponse {
            message: msg,
            from,
            timestamp: None,
        })
    }

    fn bar_bidi_stream(
        &self,
        stream: &dyn PluginStreamBidi<HelloRequest, HelloResponse>,
    ) -> Result<(), FfiError> {
        while let Some(req) = stream.recv() {
            if Self::is_error_trigger(&req.name) {
                return Err(ffi_test_error("rust bidi stream ffi error", 4304));
            }
            self.logic.bar_bidi_stream(&req.name, |msg, from| {
                let resp = HelloResponse {
                    message: msg,
                    from,
                    timestamp: None,
                };
                stream.send(resp)
            });
        }
        Ok(())
    }

    fn upload_file(
        &self,
        _stream: &dyn PluginStreamReceiver<FileChunk>,
    ) -> Result<FileStatus, FfiError> {
        Err("not implemented".into())
    }

    fn download_file(
        &self,
        _request: DownloadFileRequest,
        _stream: &dyn PluginStreamSender<FileChunk>,
    ) -> Result<(), FfiError> {
        Err("not implemented".into())
    }

    fn bidi_file(
        &self,
        _stream: &dyn PluginStreamBidi<FileChunk, FileChunk>,
    ) -> Result<(), FfiError> {
        Err("not implemented".into())
    }

    fn trigger(&self, _request: TriggerRequest) -> Result<HelloResponse, FfiError> {
        Ok(HelloResponse {
            message: "Trigger called".to_string(),
            from: "rust-plugin".to_string(),
            timestamp: None,
        })
    }

    fn get_goroutines(&self, _request: GoroutinesRequest) -> Result<GoroutinesResponse, FfiError> {
        Ok(GoroutinesResponse {
            count: 1,
            message: "Rust plugin".to_string(),
        })
    }
}

#[ctor::ctor]
fn init_plugin() {
    eprintln!("[Rust Plugin] Initializing... (Refactored)");
    register_go_greeter_service_plugin(RustPlugin::new());
}
