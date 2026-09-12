fn main() {
    println!("cargo:rustc-check-cfg=cfg(static_module)");
    println!("cargo:rerun-if-env-changed=SYNURANG_STATIC_MODULE_DIR");
    if let Ok(directory) = std::env::var("SYNURANG_STATIC_MODULE_DIR") {
        println!("cargo:rustc-link-arg={directory}/c_module.a");
        println!("cargo:rustc-link-lib=pthread");
        println!("cargo:rustc-cfg=static_module");
    }
}
