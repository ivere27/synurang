include!(concat!(env!("OUT_DIR"), "/synurang.test.rs"));
include!(concat!(env!("OUT_DIR"), "/conformance_ffi.rs"));
use synurang_call::RpcError;
struct Service;
impl CallsService for Service {
    async fn unary(&self, _: Context, request: Value) -> Result<Value> {
        if request.value == -1 { Err(RpcError::new(7, "Error after response")) }
        else { Ok(request) }
    }
    async fn server(&self, _: Context, request: Value, responses: Sender<Value>) -> Result<()> {
        for value in 0..request.value { responses.send(Value { value }).await?; }
        Ok(())
    }
    async fn client(&self, _: Context, mut requests: Receiver<Value>) -> Result<Value> {
        let mut value = 0;
        while let Some(request) = requests.recv().await? {
            if request.value == -2 { return Ok(Value { value: 42 }); }
            value += request.value;
        }
        Ok(Value { value })
    }
    async fn bidi(&self, _: Context, mut requests: Receiver<Value>, responses: Sender<Value>) -> Result<()> {
        while let Some(request) = requests.recv().await? { responses.send(request).await?; }
        Ok(())
    }
    async fn wait(&self, context: Context, _: Value) -> Result<Value> {
        Err(context.cancelled().await)
    }
    async fn fail(&self, _: Context, _: Value) -> Result<Value> {
        Err(RpcError::application(7, 42, "Permission denied by provider"))
    }
}
fn factory() -> Instance {
    let mut instance = Instance::default();
    register_calls(&mut instance, Arc::new(Service)).unwrap();
    instance
}
synurang_call::export_module!(Synurang_GetApi, factory);
