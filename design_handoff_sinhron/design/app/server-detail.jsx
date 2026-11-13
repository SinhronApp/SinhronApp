// server-detail.jsx — Self-hosted server config & status (Settings → Server)
// The screen self-hosters live in. Shows the address they're connected to,
// the version of the instance, retention policy *as reported by the server*,
// connection state, and TLS provenance. Two screens:
//   1. SnServerDetail — connected, healthy
//   2. SnServerChange — "are you sure?" sheet when switching/leaving
//
// Exports: SnServerDetail, SnServerChange

// ─── Generic Settings-style section card ────────────────────────────
function SrvCard({ title, children, footnote }) {
  return (
    <div style={{ padding: '0 14px', marginBottom: 22 }}>
      {title && (
        <div style={{
          fontSize: 11, fontWeight: 700, letterSpacing: 0.6,
          color: 'var(--sn-text-3)', textTransform: 'uppercase',
          padding: '0 8px 8px',
        }}>{title}</div>
      )}
      <div style={{
        background: 'var(--sn-surface)',
        borderRadius: 'var(--sn-radius-card)',
        boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
        overflow: 'hidden',
      }}>
        {children}
      </div>
      {footnote && (
        <div style={{
          fontSize: 11.5, fontWeight: 500, lineHeight: '16px',
          color: 'var(--sn-text-3)', letterSpacing: -0.05,
          padding: '8px 8px 0',
        }}>{footnote}</div>
      )}
    </div>
  );
}

function SrvRow({ label, value, valueColor, mono, leading, danger, last }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 14,
      padding: '13px 18px', minHeight: 52,
      borderBottom: last ? 'none' : '0.5px solid var(--sn-divider)',
    }}>
      {leading && (
        <div style={{
          width: 28, height: 28, borderRadius: 8,
          background: danger ? 'rgba(255,77,77,0.14)' : 'var(--sn-accent-soft)',
          color: danger ? '#FF4D4D' : 'var(--sn-accent)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          flexShrink: 0,
        }}>{leading}</div>
      )}
      <div style={{
        flex: 1, fontSize: 14.5, fontWeight: 500, letterSpacing: -0.1,
        color: danger ? '#FF4D4D' : 'var(--sn-text)',
      }}>{label}</div>
      {value && (
        <div className={mono ? 'sn-mono' : ''} style={{
          fontSize: mono ? 12.5 : 13.5, fontWeight: 500,
          color: valueColor || 'var(--sn-text-2)',
          letterSpacing: mono ? 0 : -0.05,
          textAlign: 'right', maxWidth: '55%',
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>{value}</div>
      )}
    </div>
  );
}

// ─── Header shared by both ──────────────────────────────────────────
function SrvHeader({ title }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center',
      padding: '8px 14px 10px',
      borderBottom: '0.5px solid var(--sn-divider)',
    }}>
      <div style={{ width: 32, height: 32, color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center', marginLeft: -6 }}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </div>
      <div style={{
        flex: 1, fontSize: 17, fontWeight: 600, letterSpacing: -0.3,
        color: 'var(--sn-text)', textAlign: 'center',
      }}>{title}</div>
      <div style={{ width: 32 }}/>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. Server detail — connected, healthy
// ════════════════════════════════════════════════════════════════════
function SnServerDetail({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <SrvHeader title="Server"/>

      <div className="sn-scroll" style={{ flex: 1, paddingTop: 22, paddingBottom: 30 }}>
        {/* Hero — server identity card */}
        <div style={{ padding: '0 14px 22px' }}>
          <div style={{
            background: 'var(--sn-surface)',
            borderRadius: 22,
            padding: '20px 20px 18px',
            boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
            display: 'flex', flexDirection: 'column', gap: 14,
          }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
              <div style={{
                width: 54, height: 54, borderRadius: 14,
                background: 'linear-gradient(150deg, #A0C4FF 0%, #2D6FF7 100%)',
                color: '#fff',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.20), inset 0 -1px 0 rgba(0,0,0,0.12)',
                flexShrink: 0,
              }}>
                <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
                  <rect x="3" y="4" width="18" height="6" rx="1.5" stroke="currentColor" strokeWidth="2"/>
                  <rect x="3" y="14" width="18" height="6" rx="1.5" stroke="currentColor" strokeWidth="2"/>
                  <circle cx="7" cy="7" r="1.2" fill="currentColor"/>
                  <circle cx="7" cy="17" r="1.2" fill="currentColor"/>
                </svg>
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div className="sn-mono" style={{
                  fontSize: 15, fontWeight: 600, letterSpacing: -0.1,
                  color: 'var(--sn-text)',
                  whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                }}>cabin.sinhron.app</div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 3 }}>
                  <div style={{ width: 7, height: 7, borderRadius: 4, background: 'var(--sn-success)' }}/>
                  <div style={{
                    fontSize: 12.5, fontWeight: 600, color: 'var(--sn-success)', letterSpacing: -0.05,
                  }}>Connected</div>
                  <div style={{ fontSize: 12, color: 'var(--sn-text-3)' }}>· 28 ms</div>
                </div>
              </div>
            </div>

            <div style={{
              display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8,
              paddingTop: 14, borderTop: '0.5px solid var(--sn-divider)',
            }}>
              {[
                { k: 'Version', v: '1.0.3' },
                { k: 'Region', v: 'eu-central' },
                { k: 'Account', v: 'Self-hosted' },
              ].map(s => (
                <div key={s.k}>
                  <div style={{ fontSize: 10.5, fontWeight: 600, letterSpacing: 0.4, color: 'var(--sn-text-3)', textTransform: 'uppercase' }}>{s.k}</div>
                  <div className="sn-mono" style={{ fontSize: 13, fontWeight: 600, color: 'var(--sn-text)', marginTop: 3, letterSpacing: -0.05 }}>{s.v}</div>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Connection */}
        <SrvCard title="Connection">
          <SrvRow label="Last sync" value="just now" valueColor="var(--sn-success)"
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <path d="M21 5v6h-6M3 19v-6h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
                <path d="M19 11a8 8 0 00-14-3M5 13a8 8 0 0014 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }/>
          <SrvRow label="Transport" value="WSS · HTTP/3"
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <path d="M3 7h18M3 12h18M3 17h18" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }/>
          <SrvRow label="Push delivery" value="APNs"
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <path d="M12 4a5 5 0 015 5v4l2 3H5l2-3V9a5 5 0 015-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
                <path d="M10 20a2 2 0 004 0" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            } last/>
        </SrvCard>

        {/* Policy declared by this server */}
        <SrvCard title="Policy on this server" footnote="Policies are set by your server admin and apply to everyone on cabin.sinhron.app.">
          <SrvRow label="Message retention" value="14 days" valueColor="var(--sn-text)"
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M12 7v5l3.5 2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }/>
          <SrvRow label="Media retention" value="90 days"
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <rect x="3" y="5" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
                <circle cx="9" cy="11" r="2" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M3 17l5-4 4 3 3-2 6 5" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            }/>
          <SrvRow label="Open registration" value="Invite only"
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <circle cx="11" cy="9" r="4" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M3 21c0-4 3.2-7 7-7s7 3 7 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
                <path d="M19 6v6M16 9h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }/>
          <SrvRow label="Max group size" value="1 000"
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <circle cx="9" cy="9" r="3.5" stroke="currentColor" strokeWidth="1.8"/>
                <circle cx="16.5" cy="9.5" r="2.7" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M3 18.5c0-3 2.7-5.2 6-5.2s6 2.2 6 5.2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            } last/>
        </SrvCard>

        {/* TLS certificate */}
        <SrvCard title="TLS certificate">
          <SrvRow label="Issuer" value="Let's Encrypt R11" mono
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <path d="M12 3l9 4v6c0 5-4 9-9 10-5-1-9-5-9-10V7l9-4z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
                <path d="M8 12l3 3 5-6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            }/>
          <SrvRow label="Expires" value="Aug 12 · 2026" mono/>
          <SrvRow label="Fingerprint" value="9a3e…ec22" mono
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <path d="M12 2a10 10 0 00-10 10M12 2a10 10 0 0110 10M6 14c0 5 3 8 6 8s6-3 6-8a6 6 0 10-12 0M10 14a2 2 0 014 0v3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round"/>
              </svg>
            }/>
          <SrvRow label="Pin this certificate" value="Off"
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <path d="M12 2l4 4-1.5 1.5L17 10l-4 4-2.5-2.5L4 18v2h2l6.5-6.5L15 16l4-4-2.5-2.5L18 8l-4-4z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            } last/>
        </SrvCard>

        {/* Admin contact */}
        <SrvCard title="Admin">
          <SrvRow label="Operator" value="Cabin Collective"
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <circle cx="12" cy="8" r="4" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M4 21c0-4 3.6-7 8-7s8 3 8 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }/>
          <SrvRow label="Contact" value="admin@cabin.sinhron.app" mono/>
          <SrvRow label="Terms of service" value="View" valueColor="var(--sn-accent)" last
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <path d="M14 3H6.5A1.5 1.5 0 005 4.5v15A1.5 1.5 0 006.5 21h11A1.5 1.5 0 0019 19.5V8l-5-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
                <path d="M14 3v5h5" stroke="currentColor" strokeWidth="1.8"/>
              </svg>
            }/>
        </SrvCard>

        {/* Destructive */}
        <SrvCard title="Danger zone">
          <SrvRow label="Change server" danger last
            leading={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <path d="M3 9a4 4 0 014-4h10l-3-3M21 15a4 4 0 01-4 4H7l3 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            }/>
        </SrvCard>

        <div style={{
          textAlign: 'center', padding: '4px 24px 8px',
          fontSize: 11, fontWeight: 500, color: 'var(--sn-text-4)', letterSpacing: -0.05,
          lineHeight: '16px',
        }}>
          Sinhron talks to one server at a time. Your data lives encrypted on this server until retention expires; the server admin can read metadata (who messages whom), never message content.
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Change server confirm — destructive sheet over the detail screen
// ════════════════════════════════════════════════════════════════════
function SnServerChange({ dark = false, platform = 'ios' }) {
  return (
    <div style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden' }}>
      <SnServerDetail dark={dark} platform={platform}/>
      <div style={{ position: 'absolute', inset: 0, background: dark ? 'rgba(0,0,0,0.50)' : 'rgba(15,23,32,0.38)' }}/>

      <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
        position: 'absolute', left: 0, right: 0, bottom: 0,
        background: 'var(--sn-bg)',
        borderTopLeftRadius: 22, borderTopRightRadius: 22,
        boxShadow: '0 -10px 40px rgba(0,0,0,0.30)',
        padding: '14px 22px 26px',
      }}>
        <div style={{ display: 'flex', justifyContent: 'center', paddingBottom: 14 }}>
          <div style={{ width: 38, height: 5, borderRadius: 3, background: 'var(--sn-text-4)' }}/>
        </div>

        <div style={{
          width: 56, height: 56, borderRadius: 16, margin: '0 auto 14px',
          background: 'rgba(255,77,77,0.14)', color: '#FF4D4D',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
            <path d="M12 3l10 18H2L12 3z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
            <path d="M12 10v5M12 18v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
          </svg>
        </div>

        <div style={{ textAlign: 'center', fontSize: 20, fontWeight: 600, letterSpacing: -0.4, color: 'var(--sn-text)', marginBottom: 8 }}>
          Change server?
        </div>
        <div style={{
          textAlign: 'center', fontSize: 14, fontWeight: 500,
          lineHeight: '20px', letterSpacing: -0.05,
          color: 'var(--sn-text-2)', marginBottom: 18,
        }}>
          You'll be signed out of <span className="sn-mono" style={{ color: 'var(--sn-text)', fontSize: 13 }}>cabin.sinhron.app</span>. Your identity key and recovery phrase stay; messages, groups and contacts live only on this server and will <b>not</b> follow you.
        </div>

        <div style={{
          background: 'var(--sn-bg-soft)', borderRadius: 12,
          padding: '12px 14px', marginBottom: 16,
          display: 'flex', flexDirection: 'column', gap: 8,
        }}>
          {[
            ['12 chats', 'including 3 groups'],
            ['1 240 messages', 'on this device · safe'],
            ['Linked devices', '2 stay paired'],
          ].map(([k, v]) => (
            <div key={k} style={{ display: 'flex', alignItems: 'baseline', gap: 8, fontSize: 13, letterSpacing: -0.05 }}>
              <div style={{ fontWeight: 600, color: 'var(--sn-text)' }}>{k}</div>
              <div style={{ color: 'var(--sn-text-3)' }}>· {v}</div>
            </div>
          ))}
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <DsButton variant="primary" leading={
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <path d="M3 9a4 4 0 014-4h10l-3-3M21 15a4 4 0 01-4 4H7l3 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          }>Continue & pick new server</DsButton>
          <DsButton variant="ghost">Cancel</DsButton>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SnServerDetail, SnServerChange });
