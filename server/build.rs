// Compile-time codegen: `proto/sinhron.proto` → `src/proto/sinhron.v1.rs`.
// The same .proto file feeds the Dart client codegen (when sinhron_net
// lands) so the wire format stays single-source-of-truth.

fn main() {
    println!("cargo:rerun-if-changed=proto/sinhron.proto");
    // Default output is OUT_DIR; we pull in via include!() in src/proto.rs.
    prost_build::compile_protos(&["proto/sinhron.proto"], &["proto/"])
        .expect("failed to compile sinhron.proto");
}
