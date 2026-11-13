// account-delete.jsx — Two destructive flows
//   1. SnDeleteDevice  — "remove this device from my account" (soft, recoverable
//      because the user still has their recovery phrase and other devices)
//   2. SnDeleteAccount — full account deletion (MLS-Remove from every group,
//      identity-key burned, recovery phrase no longer recovers anything)
//
// Both render as Settings sub-screens with a confirm sheet pre-applied so
// the design surfaces the WARNING text immediately — the way Apple and
// Signal do it for destructive flows.
//
// Exports: SnDeleteDevice, SnDeleteAccount

// ─── Soft Settings-sub-screen header ────────────────────────────────
function DelHeader({ title }) {
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

// ─── A checklist of what will happen ────────────────────────────────
function ConsequenceList({ items }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      {items.map((it, i) => (
        <div key={i} style={{ display: 'flex', gap: 12, alignItems: 'flex-start' }}>
          <div style={{
            width: 22, height: 22, borderRadius: 11, marginTop: 1,
            background: it.tone === 'safe' ? 'rgba(31,175,110,0.16)' : 'rgba(255,77,77,0.16)',
            color: it.tone === 'safe' ? 'var(--sn-success)' : '#FF4D4D',
            display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
          }}>
            {it.tone === 'safe' ? (
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            ) : (
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                <path d="M5 5l14 14M19 5L5 19" stroke="currentColor" strokeWidth="3" strokeLinecap="round"/>
              </svg>
            )}
          </div>
          <div style={{
            flex: 1, fontSize: 13.5, lineHeight: '19px', letterSpacing: -0.05,
            color: 'var(--sn-text-2)',
          }}>
            <span style={{ fontWeight: 600, color: 'var(--sn-text)' }}>{it.title}</span>
            {it.detail && <> · {it.detail}</>}
          </div>
        </div>
      ))}
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. Remove this device — soft destructive
// ════════════════════════════════════════════════════════════════════
function SnDeleteDevice({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DelHeader title="Remove this device"/>

      <div className="sn-scroll" style={{ flex: 1, padding: '24px 18px 24px' }}>
        {/* Hero */}
        <div style={{
          display: 'flex', flexDirection: 'column', alignItems: 'center',
          gap: 12, marginBottom: 22,
        }}>
          <div style={{
            width: 64, height: 64, borderRadius: 18,
            background: 'rgba(255,77,77,0.14)', color: '#FF4D4D',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <svg width="32" height="32" viewBox="0 0 24 24" fill="none">
              <rect x="2.5" y="5" width="13" height="11" rx="2" stroke="currentColor" strokeWidth="1.8"/>
              <rect x="14" y="9" width="7.5" height="12" rx="1.8" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M15.5 14.5l4 4M19.5 14.5l-4 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          </div>
          <div style={{ fontSize: 22, fontWeight: 600, letterSpacing: -0.4, color: 'var(--sn-text)', textAlign: 'center' }}>
            Remove iPhone 15 Pro?
          </div>
          <div style={{
            fontSize: 14, fontWeight: 500, color: 'var(--sn-text-2)',
            lineHeight: '20px', letterSpacing: -0.05, textAlign: 'center', maxWidth: 320,
          }}>
            This device will be signed out of every group you're in. Your other devices keep their history.
          </div>
        </div>

        {/* This device */}
        <div style={{
          background: 'var(--sn-surface)',
          borderRadius: 'var(--sn-radius-card)',
          padding: '14px 16px',
          marginBottom: 20,
          display: 'flex', alignItems: 'center', gap: 14,
          boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
        }}>
          <div style={{
            width: 42, height: 42, borderRadius: 11,
            background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
          }}>
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
              <rect x="6" y="2" width="12" height="20" rx="2.5" stroke="currentColor" strokeWidth="1.8"/>
              <circle cx="12" cy="18.5" r="0.9" fill="currentColor"/>
            </svg>
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{
              fontSize: 14.5, fontWeight: 600, letterSpacing: -0.15, color: 'var(--sn-text)',
              display: 'flex', alignItems: 'center', gap: 8,
            }}>
              iPhone 15 Pro
              <span style={{
                fontSize: 10.5, fontWeight: 700, letterSpacing: 0.2,
                padding: '2px 6px', borderRadius: 4,
                background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
                textTransform: 'uppercase',
              }}>This device</span>
            </div>
            <div className="sn-mono" style={{ fontSize: 12, color: 'var(--sn-text-3)', marginTop: 2 }}>
              fp: a4f7 · iOS 18.4 · paired Apr 02
            </div>
          </div>
        </div>

        {/* Consequences */}
        <div style={{
          fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase',
          color: 'var(--sn-text-3)', padding: '0 4px 12px',
        }}>What happens</div>
        <ConsequenceList items={[
          { tone: 'safe', title: 'Other devices keep working', detail: 'MacBook Pro and iPad continue to receive new messages' },
          { tone: 'safe', title: 'Recovery phrase still works' },
          { tone: 'gone', title: 'Local history on this device is wiped', detail: 'including drafts, cached media and search index' },
          { tone: 'gone', title: 'Future messages won\u2019t arrive here', detail: 'unless you re-pair this device' },
        ]}/>

        <div style={{ marginTop: 22, padding: '12px 14px', borderRadius: 12, background: 'var(--sn-bg-soft)' }}>
          <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--sn-text-2)', letterSpacing: -0.05, lineHeight: '18px' }}>
            We'll commit an MLS <span className="sn-mono" style={{ fontSize: 11, color: 'var(--sn-text)', background: 'var(--sn-surface)', padding: '0 5px', borderRadius: 4 }}>Remove</span> from every group you're in. After the commit lands, no past messages can be decrypted on this device.
          </div>
        </div>
      </div>

      {/* Action bar */}
      <div style={{
        padding: '12px 14px 18px',
        borderTop: '0.5px solid var(--sn-divider)',
        background: 'var(--sn-bg)',
        display: 'flex', flexDirection: 'column', gap: 8,
      }}>
        <div style={{
          width: '100%', height: 50, borderRadius: 14,
          background: '#FF4D4D', color: '#fff',
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
          boxShadow: '0 1px 2px rgba(255,77,77,0.22), 0 6px 16px rgba(255,77,77,0.20)',
          fontSize: 16, fontWeight: 600, letterSpacing: -0.15,
        }}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <rect x="2.5" y="5" width="13" height="11" rx="2" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M15 9l5 5M20 9l-5 5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
          Remove this device
        </div>
        <DsButton variant="ghost">Cancel</DsButton>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Delete account — hard destructive, type-to-confirm gate
// ════════════════════════════════════════════════════════════════════
function SnDeleteAccount({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DelHeader title="Delete account"/>

      <div className="sn-scroll" style={{ flex: 1, padding: '24px 18px 24px' }}>
        <div style={{
          display: 'flex', flexDirection: 'column', alignItems: 'center',
          gap: 12, marginBottom: 22,
        }}>
          <div style={{
            width: 64, height: 64, borderRadius: 18,
            background: 'rgba(255,77,77,0.14)', color: '#FF4D4D',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <svg width="32" height="32" viewBox="0 0 24 24" fill="none">
              <path d="M12 3l10 18H2L12 3z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              <path d="M12 10v5M12 18v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
            </svg>
          </div>
          <div style={{ fontSize: 22, fontWeight: 600, letterSpacing: -0.4, color: 'var(--sn-text)', textAlign: 'center' }}>
            Delete your account
          </div>
          <div style={{
            fontSize: 14, fontWeight: 500, color: 'var(--sn-text-2)',
            lineHeight: '20px', letterSpacing: -0.05, textAlign: 'center', maxWidth: 320,
          }}>
            We'll remove your identity from every group, sign out all your devices, and burn your account on <span className="sn-mono" style={{ color: 'var(--sn-text)', fontSize: 13 }}>cabin.sinhron.app</span>.
          </div>
        </div>

        {/* Identity card */}
        <div style={{
          background: 'var(--sn-surface)',
          borderRadius: 'var(--sn-radius-card)',
          padding: '14px 16px',
          marginBottom: 20,
          display: 'flex', alignItems: 'center', gap: 14,
          boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
        }}>
          <SnAvatar name="Vera Kuznetsova" size={48}/>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: -0.2, color: 'var(--sn-text)' }}>Vera Kuznetsova</div>
            <div className="sn-mono" style={{ fontSize: 12, color: 'var(--sn-text-3)', marginTop: 2 }}>@vera · 12 chats · 2 devices</div>
          </div>
        </div>

        {/* Consequences — all destructive */}
        <div style={{
          fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase',
          color: 'var(--sn-text-3)', padding: '0 4px 12px',
        }}>This can't be undone</div>
        <ConsequenceList items={[
          { tone: 'gone', title: 'Your identity key is burned', detail: 'recovery phrase no longer restores anything' },
          { tone: 'gone', title: 'Removed from every group', detail: '3 groups, including Engineering and Coffee crew' },
          { tone: 'gone', title: 'All devices signed out', detail: 'iPhone, MacBook' },
          { tone: 'gone', title: 'Server cleanup', detail: 'KeyPackages and remaining ciphertext wiped on next epoch' },
          { tone: 'gone', title: 'Your contacts won\u2019t be notified', detail: 'they\u2019ll see your last message; not a system event' },
        ]}/>

        {/* Type-to-confirm */}
        <div style={{ marginTop: 24 }}>
          <div style={{
            fontSize: 12, fontWeight: 600, letterSpacing: 0.6, textTransform: 'uppercase',
            color: 'var(--sn-text-3)',
            paddingLeft: 4, marginBottom: 6,
          }}>To confirm, type</div>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 10,
            background: 'var(--sn-surface)',
            boxShadow: '0 0 0 0.5px var(--sn-divider-strong)',
            borderRadius: 14, height: 50, padding: '0 16px',
          }}>
            <div className="sn-mono" style={{
              flex: 1, fontSize: 14, fontWeight: 500, color: 'var(--sn-text)',
              letterSpacing: 0,
            }}>delete vera</div>
            <div style={{ width: 1.5, height: 18, background: 'var(--sn-accent)' }}/>
          </div>
        </div>
      </div>

      {/* Action bar */}
      <div style={{
        padding: '12px 14px 18px',
        borderTop: '0.5px solid var(--sn-divider)',
        background: 'var(--sn-bg)',
        display: 'flex', flexDirection: 'column', gap: 8,
      }}>
        <div style={{
          width: '100%', height: 50, borderRadius: 14,
          background: '#FF4D4D', color: '#fff',
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
          boxShadow: '0 1px 2px rgba(255,77,77,0.22), 0 6px 16px rgba(255,77,77,0.20)',
          fontSize: 16, fontWeight: 600, letterSpacing: -0.15,
        }}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <path d="M3 6h18M8 6V4a1 1 0 011-1h6a1 1 0 011 1v2M6 6l1 14a1 1 0 001 1h8a1 1 0 001-1l1-14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
          Delete account forever
        </div>
        <DsButton variant="ghost">Cancel</DsButton>
      </div>
    </div>
  );
}

Object.assign(window, { SnDeleteDevice, SnDeleteAccount });
