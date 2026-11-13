//! The app trusts only the root list compiled into it (no OS store, no CRLs).
//! A root whose issuing keys became public must not be on that list:
//! RUSTSEC-2026-0381 / -0382 (emSign G3 intermediates with recoverable keys).
//! Audit `deploy-deps:1`, docs/security-review-2026-11.md.

#[test]
fn distrusted_emsign_g3_roots_are_not_trusted() {
    for anchor in webpki_roots::TLS_SERVER_ROOTS {
        let subject = String::from_utf8_lossy(anchor.subject.as_ref());
        assert!(
            !subject.contains("emSign ECC Root CA - G3") && !subject.contains("emSign Root TLS CA - G3"),
            "distrusted root still compiled in: {subject}"
        );
    }
}
