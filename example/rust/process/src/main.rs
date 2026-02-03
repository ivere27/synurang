use tonic::{transport::Server, Request, Response, Status, Streaming};
use synurang_service::example::v1::go_greeter_service_server::{GoGreeterService, GoGreeterServiceServer};
use synurang_service::example::v1::{HelloRequest, HelloResponse, DownloadFileRequest, FileChunk, FileStatus, TriggerRequest, GoroutinesRequest, GoroutinesResponse};
use synurang_service::GreeterLogic;
use std::os::unix::io::FromRawFd;
use std::pin::Pin;
use tokio::sync::mpsc;
use tokio_stream::StreamExt;

pub struct MyGreeter {
    logic: GreeterLogic,
}

impl Default for MyGreeter {
    fn default() -> Self {
        Self {
            logic: GreeterLogic::new("rust-process"),
        }
    }
}

#[tonic::async_trait]
impl GoGreeterService for MyGreeter {
    type BarServerStreamStream = Pin<Box<dyn tokio_stream::Stream<Item = Result<HelloResponse, Status>> + Send>>;
    type BarBidiStreamStream = Pin<Box<dyn tokio_stream::Stream<Item = Result<HelloResponse, Status>> + Send>>;
    type DownloadFileStream = Pin<Box<dyn tokio_stream::Stream<Item = Result<FileChunk, Status>> + Send>>;
    type BidiFileStream = Pin<Box<dyn tokio_stream::Stream<Item = Result<FileChunk, Status>> + Send>>;

    async fn bar(&self, request: Request<HelloRequest>) -> Result<Response<HelloResponse>, Status> {
        let req = request.into_inner();
        let (msg, from) = self.logic.bar(&req.name);
        Ok(Response::new(HelloResponse {
            message: msg,
            from,
            timestamp: None,
        }))
    }

    async fn bar_server_stream(
        &self,
        request: Request<HelloRequest>,
    ) -> Result<Response<Self::BarServerStreamStream>, Status> {
        let req = request.into_inner();
        let (tx, rx) = mpsc::channel(4);
        let name = req.name.clone();
        let source = self.logic.source.clone();

        // Spawn a blocking task for the synchronous streaming logic
        tokio::task::spawn_blocking(move || {
            let logic = GreeterLogic::new(&source);
            logic.bar_server_stream(&name, |msg, from| {
                let resp = HelloResponse {
                    message: msg,
                    from,
                    timestamp: None,
                };
                // blocking_send is OK inside spawn_blocking
                tx.blocking_send(Ok(resp)).is_ok()
            });
        });

        Ok(Response::new(Box::pin(tokio_stream::wrappers::ReceiverStream::new(rx))))
    }

    async fn bar_client_stream(
        &self,
        request: Request<Streaming<HelloRequest>>,
    ) -> Result<Response<HelloResponse>, Status> {
        let mut stream = request.into_inner();
        let mut requests = Vec::new();

        while let Some(req) = stream.next().await {
            match req {
                Ok(r) => requests.push(r.name),
                Err(e) => return Err(e),
            }
        }

        let (msg, from) = self.logic.bar_client_stream(requests.into_iter());
        Ok(Response::new(HelloResponse {
            message: msg,
            from,
            timestamp: None,
        }))
    }

    async fn bar_bidi_stream(
        &self,
        request: Request<Streaming<HelloRequest>>,
    ) -> Result<Response<Self::BarBidiStreamStream>, Status> {
        let mut stream = request.into_inner();
        let (tx, rx) = mpsc::channel(4);

        let source = self.logic.source.clone();
        tokio::spawn(async move {
            let logic = GreeterLogic::new(&source);
            while let Some(req_result) = stream.next().await {
                 match req_result {
                     Ok(req) => {
                         // Call logic and send response immediately (no callback)
                         let (msg, from) = logic.bar_bidi_single(&req.name);
                         let resp = HelloResponse {
                             message: msg,
                             from,
                             timestamp: None,
                         };
                         if tx.send(Ok(resp)).await.is_err() {
                             break; // Receiver dropped
                         }
                     },
                     Err(_) => break, // Stream error
                 }
            }
        });

        Ok(Response::new(Box::pin(tokio_stream::wrappers::ReceiverStream::new(rx))))
    }

    // Unimplemented methods
    async fn upload_file(&self, _req: Request<Streaming<FileChunk>>) -> Result<Response<FileStatus>, Status> {
        Err(Status::unimplemented("Not implemented"))
    }
    async fn download_file(&self, _req: Request<DownloadFileRequest>) -> Result<Response<Self::DownloadFileStream>, Status> {
        Err(Status::unimplemented("Not implemented"))
    }
    async fn bidi_file(&self, _req: Request<Streaming<FileChunk>>) -> Result<Response<Self::BidiFileStream>, Status> {
        Err(Status::unimplemented("Not implemented"))
    }
    async fn trigger(&self, _req: Request<TriggerRequest>) -> Result<Response<HelloResponse>, Status> {
        Err(Status::unimplemented("Not implemented"))
    }
    async fn get_goroutines(&self, _req: Request<GoroutinesRequest>) -> Result<Response<GoroutinesResponse>, Status> {
         Err(Status::unimplemented("Not implemented"))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("Rust process child starting...");
    let fd_str = std::env::var("SYNURANG_IPC").map_err(|_| "SYNURANG_IPC arg required")?;
    eprintln!("Rust process child using FD: {}", fd_str);
    let fd: i32 = fd_str.parse()?;
    
    // Create stream from inherited FD (it's a socketpair endpoint, not a listener)
    // SAFETY: We assume the FD provided by SYNURANG_IPC is valid and owned by us
    let stream = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    stream.set_nonblocking(true)?;
    let tokio_stream = tokio::net::UnixStream::from_std(stream)?;
    
    // Custom stream that yields the connection once, then hangs (Pending)
    // This prevents serve_with_incoming from exiting, which would kill the active connection
    struct SingleConnectionStream {
        stream: Option<tokio::net::UnixStream>,
    }

    impl tokio_stream::Stream for SingleConnectionStream {
        type Item = Result<tokio::net::UnixStream, std::io::Error>;

        fn poll_next(
            mut self: Pin<&mut Self>,
            _cx: &mut std::task::Context<'_>,
        ) -> std::task::Poll<Option<Self::Item>> {
            if let Some(stream) = self.stream.take() {
                eprintln!("Rust child: Yielding connection to Tonic");
                std::task::Poll::Ready(Some(Ok(stream)))
            } else {
                // Keep the server alive by never returning None
                std::task::Poll::Pending
            }
        }
    }

    let incoming = SingleConnectionStream { stream: Some(tokio_stream) };

    eprintln!("Rust process child serving on FD {}", fd);

    let (mut health_reporter, health_service) = tonic_health::server::health_reporter();
    // Mark our service as serving
    health_reporter.set_serving::<GoGreeterServiceServer<MyGreeter>>().await;

    Server::builder()
        .add_service(health_service)
        .add_service(GoGreeterServiceServer::new(MyGreeter::default()))
        .serve_with_incoming(incoming)
        .await?;

    Ok(())
}
