fn main() {
    println!("cargo:rerun-if-changed=assets/anicat.rc");
    println!("cargo:rerun-if-changed=assets/anicat.ico");
    // The target, not the host: a build script is compiled for the machine
    // running cargo, so `cfg(windows)` here would describe the wrong one.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        embed_resource::compile("assets/anicat.rc", embed_resource::NONE)
            .manifest_optional()
            .unwrap();
    }
}
