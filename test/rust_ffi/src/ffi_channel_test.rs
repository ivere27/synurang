// FfiChannel Test Suite
//
// Tests the generated FfiChannel implementation that allows using standard
// gRPC clients over FFI transport in Rust.
//
// To run: cargo test

use std::collections::HashMap;
use std::sync::Arc;

// =============================================================================
// Mock Protobuf Messages (simplified for testing without full prost)
// =============================================================================

pub trait Message: Default {
    fn encode(&self, buf: &mut Vec<u8>) -> Result<(), String>;
    fn decode(buf: &[u8]) -> Result<Self, String>
    where
        Self: Sized;
}

#[derive(Default, Clone)]
pub struct Empty;

impl Message for Empty {
    fn encode(&self, _buf: &mut Vec<u8>) -> Result<(), String> {
        Ok(())
    }

    fn decode(_buf: &[u8]) -> Result<Self, String> {
        Ok(Empty)
    }
}

#[derive(Default, Clone, Debug)]
pub struct PingResponse {
    pub message: String,
}

impl Message for PingResponse {
    fn encode(&self, buf: &mut Vec<u8>) -> Result<(), String> {
        buf.extend_from_slice(format!("ping:{}", self.message).as_bytes());
        Ok(())
    }

    fn decode(buf: &[u8]) -> Result<Self, String> {
        let s = String::from_utf8_lossy(buf);
        if let Some(msg) = s.strip_prefix("ping:") {
            Ok(PingResponse {
                message: msg.to_string(),
            })
        } else {
            Err("Invalid format".to_string())
        }
    }
}

#[derive(Default, Clone)]
pub struct GetCacheRequest {
    pub store_name: String,
    pub key: String,
}

impl Message for GetCacheRequest {
    fn encode(&self, buf: &mut Vec<u8>) -> Result<(), String> {
        buf.extend_from_slice(format!("get:{}:{}", self.store_name, self.key).as_bytes());
        Ok(())
    }

    fn decode(buf: &[u8]) -> Result<Self, String> {
        let s = String::from_utf8_lossy(buf);
        if let Some(rest) = s.strip_prefix("get:") {
            let parts: Vec<&str> = rest.splitn(2, ':').collect();
            if parts.len() == 2 {
                return Ok(GetCacheRequest {
                    store_name: parts[0].to_string(),
                    key: parts[1].to_string(),
                });
            }
        }
        Err("Invalid format".to_string())
    }
}

#[derive(Default, Clone)]
pub struct GetCacheResponse {
    pub value: String,
}

impl Message for GetCacheResponse {
    fn encode(&self, buf: &mut Vec<u8>) -> Result<(), String> {
        buf.extend_from_slice(format!("resp:{}", self.value).as_bytes());
        Ok(())
    }

    fn decode(buf: &[u8]) -> Result<Self, String> {
        let s = String::from_utf8_lossy(buf);
        if let Some(val) = s.strip_prefix("resp:") {
            Ok(GetCacheResponse {
                value: val.to_string(),
            })
        } else {
            Err("Invalid format".to_string())
        }
    }
}

// =============================================================================
// Mock FfiServer Trait and Implementation
// =============================================================================

pub trait FfiServer: Send + Sync {
    fn ping(&self, request: Empty) -> Result<PingResponse, String>;
    fn get(&self, request: GetCacheRequest) -> Result<GetCacheResponse, String>;
}

pub struct MockFfiServer {
    pub ping_count: std::sync::atomic::AtomicUsize,
    pub get_count: std::sync::atomic::AtomicUsize,
    pub cache_data: std::sync::RwLock<HashMap<String, String>>,
}

impl MockFfiServer {
    pub fn new() -> Self {
        MockFfiServer {
            ping_count: std::sync::atomic::AtomicUsize::new(0),
            get_count: std::sync::atomic::AtomicUsize::new(0),
            cache_data: std::sync::RwLock::new(HashMap::new()),
        }
    }

    pub fn set_cache(&self, key: &str, value: &str) {
        self.cache_data
            .write()
            .unwrap()
            .insert(key.to_string(), value.to_string());
    }
}

impl FfiServer for MockFfiServer {
    fn ping(&self, _request: Empty) -> Result<PingResponse, String> {
        self.ping_count
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Ok(PingResponse {
            message: "pong".to_string(),
        })
    }

    fn get(&self, request: GetCacheRequest) -> Result<GetCacheResponse, String> {
        self.get_count
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let cache = self.cache_data.read().unwrap();
        let value = cache.get(&request.key).cloned().unwrap_or_default();
        Ok(GetCacheResponse { value })
    }
}

// =============================================================================
// Mock Invoke Function (simulates generated invoke)
// =============================================================================

pub fn invoke<S: FfiServer>(server: &S, method: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    match method {
        "/core.v1.HealthService/Ping" => {
            let request = Empty::decode(data)?;
            let response = server.ping(request)?;
            let mut buf = Vec::new();
            response.encode(&mut buf)?;
            Ok(buf)
        }
        "/core.v1.CacheService/Get" => {
            let request = GetCacheRequest::decode(data)?;
            let response = server.get(request)?;
            let mut buf = Vec::new();
            response.encode(&mut buf)?;
            Ok(buf)
        }
        _ => Err(format!("unknown method: {}", method)),
    }
}

// =============================================================================
// Mock FfiChannel (simulates generated FfiChannel)
// =============================================================================

pub struct FfiChannel<S: FfiServer> {
    server: Arc<S>,
}

impl<S: FfiServer> FfiChannel<S> {
    pub fn new(server: Arc<S>) -> Self {
        FfiChannel { server }
    }

    pub fn invoke<Req: Message, Resp: Message>(
        &self,
        method: &str,
        request: &Req,
    ) -> Result<Resp, String> {
        let mut data = Vec::new();
        request.encode(&mut data)?;
        let result = invoke(&*self.server, method, &data)?;
        Resp::decode(&result)
    }
}

// =============================================================================
// Mock Typed Clients (simulates generated clients)
// =============================================================================

pub struct HealthServiceFfiClient<S: FfiServer> {
    channel: FfiChannel<S>,
}

impl<S: FfiServer> HealthServiceFfiClient<S> {
    pub fn new(server: Arc<S>) -> Self {
        HealthServiceFfiClient {
            channel: FfiChannel::new(server),
        }
    }

    pub fn ping(&self, request: &Empty) -> Result<PingResponse, String> {
        self.channel.invoke("/core.v1.HealthService/Ping", request)
    }
}

pub struct CacheServiceFfiClient<S: FfiServer> {
    channel: FfiChannel<S>,
}

impl<S: FfiServer> CacheServiceFfiClient<S> {
    pub fn new(server: Arc<S>) -> Self {
        CacheServiceFfiClient {
            channel: FfiChannel::new(server),
        }
    }

    pub fn get(&self, request: &GetCacheRequest) -> Result<GetCacheResponse, String> {
        self.channel.invoke("/core.v1.CacheService/Get", request)
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ping() {
        let server = Arc::new(MockFfiServer::new());
        let client = HealthServiceFfiClient::new(server.clone());

        let response = client.ping(&Empty).unwrap();

        assert_eq!(response.message, "pong");
        assert_eq!(
            server.ping_count.load(std::sync::atomic::Ordering::SeqCst),
            1
        );
    }

    #[test]
    fn test_get_cache() {
        let server = Arc::new(MockFfiServer::new());
        server.set_cache("test-key", "test-value");

        let client = CacheServiceFfiClient::new(server.clone());
        let request = GetCacheRequest {
            store_name: "default".to_string(),
            key: "test-key".to_string(),
        };

        let response = client.get(&request).unwrap();

        assert_eq!(response.value, "test-value");
        assert_eq!(
            server.get_count.load(std::sync::atomic::Ordering::SeqCst),
            1
        );
    }

    #[test]
    fn test_get_cache_not_found() {
        let server = Arc::new(MockFfiServer::new());
        let client = CacheServiceFfiClient::new(server.clone());

        let request = GetCacheRequest {
            store_name: "default".to_string(),
            key: "non-existent".to_string(),
        };

        let response = client.get(&request).unwrap();
        assert!(response.value.is_empty());
    }

    #[test]
    fn test_multiple_pings() {
        let server = Arc::new(MockFfiServer::new());
        let client = HealthServiceFfiClient::new(server.clone());

        for _ in 0..100 {
            let response = client.ping(&Empty).unwrap();
            assert_eq!(response.message, "pong");
        }

        assert_eq!(
            server.ping_count.load(std::sync::atomic::Ordering::SeqCst),
            100
        );
    }

    #[test]
    fn test_concurrent_access() {
        use std::thread;

        let server = Arc::new(MockFfiServer::new());
        let mut handles = vec![];

        for _ in 0..10 {
            let server_clone = server.clone();
            let handle = thread::spawn(move || {
                let client = HealthServiceFfiClient::new(server_clone);
                for _ in 0..10 {
                    let _ = client.ping(&Empty).unwrap();
                }
            });
            handles.push(handle);
        }

        for handle in handles {
            handle.join().unwrap();
        }

        assert_eq!(
            server.ping_count.load(std::sync::atomic::Ordering::SeqCst),
            100
        );
    }

    #[test]
    fn test_channel_direct_invoke() {
        let server = Arc::new(MockFfiServer::new());
        let channel = FfiChannel::new(server.clone());

        let response: PingResponse = channel
            .invoke("/core.v1.HealthService/Ping", &Empty)
            .unwrap();

        assert_eq!(response.message, "pong");
    }

    #[test]
    fn test_unknown_method() {
        let server = Arc::new(MockFfiServer::new());
        let channel = FfiChannel::new(server);

        let result: Result<PingResponse, String> =
            channel.invoke("/unknown.Service/Method", &Empty);

        assert!(result.is_err());
        assert!(result.unwrap_err().contains("unknown method"));
    }
}
