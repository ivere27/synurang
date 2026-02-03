use synurang_service::example::v1::*;
use synurang_service::GreeterLogic;

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
}

impl GoGreeterServicePlugin for RustPlugin {
    fn bar(&self, request: HelloRequest) -> Result<HelloResponse, String> {
        let (msg, from) = self.logic.bar(&request.name);
        Ok(HelloResponse { message: msg, from, timestamp: None })
    }

    fn bar_server_stream(&self, request: HelloRequest, stream: &dyn PluginStreamSender<HelloResponse>) -> Result<(), String> {
        self.logic.bar_server_stream(&request.name, |msg, from| {
            let resp = HelloResponse { message: msg, from, timestamp: None };
            stream.send(resp)
        });
        Ok(())
    }

    fn bar_client_stream(&self, stream: &dyn PluginStreamReceiver<HelloRequest>) -> Result<HelloResponse, String> {
        let mut requests = Vec::new();
        while let Some(req) = stream.recv() {
            requests.push(req.name);
        }
        let (msg, from) = self.logic.bar_client_stream(requests.into_iter());
        Ok(HelloResponse { message: msg, from, timestamp: None })
    }

    fn bar_bidi_stream(&self, stream: &dyn PluginStreamBidi<HelloRequest, HelloResponse>) -> Result<(), String> {
        // Since logic.bar_bidi_stream expects a callback, we can't easily map it 1:1 if the logic loop pulls.
        // Wait, logic.bar_bidi_stream takes a name and a sender callback?
        // Let's check logic.bar_bidi_stream in service/lib.rs
        // It says: pub fn bar_bidi_stream<F>(&self, name: &str, mut send: F) -> bool
        // This seems to handle ONE request?
        // Service implementation says:
        /*
        pub fn bar_bidi_stream<F>(&self, name: &str, mut send: F) -> bool {
            eprintln!("[{}] BarBidiStream received: {}", self.source, name);
            let msg = format!("Echo: {}", name);
            send(msg, self.source.clone())
        }
        */
        // It processes ONE message.
        // The PluginStreamBidi provides a loop or we must loop?
        // The generated code for bidi (Step 11): 
        // fn bar_bidi_stream(&self, stream: &dyn PluginStreamBidi<HelloRequest, HelloResponse>)
        // We probably need to loop here.
        
        while let Some(req) = stream.recv() {
             self.logic.bar_bidi_stream(&req.name, |msg, from| {
                 let resp = HelloResponse { message: msg, from, timestamp: None };
                 stream.send(resp)
             });
        }
        Ok(())
    }

    fn upload_file(&self, _stream: &dyn PluginStreamReceiver<FileChunk>) -> Result<FileStatus, String> {
        Err("not implemented".to_string())
    }

    fn download_file(&self, _request: DownloadFileRequest, _stream: &dyn PluginStreamSender<FileChunk>) -> Result<(), String> {
        Err("not implemented".to_string())
    }

    fn bidi_file(&self, _stream: &dyn PluginStreamBidi<FileChunk, FileChunk>) -> Result<(), String> {
        Err("not implemented".to_string())
    }

    fn trigger(&self, _request: TriggerRequest) -> Result<HelloResponse, String> {
         // Logic doesn't have trigger?
         // In original lib.rs:
         /*
         "/example.v1.GoGreeterService/Trigger" => {
            let resp = proto::HelloResponse {
                message: "Trigger called".to_string(),
                from: "rust-plugin".to_string(),
            };
         */
         Ok(HelloResponse {
             message: "Trigger called".to_string(),
             from: "rust-plugin".to_string(),
             timestamp: None,
         })
    }

    fn get_goroutines(&self, _request: GoroutinesRequest) -> Result<GoroutinesResponse, String> {
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
