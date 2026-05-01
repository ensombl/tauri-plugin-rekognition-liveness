fn main() {
    // Google Play enforces 16 KB-aligned native libs for new submissions from
    // 2025-11-01. .cargo/config.toml does not reliably propagate through
    // Tauri's android build, so emit the linker flags from build.rs of the
    // crate that owns the cdylib. Applies uniformly to all four Android
    // targets (aarch64, armv7, x86_64, i686).
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        println!("cargo:rustc-link-arg=-Wl,-z,max-page-size=16384");
        println!("cargo:rustc-link-arg=-Wl,-z,common-page-size=16384");
    }

    tauri_build::build();
}
