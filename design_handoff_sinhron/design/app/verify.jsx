// verify.jsx — Safety number compare
// The ONE screen in Sinhron that puts E2EE front-and-centre — for users who
// dig deep enough to verify identity with a contact. Per tech spec: identity
// = Ed25519 + Basic MLS credential; the safety number is the hex digest of
// both parties' public keys, formatted as 60 digits in groups of 5.
// Exports: SnSafetyNumber

function SnSafetyNumber({ dark = false, platform = 'ios', verified = false }) {
  // Stable mock — 60 digits, 12 groups of 5.
  const NUMBERS = [
    '21438', '07912', '58604', '33179',
    '42058', '91635', '70283', '14906',
    '85371', '26840', '59712', '07435',
  ];
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* Header */}
      <div style={{
        display: 'flex', alignItems: 'center',
        padding: '8px 14px 10px',
        borderBottom: '0.5px solid var(--sn-divider)',
      }}>
        <button style={{
          width: 32, height: 32, borderRadius: 10, border: 'none',
          background: 'transparent', padding: 0, cursor: 'pointer',
          color: 'var(--sn-text)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
            <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </button>
        <div style={{
          flex: 1, fontSize: 17, fontWeight: 600, letterSpacing: -0.3,
          color: 'var(--sn-text)', textAlign: 'center',
        }}>Verify safety number</div>
        <div style={{ width: 32 }}/>
      </div>

      <div className="sn-scroll" style={{ flex: 1 }}>
        {/* Two avatars facing each other */}
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          gap: 18, padding: '24px 24px 18px',
        }}>
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
            <SnAvatar name="Vera Kuznetsova" size={62}/>
            <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--sn-text-2)' }}>You</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', color: 'var(--sn-text-4)' }}>
            <svg width="32" height="20" viewBox="0 0 32 20" fill="none">
              <path d="M2 10h28M22 4l8 6-8 6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
            <SnAvatar name="Maria Chen" size={62}/>
            <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--sn-text-2)' }}>Maria Chen</div>
          </div>
        </div>

        {/* Intro copy */}
        <div style={{
          fontSize: 14, lineHeight: '20px', color: 'var(--sn-text-2)',
          textAlign: 'center', padding: '0 30px 18px',
          letterSpacing: -0.05,
        }}>
          If you can confirm in person — or on a trusted call — that the
          number below matches Maria's, your conversation is genuinely
          between just the two of you.
        </div>

        {/* QR card */}
        <div style={{ padding: '0 20px 16px', display: 'flex', justifyContent: 'center' }}>
          <div style={{
            width: 200, height: 200, padding: 14,
            background: 'var(--sn-surface)',
            borderRadius: 20,
            boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 8px 24px rgba(15,23,32,0.06), 0 0 0 0.5px var(--sn-divider-strong)',
            position: 'relative',
          }}>
            <QrPlaceholder/>
            <div style={{
              position: 'absolute', top: '50%', left: '50%',
              transform: 'translate(-50%, -50%)',
              width: 38, height: 38, borderRadius: 10,
              background: 'var(--sn-bg)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              boxShadow: '0 0 0 3px var(--sn-bg)',
            }}>
              <SinhronMark size={24}/>
            </div>
          </div>
        </div>

        {/* Numeric digits — 12 groups of 5 in a 3×4 grid */}
        <div style={{
          margin: '0 14px 16px',
          padding: '18px 16px',
          background: 'var(--sn-surface)',
          borderRadius: 'var(--sn-radius-card)',
          boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider-strong)',
        }}>
          <div style={{
            fontSize: 11, fontWeight: 700, letterSpacing: 0.6,
            color: 'var(--sn-text-3)', textTransform: 'uppercase',
            textAlign: 'center', marginBottom: 14,
          }}>Numeric · 60 digits</div>
          <div className="sn-mono" style={{
            display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '8px 14px',
            fontSize: 18, fontWeight: 600, letterSpacing: 0.6,
            color: 'var(--sn-text)', textAlign: 'center',
            fontVariantNumeric: 'tabular-nums',
          }}>
            {NUMBERS.map((g, i) => (
              <div key={i}>{g}</div>
            ))}
          </div>
        </div>

        {/* Verified state (if already verified) */}
        {verified && (
          <div style={{
            margin: '0 14px 16px',
            padding: '14px 18px',
            background: 'rgba(31, 175, 110, 0.10)',
            borderRadius: 14,
            display: 'flex', alignItems: 'center', gap: 12,
            color: 'var(--sn-success)',
          }}>
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path d="M12 2l8 4v6c0 5-3.5 9-8 10-4.5-1-8-5-8-10V6l8-4z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
              <path d="M8.5 12l2.5 2.5L16 9.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 14, fontWeight: 600, letterSpacing: -0.1 }}>Verified</div>
              <div style={{ fontSize: 12.5, fontWeight: 500, color: 'var(--sn-text-2)' }}>You confirmed this safety number on Apr 12</div>
            </div>
          </div>
        )}

        <div style={{ height: 12 }}/>
      </div>

      {/* Bottom CTA */}
      <div style={{ padding: '0 20px 18px', display: 'flex', flexDirection: 'column', gap: 10 }}>
        {!verified && (
          <DsButton variant="primary" leading={
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          }>Mark as verified</DsButton>
        )}
        <DsButton variant="ghost">Scan their code</DsButton>
      </div>
    </div>
  );
}

Object.assign(window, { SnSafetyNumber });
