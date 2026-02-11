fn main() {
    prost_build::compile_protos(&["../api/media.proto"], &["../api/"]).unwrap();
}
