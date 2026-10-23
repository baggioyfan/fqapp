fn main() {
    // Desktop hosts link the C crypto core straight into the Rust library.
    // Android builds the same sources as its own .so through
    // native/CMakeLists.txt (with the JNI bridge), so nothing is compiled here.
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os != "windows" && target_os != "macos" {
        return;
    }
    let sources = [
        "crypto_core/sp_error.c",
        "crypto_core/sp_stream.c",
        "crypto_core/mp4_cenc.c",
        "crypto_core/sp_aes.c",
        "third_party/tiny_aes/aes.c",
    ];
    let mut build = cc::Build::new();
    build
        .include("../native/crypto_core")
        .std("c11")
        .flag_if_supported("/experimental:c11atomics")
        .define("CBC", "0")
        .define("CTR", "0")
        .define("ECB", "1");
    for source in sources {
        let path = format!("../native/{source}");
        println!("cargo:rerun-if-changed={path}");
        build.file(path);
    }
    println!("cargo:rerun-if-changed=../native/crypto_core/sp_crypto.h");
    build.compile("sp_crypto_core");
}
