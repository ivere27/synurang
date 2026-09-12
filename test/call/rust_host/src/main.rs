use futures_util::{stream, StreamExt};
use prost::Message;
use std::{future::Future, path::Path, time::Duration};
use synurang_host::{
    CancellationToken, ModuleCallOptions, ModuleHost, ModuleMethod, ModuleOptions, RpcError,
    RpcResult,
};

#[derive(Clone, PartialEq, Message)]
struct Value {
    #[prost(int32, tag = "1")]
    value: i32,
}
fn value(value: i32) -> Vec<u8> {
    Value { value }.encode_to_vec()
}
fn number(bytes: &[u8]) -> i32 {
    Value::decode(bytes).unwrap().value
}
fn path(method: &str) -> String {
    format!("/synurang.test.Calls/{method}")
}
fn options() -> ModuleOptions {
    ModuleOptions {
        capacity: 2,
        command_capacity: 4,
        ..Default::default()
    }
}
async fn fails<T>(future: impl Future<Output = RpcResult<T>>, code: i32) -> RpcError {
    match future.await {
        Err(error) => {
            assert_eq!(error.code, code, "{error}");
            error
        }
        Ok(_) => panic!("Expected RPC code {code}"),
    }
}

async fn conformance(create: impl Fn() -> RpcResult<ModuleHost>) -> RpcResult<()> {
    let host = create()?;
    let other = create()?;
    let result = async {
        assert_eq!(
            number(
                &host
                    .unary(path("Unary"), &value(0), Default::default())
                    .await?
            ),
            0
        );
        assert_eq!(
            number(
                &host
                    .unary(path("Unary"), &value(42), Default::default())
                    .await?
            ),
            42
        );
        let server = host
            .server_stream(path("Server"), &value(50), Default::default())
            .await?
            .responses();
        futures_util::pin_mut!(server);
        let mut count = 0;
        while let Some(response) = server.next().await {
            assert_eq!(number(&response?), count);
            count += 1;
        }
        assert_eq!(count, 50);
        let sum = host
            .client_stream(
                path("Client"),
                stream::iter((0..50).map(value)),
                Default::default(),
            )
            .await?;
        assert_eq!(number(&sum), 1225);
        let early = host
            .client_stream(
                path("Client"),
                stream::iter(std::iter::once(value(-2)).chain((0..100).map(value))),
                Default::default(),
            )
            .await?;
        assert_eq!(number(&early), 42);
        let stalled = stream::once(async { value(-2) }).chain(stream::pending());
        let early = tokio::time::timeout(
            Duration::from_secs(2),
            host.client_stream(path("Client"), stalled, Default::default()),
        )
        .await
        .expect("Early response waited for an unfinished request source")?;
        assert_eq!(number(&early), 42);
        let bidi = host.bidi(path("Bidi"), Default::default()).await?;
        for n in 0..30 {
            bidi.send(&value(n)).await?;
            assert_eq!(number(&bidi.recv().await?.unwrap()), n);
        }
        bidi.half_close().await?;
        assert!(bidi.recv().await?.is_none());
        bidi.close().await;
        let futures = (0..25).map(|n| {
            let host = host.clone();
            async move {
                let response = host
                    .unary(path("Unary"), &value(n), Default::default())
                    .await?;
                assert_eq!(number(&response), n);
                RpcResult::Ok(())
            }
        });
        for result in futures_util::future::join_all(futures).await {
            result?;
        }
        assert_eq!(
            number(
                &other
                    .unary(path("Unary"), &value(123), Default::default())
                    .await?
            ),
            123
        );
        let error = fails(host.unary(path("Fail"), &value(0), Default::default()), 7).await;
        assert!(!error.details.is_empty());
        fails(host.unary(path("Unary"), &value(-1), Default::default()), 7).await;
        let unknown = host
            .open(
                ModuleMethod::new("/unknown.Service/Method", false, false),
                Default::default(),
            )
            .await?;
        fails(unknown.recv(), 12).await;
        unknown.close().await;
        fails(
            host.unary("/unknown.Service/Method", &value(0), Default::default()),
            12,
        )
        .await;
        let preserving = host
            .server_stream(path("Server"), &value(100), Default::default())
            .await?;
        assert_eq!(number(&preserving.recv().await?.unwrap()), 0);
        assert!(preserving
            .send(&value(1))
            .await
            .unwrap_err()
            .is_request_closed());
        for n in 1..100 {
            assert_eq!(number(&preserving.recv().await?.unwrap()), n);
        }
        assert!(preserving.recv().await?.is_none());
        preserving.close().await;
        let cancellation = CancellationToken::new();
        let token = cancellation.clone();
        let cancelling = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            token.cancel();
        });
        fails(
            host.unary(
                path("Wait"),
                &value(0),
                ModuleCallOptions {
                    cancellation: Some(cancellation.clone()),
                    ..Default::default()
                },
            ),
            1,
        )
        .await;
        cancelling.await.unwrap();
        fails(
            host.unary(
                path("Wait"),
                &value(0),
                ModuleCallOptions {
                    timeout: Some(Duration::from_millis(20)),
                    ..Default::default()
                },
            ),
            4,
        )
        .await;
        fails(
            host.unary(
                path("Wait"),
                &value(0),
                ModuleCallOptions {
                    timeout: Some(Duration::ZERO),
                    ..Default::default()
                },
            ),
            4,
        )
        .await;
        fails(
            host.unary(
                path("Wait"),
                &value(0),
                ModuleCallOptions {
                    cancellation: Some(cancellation),
                    ..Default::default()
                },
            ),
            1,
        )
        .await;
        // Dropping an iterator releases a producer blocked on its bounded queue.
        {
            let responses = host
                .server_stream(path("Server"), &value(10000), Default::default())
                .await?
                .responses();
            futures_util::pin_mut!(responses);
            assert_eq!(number(&responses.next().await.unwrap()?), 0);
        }
        // Concurrent send and receive on one call; request queue is capacity 2.
        let duplex = host.bidi(path("Bidi"), Default::default()).await?;
        let sending = duplex.clone();
        let (acknowledge, mut received) = tokio::sync::mpsc::channel(1);
        let producer = tokio::spawn(async move {
            for n in 0..30 {
                sending.send(&value(n)).await?;
                // The fixture's C echo rejects outbound queue overflow. The
                // two tasks still await send/receive concurrently without
                // depending on scheduler timing or buffering beyond capacity.
                received.recv().await.expect("Consumer stopped early");
            }
            sending.half_close().await
        });
        let mut count = 0;
        while let Some(bytes) = duplex.recv().await? {
            assert_eq!(number(&bytes), count);
            count += 1;
            acknowledge.send(()).await.unwrap();
        }
        assert_eq!(count, 30);
        producer.await.unwrap()?;
        duplex.close().await;
        let pending_host = host.clone();
        let pending = tokio::spawn(async move {
            fails(
                pending_host.unary(path("Wait"), &value(0), Default::default()),
                1,
            )
            .await
        });
        tokio::time::sleep(Duration::from_millis(5)).await;
        let (first, second) = tokio::join!(host.close(), host.close());
        first?;
        second?;
        pending.await.unwrap();
        fails(host.unary(path("Unary"), &value(0), Default::default()), 14).await;
        assert_eq!(
            number(
                &other
                    .unary(path("Unary"), &value(9), Default::default())
                    .await?
            ),
            9
        );
        Ok(())
    }
    .await;
    host.close().await?;
    other.close().await?;
    result
}

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> RpcResult<()> {
    let directory = std::env::args()
        .nth(1)
        .expect("Usage: rust-host-conformance MODULE_DIRECTORY");
    for provider in ["c", "cpp", "rust", "go"] {
        let path = Path::new(&directory).join(format!("{provider}_module.so"));
        tokio::time::timeout(
            Duration::from_secs(30),
            conformance(|| ModuleHost::load(&path, options())),
        )
        .await
        .expect("Rust host conformance timed out")?;
        println!("Rust host {provider} conformance passed");
    }
    #[cfg(static_module)]
    {
        extern "C" {
            fn Synurang_GetApi() -> *const synurang_host::module::abi::Api;
        }
        conformance(|| unsafe { ModuleHost::from_static_api(Synurang_GetApi(), options()) })
            .await?;
        println!("Rust host statically linked C conformance passed");
    }
    Ok(())
}
