// invite-link.jsx — Accept an invite-token deep link (§6.1)
// Two screens:
//   1. SnInviteLandingNew — user has no Sinhron account yet; the link is the
//      first thing they see when they open the app via deep-link.
//   2. SnInviteEnterToken — manual entry path (paste a token someone gave them).
//
// Exports: SnInviteLandingNew, SnInviteEnterToken

// ─── Shared screen frame (same as DsScreen pattern) ────────────────
function InviteFrame({ children, dark }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>{children}</div>
  );
}

// ─── Topbar with back + skip ───────────────────────────────────────
function InviteTop({ trailing }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center',
      padding: '10px 14px',
    }}>
      <div style={{ width: 32, height: 32, color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center', marginLeft: -6 }}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </div>
      <div style={{ flex: 1 }}/>
      {trailing}
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. Invite landing — new user opened a Sinhron deep link
// ════════════════════════════════════════════════════════════════════
function SnInviteLandingNew({ dark = false, platform = 'ios' }) {
  return (
    <InviteFrame dark={dark}>
      <InviteTop/>

      <div className="sn-scroll" style={{ flex: 1, padding: '8px 22px 0' }}>
        {/* Eyebrow */}
        <div style={{
          display: 'inline-flex', alignItems: 'center', gap: 7,
          padding: '5px 10px 5px 8px', borderRadius: 999,
          background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
          fontSize: 11.5, fontWeight: 700, letterSpacing: 0.2, textTransform: 'uppercase',
        }}>
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
            <path d="M10 14a4 4 0 005.66 0l3-3a4 4 0 10-5.66-5.66L11.5 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            <path d="M14 10a4 4 0 00-5.66 0l-3 3a4 4 0 105.66 5.66L12.5 17" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
          Invite link
        </div>

        <div style={{ fontSize: 28, fontWeight: 600, letterSpacing: -0.7, color: 'var(--sn-text)', marginTop: 14, lineHeight: '34px' }}>
          You've been invited to join a Sinhron server
        </div>
        <div style={{
          fontSize: 15, fontWeight: 500, color: 'var(--sn-text-2)',
          lineHeight: '21px', letterSpacing: -0.1, marginTop: 8,
        }}>
          Sinhron is a private messenger that runs on a server you trust. Below is the server you'll be joining — and who invited you.
        </div>

        {/* Server card */}
        <div style={{
          marginTop: 22,
          background: 'var(--sn-surface)',
          borderRadius: 18,
          padding: '16px 16px 14px',
          boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
        }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{
              width: 44, height: 44, borderRadius: 12,
              background: 'linear-gradient(150deg, #A0C4FF 0%, #2D6FF7 100%)',
              color: '#fff',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              flexShrink: 0,
              boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.20), inset 0 -1px 0 rgba(0,0,0,0.12)',
            }}>
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
                <rect x="3" y="4" width="18" height="6" rx="1.5" stroke="currentColor" strokeWidth="2"/>
                <rect x="3" y="14" width="18" height="6" rx="1.5" stroke="currentColor" strokeWidth="2"/>
                <circle cx="7" cy="7" r="1.2" fill="currentColor"/>
                <circle cx="7" cy="17" r="1.2" fill="currentColor"/>
              </svg>
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div className="sn-mono" style={{
                fontSize: 14, fontWeight: 600, letterSpacing: -0.1, color: 'var(--sn-text)',
                whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
              }}>cabin.sinhron.app</div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 3 }}>
                <div style={{ width: 7, height: 7, borderRadius: 4, background: 'var(--sn-success)' }}/>
                <div style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--sn-success)', letterSpacing: -0.05 }}>Reachable · 28 ms</div>
              </div>
            </div>
          </div>

          <div style={{
            marginTop: 14, paddingTop: 12,
            borderTop: '0.5px solid var(--sn-divider)',
            display: 'flex', alignItems: 'center', gap: 10,
          }}>
            <SnAvatar name="Henry Park" size={32}/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 12.5, fontWeight: 500, color: 'var(--sn-text-3)', letterSpacing: -0.05 }}>Invited by</div>
              <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--sn-text)', letterSpacing: -0.1 }}>Henry Park · @henry</div>
            </div>
          </div>
        </div>

        {/* Token row */}
        <div style={{
          marginTop: 12,
          padding: '11px 12px 11px 14px',
          borderRadius: 12,
          background: 'var(--sn-bg-soft)',
          display: 'flex', alignItems: 'center', gap: 10,
        }}>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-text-3)', flexShrink: 0 }}>
            <circle cx="8" cy="14" r="4" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M11 11l9-9 2 2-2 2 2 2-2 2-2-2-3 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
          <div className="sn-mono" style={{
            flex: 1, minWidth: 0,
            fontSize: 13, fontWeight: 500, color: 'var(--sn-text)', letterSpacing: 0,
            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
          }}>inv_7K9d-c4eR-b8fA-zNm2</div>
          <div style={{
            padding: '3px 8px', borderRadius: 5,
            background: 'rgba(217,119,6,0.14)', color: '#C2410C',
            fontSize: 10.5, fontWeight: 700, letterSpacing: 0.2,
          }}>Expires in 22h</div>
        </div>

        {/* What you'll set up */}
        <div style={{
          marginTop: 22,
          fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase',
          color: 'var(--sn-text-3)',
        }}>Next steps</div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12, marginTop: 10 }}>
          {[
            ['Pick a display name', 'No email, no phone, no password'],
            ['Save your 24-word recovery phrase', 'The only way to restore your account later'],
            ['You\u2019re in', 'Henry will be the first contact in your list'],
          ].map(([k, v], i) => (
            <div key={k} style={{ display: 'flex', gap: 12, alignItems: 'flex-start' }}>
              <div style={{
                width: 24, height: 24, borderRadius: 12, marginTop: 1,
                background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontSize: 12, fontWeight: 700, flexShrink: 0,
              }}>{i + 1}</div>
              <div style={{ flex: 1, fontSize: 13.5, lineHeight: '19px', letterSpacing: -0.05 }}>
                <span style={{ fontWeight: 600, color: 'var(--sn-text)' }}>{k}</span>
                <span style={{ color: 'var(--sn-text-2)' }}> · {v}</span>
              </div>
            </div>
          ))}
        </div>

        <div style={{ height: 28 }}/>
      </div>

      <div style={{ padding: '10px 22px 18px', display: 'flex', flexDirection: 'column', gap: 10 }}>
        <DsButton variant="primary" leading={
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
            <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        }>Accept & set up</DsButton>
        <DsButton variant="ghost">I already have an account</DsButton>
      </div>
    </InviteFrame>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Manual token entry — someone shared the token over a side channel
// ════════════════════════════════════════════════════════════════════
function SnInviteEnterToken({ dark = false, platform = 'ios' }) {
  return (
    <InviteFrame dark={dark}>
      <InviteTop/>

      <div className="sn-scroll" style={{ flex: 1, padding: '8px 22px 0' }}>
        <div style={{ fontSize: 28, fontWeight: 600, letterSpacing: -0.7, color: 'var(--sn-text)', lineHeight: '34px' }}>
          Paste your invite
        </div>
        <div style={{
          fontSize: 15, fontWeight: 500, color: 'var(--sn-text-2)',
          lineHeight: '21px', letterSpacing: -0.1, marginTop: 8,
        }}>
          Got an invite link or token from someone? Paste it below. We'll show you the server and who's inviting you before anything happens.
        </div>

        {/* Server prefilled */}
        <div style={{ marginTop: 24 }}>
          <div style={{
            fontSize: 12, fontWeight: 600, letterSpacing: 0.6, textTransform: 'uppercase',
            color: 'var(--sn-text-3)', paddingLeft: 4, marginBottom: 6,
          }}>Server</div>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8,
            background: 'var(--sn-surface)',
            boxShadow: '0 0 0 0.5px var(--sn-divider-strong)',
            borderRadius: 14, height: 50, padding: '0 16px',
          }}>
            <div style={{ color: 'var(--sn-text-3)', fontSize: 15, fontWeight: 500 }}>https://</div>
            <div className="sn-mono" style={{
              flex: 1, minWidth: 0,
              fontSize: 14, fontWeight: 500, letterSpacing: 0,
              color: 'var(--sn-text)',
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}>cabin.sinhron.app</div>
          </div>
        </div>

        {/* Token input — focused */}
        <div style={{ marginTop: 16 }}>
          <div style={{
            fontSize: 12, fontWeight: 600, letterSpacing: 0.6, textTransform: 'uppercase',
            color: 'var(--sn-text-3)', paddingLeft: 4, marginBottom: 6,
          }}>Invite token</div>
          <div style={{
            background: 'var(--sn-surface)',
            borderRadius: 14,
            boxShadow: '0 0 0 2px var(--sn-accent-soft), 0 0 0 0.5px var(--sn-accent)',
            padding: '12px 16px',
            minHeight: 56,
            display: 'flex', alignItems: 'center', gap: 6,
          }}>
            <div className="sn-mono" style={{
              flex: 1, minWidth: 0,
              fontSize: 14, fontWeight: 500, color: 'var(--sn-text)', letterSpacing: 0,
            }}>inv_7K9d-c4eR-b8fA-zNm2</div>
            <div style={{ width: 1.5, height: 18, background: 'var(--sn-accent)' }}/>
          </div>
        </div>

        {/* Validation success — appears once token parses */}
        <div style={{
          marginTop: 14,
          padding: '11px 14px 11px 12px',
          borderRadius: 12,
          background: 'rgba(31,175,110,0.10)',
          boxShadow: 'inset 0 0 0 0.5px rgba(31,175,110,0.32)',
          display: 'flex', alignItems: 'flex-start', gap: 10,
        }}>
          <div style={{
            width: 22, height: 22, borderRadius: 11, marginTop: 1,
            background: 'rgba(31,175,110,0.18)', color: 'var(--sn-success)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
          }}>
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
              <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </div>
          <div style={{ flex: 1, fontSize: 13, lineHeight: '18px', letterSpacing: -0.05, color: 'var(--sn-text-2)' }}>
            <span style={{ fontWeight: 600, color: 'var(--sn-text)' }}>Valid invite</span> · from Henry Park · expires in 22h
          </div>
        </div>

        {/* QR alternative */}
        <div style={{
          marginTop: 22, padding: '13px 14px 13px 12px',
          background: 'var(--sn-bg-soft)', borderRadius: 12,
          display: 'flex', alignItems: 'center', gap: 12,
        }}>
          <div style={{
            width: 32, height: 32, borderRadius: 8,
            background: 'var(--sn-surface)', color: 'var(--sn-text)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
          }}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <rect x="3" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
              <rect x="14" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
              <rect x="3" y="14" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M14 14h3v3h-3zM17 17h4v4h-4z" stroke="currentColor" strokeWidth="1.8"/>
            </svg>
          </div>
          <div style={{ flex: 1, fontSize: 13.5, fontWeight: 500, color: 'var(--sn-text-2)', letterSpacing: -0.05 }}>
            Or scan an invite QR
          </div>
          <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--sn-accent)' }}>Open camera</div>
        </div>

        <div style={{ height: 24 }}/>
      </div>

      <div style={{ padding: '10px 22px 18px' }}>
        <DsButton variant="primary">Continue</DsButton>
      </div>
    </InviteFrame>
  );
}

Object.assign(window, { SnInviteLandingNew, SnInviteEnterToken });
