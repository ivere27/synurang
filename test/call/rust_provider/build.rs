fn main() {
    prost_build::compile_protos(&["../conformance.proto"], &[".."]).unwrap();
    let generator = std::env::var("SYNURANG_GENERATOR").expect("SYNURANG_GENERATOR must point to the built protoc plugin");
    let output = std::env::var("OUT_DIR").unwrap();
    let status = std::process::Command::new("protoc")
        .args(["-I..", "../conformance.proto"])
        .arg(format!("--plugin=protoc-gen-synurang-ffi={generator}"))
        .arg(format!("--synurang-ffi_out=lang=rust,mode=module:{output}"))
        .status().unwrap();
    assert!(status.success());
    println!("cargo:rerun-if-changed=../conformance.proto");
    println!("cargo:rerun-if-env-changed=SYNURANG_GENERATOR");
    println!("cargo:rerun-if-changed={generator}");
}
