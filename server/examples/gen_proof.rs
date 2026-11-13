// Generate deterministic Ed25519 fixtures for smoke-testing the API.
// Two modes:
//
//   cargo run --example gen_proof -- register [seed_hex]
//     → prints identity_pubkey + registration proof + device_pk + device cred
//       (using seed_hex for identity, seed_hex with bit-flip for device)
//
//   cargo run --example gen_proof -- upload-kp <device_seed_hex> <kp_b64> <ts>
//     → prints upload_proof_hex (Ed25519 sig over canonical msg)
//
//   cargo run --example gen_proof -- action <seed_hex> <domain> <body_hex> <ts>
//     → prints proof_hex: any action proof, e.g. sinhron-group-announce-v1:
//       or sinhron-kp-consume-v1:
//
// NOT used in production — debug helper only. Proofs name the server
// (ADR-086): the first name in SINHRON_PUBLIC_HOSTNAME, default localhost.

use base64::prelude::*;
use ed25519_dalek::{Signer, SigningKey};
use sha2::{Digest, Sha256};

const REGISTRATION_DOMAIN: &[u8] = b"sinhron-register-v1:";
const UPLOAD_KP_DOMAIN: &[u8] = b"sinhron-upload-kp-v1";
const PUT_STATE_BACKUP_DOMAIN: &[u8] = b"sinhron-state-backup-put-v1";

fn main() {
    let mut args = std::env::args().skip(1);
    let mode = args.next().unwrap_or_else(|| "register".to_string());

    match mode.as_str() {
        "register" => {
            let seed_hex = args.next().unwrap_or_else(|| "42".repeat(32));
            let seed = parse_seed(&seed_hex);
            let id_sk = SigningKey::from_bytes(&seed);
            let id_pk = id_sk.verifying_key().to_bytes();

            // Registration proof.
            let mut msg = Vec::new();
            msg.extend_from_slice(REGISTRATION_DOMAIN);
            msg.extend_from_slice(&id_pk);
            let reg_sig = id_sk.sign(&sinhron_server::handlers::proof::bind_to_host(&sinhron_server::handlers::proof::public_hosts()[0], &msg)).to_bytes();

            // Derive a device seed by XOR'ing the identity seed with a
            // domain-tagged mask. Deterministic + distinct from identity.
            let mut device_seed = seed;
            for (i, b) in device_seed.iter_mut().enumerate() {
                *b ^= 0x80 ^ (i as u8);
            }
            let dev_sk = SigningKey::from_bytes(&device_seed);
            let dev_pk = dev_sk.verifying_key().to_bytes();

            println!("identity_pubkey_hex={}", hex::encode(id_pk));
            println!("registration_proof_hex={}", hex::encode(reg_sig));
            println!("device_pk_hex={}", hex::encode(dev_pk));
            println!("device_credential_hex={}", hex::encode(dev_pk));
            println!("device_seed_hex={}", hex::encode(device_seed));
        }
        "upload-kp" => {
            let device_seed_hex = args.next().expect("missing <device_seed_hex>");
            let kp_b64 = args.next().expect("missing <kp_b64>");
            let ts_str = args.next().expect("missing <ts>");
            let ts: i64 = ts_str.parse().expect("ts must be integer");

            let seed = parse_seed(&device_seed_hex);
            let dev_sk = SigningKey::from_bytes(&seed);

            let kp_bytes = BASE64_STANDARD.decode(&kp_b64).expect("kp_b64 must be base64");

            let body_hash = {
                let mut h = Sha256::new();
                h.update(&kp_bytes);
                h.finalize()
            };

            let mut msg = Vec::new();
            msg.extend_from_slice(UPLOAD_KP_DOMAIN);
            msg.push(b':');
            msg.extend_from_slice(&body_hash);
            msg.push(b':');
            msg.extend_from_slice(&ts.to_be_bytes());
            let sig = dev_sk.sign(&sinhron_server::handlers::proof::bind_to_host(&sinhron_server::handlers::proof::public_hosts()[0], &msg)).to_bytes();

            println!("upload_proof_hex={}", hex::encode(sig));
            println!("upload_proof_ts={ts}");
        }
        "action" => {
            let seed = parse_seed(&args.next().expect("missing <seed_hex>"));
            let domain = args.next().expect("missing <domain>");
            let body = hex::decode(args.next().expect("missing <body_hex>")).expect("body must be hex");
            let ts: i64 = args.next().expect("missing <ts>").parse().expect("ts must be integer");
            let mut msg = domain.into_bytes();
            msg.push(b':');
            msg.extend_from_slice(&Sha256::digest(&body));
            msg.push(b':');
            msg.extend_from_slice(&ts.to_be_bytes());
            let msg = sinhron_server::handlers::proof::bind_to_host(&sinhron_server::handlers::proof::public_hosts()[0], &msg);
            println!("proof_hex={}", hex::encode(SigningKey::from_bytes(&seed).sign(&msg).to_bytes()));
        }
        "put-state-backup" => {
            // cargo run --example gen_proof -- put-state-backup
            //   <identity_seed_hex> <blob_b64> <version_seq> <ts>
            let identity_seed_hex = args.next().expect("missing <identity_seed_hex>");
            let blob_b64 = args.next().expect("missing <blob_b64>");
            let version_seq: i64 = args
                .next()
                .expect("missing <version_seq>")
                .parse()
                .expect("version_seq must be integer");
            let ts: i64 = args
                .next()
                .expect("missing <ts>")
                .parse()
                .expect("ts must be integer");

            let seed = parse_seed(&identity_seed_hex);
            let id_sk = SigningKey::from_bytes(&seed);

            let blob = BASE64_STANDARD.decode(&blob_b64).expect("blob_b64 must be base64");

            // signed body = blob || be8(version_seq)
            let mut signed_body = Vec::with_capacity(blob.len() + 8);
            signed_body.extend_from_slice(&blob);
            signed_body.extend_from_slice(&version_seq.to_be_bytes());

            let body_hash = {
                let mut h = Sha256::new();
                h.update(&signed_body);
                h.finalize()
            };

            let mut msg = Vec::new();
            msg.extend_from_slice(PUT_STATE_BACKUP_DOMAIN);
            msg.push(b':');
            msg.extend_from_slice(&body_hash);
            msg.push(b':');
            msg.extend_from_slice(&ts.to_be_bytes());
            let sig = id_sk.sign(&sinhron_server::handlers::proof::bind_to_host(&sinhron_server::handlers::proof::public_hosts()[0], &msg)).to_bytes();

            println!("put_proof_hex={}", hex::encode(sig));
            println!("put_proof_ts={ts}");
            println!("version_seq={version_seq}");
        }
        other => {
            eprintln!(
                "unknown mode: {other}. Try 'register', 'upload-kp', or 'put-state-backup'."
            );
            std::process::exit(2);
        }
    }
}

fn parse_seed(seed_hex: &str) -> [u8; 32] {
    let bytes = hex::decode(seed_hex).expect("seed must be hex");
    bytes.try_into().expect("seed must be 32 bytes")
}
