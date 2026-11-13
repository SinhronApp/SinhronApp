// Compile-time codegen for the WS wire protocol.
//
// proto/sinhron.proto MUST stay in sync with server/proto/sinhron.proto
// — they describe the same wire format. A future WU may move this into
// a shared `sinhron_proto` crate that both server & client depend on;
// until then, the .proto is copied at sinhron_net crate-creation time
// (see WU B1) and updated by hand whenever the server's schema changes.

fn main() {
    println!("cargo:rerun-if-changed=proto/sinhron.proto");

    // Xcode invokes cargokit build scripts with a minimal PATH that may not
    // include `/opt/homebrew/bin` (where `brew install protobuf` puts protoc).
    // If PROTOC isn't already set, probe common install locations so the
    // build works both from a normal shell AND from Xcode-driven builds.
    if std::env::var_os("PROTOC").is_none() {
        for candidate in &[
            "/opt/homebrew/bin/protoc",      // Apple Silicon Homebrew
            "/usr/local/bin/protoc",          // Intel Homebrew + /usr/local installs
            "/opt/local/bin/protoc",          // MacPorts
            "/usr/bin/protoc",                // System / Linux distros
        ] {
            if std::path::Path::new(candidate).exists() {
                println!("cargo:warning=PROTOC not set; using {}", candidate);
                std::env::set_var("PROTOC", candidate);
                break;
            }
        }
    }

    prost_build::compile_protos(&["proto/sinhron.proto"], &["proto/"])
        .expect("failed to compile sinhron.proto — ensure `protoc` is installed (brew install protobuf)");
}
