fn main() {
    // LiteRT-LM FFI linking (only when litert feature is enabled)
    #[cfg(feature = "litert")]
    {
        let target = std::env::var("TARGET").unwrap_or_default();

        // Determine library directory based on target
        let lib_dir = if target.contains("aarch64") && target.contains("android") {
            "lib/android_arm64"
        } else if target.contains("aarch64") && target.contains("linux") {
            "lib/linux_arm64"
        } else if target.contains("x86_64") && target.contains("linux") {
            "lib/linux_x86_64"
        } else {
            // Fallback — user must provide the library in lib/
            "lib"
        };

        println!("cargo:rustc-link-search=native={}", lib_dir);
        println!("cargo:rustc-link-lib=static=engine");
        // LiteRT-LM's C++ engine requires the C++ standard library
        println!("cargo:rustc-link-lib=dylib=c++");
    }
}
