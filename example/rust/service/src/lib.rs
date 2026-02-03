//! Shared Rust greeter service logic
//! Used by both plugin and process modes

pub mod example {
    pub mod v1 {
        tonic::include_proto!("example.v1");
    }
}

pub mod core {
    pub mod v1 {
        tonic::include_proto!("core.v1");
    }
}

/// Greeter service logic with configurable source identifier
pub struct GreeterLogic {
    pub source: String,
}

impl GreeterLogic {
    pub fn new(source: impl Into<String>) -> Self {
        Self { source: source.into() }
    }

    /// Unary RPC logic
    pub fn bar(&self, name: &str) -> (String, String) {
        eprintln!("[{}] Bar: {}", self.source, name);
        (format!("Hello {}!", name), self.source.clone())
    }

    /// Server streaming RPC logic - generates N responses
    pub fn bar_server_stream<F>(&self, name: &str, mut send: F)
    where
        F: FnMut(String, String) -> bool,
    {
        eprintln!("[{}] BarServerStream: {}", self.source, name);
        for i in 0..3 {
            let msg = format!("Hello {} #{}", name, i + 1);
            if !send(msg, self.source.clone()) {
                break;
            }
        }
    }

    /// Client streaming RPC logic - collects and summarizes
    pub fn bar_client_stream<I>(&self, requests: I) -> (String, String)
    where
        I: Iterator<Item = String>,
    {
        eprintln!("[{}] BarClientStream started", self.source);
        let mut count = 0;
        for name in requests {
            eprintln!("[{}] BarClientStream received: {}", self.source, name);
            count += 1;
        }
        (format!("Received {} messages", count), self.source.clone())
    }

    /// Bidi streaming RPC logic - echoes each request
    pub fn bar_bidi_stream<F>(&self, name: &str, mut send: F) -> bool
    where
        F: FnMut(String, String) -> bool,
    {
        eprintln!("[{}] BarBidiStream received: {}", self.source, name);
        let msg = format!("Echo: {}", name);
        send(msg, self.source.clone())
    }

    /// Bidi streaming RPC logic - single message variant (returns directly, for async use)
    pub fn bar_bidi_single(&self, name: &str) -> (String, String) {
        eprintln!("[{}] BarBidiStream received: {}", self.source, name);
        (format!("Echo: {}", name), self.source.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bar() {
        let logic = GreeterLogic::new("test");
        let (msg, from) = logic.bar("World");
        assert_eq!(msg, "Hello World!");
        assert_eq!(from, "test");
    }
}
