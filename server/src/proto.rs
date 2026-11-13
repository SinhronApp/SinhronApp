// Generated Protobuf types — wraps the prost-build output. The generated
// file lives in `$OUT_DIR/sinhron.v1.rs`; we re-export the module here
// so callers say `crate::proto::WsFrame` instead of leaking the prost
// package name into module paths.

pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/sinhron.v1.rs"));
}

pub use v1::*;
