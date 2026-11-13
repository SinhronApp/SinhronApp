// perm-denied.jsx — Settings → Notifications with system-level denial
// Critical UX moment: user said "no" to iOS/Android's notification prompt.
// Now Sinhron can't send a single push, and the whole rest of this screen's
// toggles are inert. Pattern: a tall, deliberate red banner pinned to the
// top with a deep-link to the system Settings; the local toggles are
// dimmed but visible so the user knows what they're missing.
//
// Exports: SnPermDeniedNotifications

function PdHeader({ title }) {
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

function PdRow({ icon, iconBg, label, value, toggleOn, disabled, last }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 14,
      padding: '13px 18px', minHeight: 52,
      opacity: disabled ? 0.5 : 1,
      borderBottom: last ? 'none' : '0.5px solid var(--sn-divider)',
    }}>
      {icon && (
        <div style={{
          width: 28, height: 28, borderRadius: 8,
          background: iconBg || 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
        }}>{icon}</div>
      )}
      <div style={{ flex: 1, fontSize: 14.5, fontWeight: 500, color: 'var(--sn-text)' }}>{label}</div>
      {value != null && <div style={{ fontSize: 13.5, fontWeight: 500, color: 'var(--sn-text-2)' }}>{value}</div>}
      {toggleOn != null && (
        <div style={{
          width: 44, height: 26, borderRadius: 13,
          background: toggleOn ? 'var(--sn-accent)' : 'var(--sn-text-4)',
          position: 'relative',
        }}>
          <div style={{
            position: 'absolute', top: 2, left: toggleOn ? 20 : 2,
            width: 22, height: 22, borderRadius: 11,
            background: '#fff',
            boxShadow: '0 1px 2px rgba(0,0,0,0.20), 0 2px 4px rgba(0,0,0,0.10)',
          }}/>
        </div>
      )}
    </div>
  );
}

function PdCard({ title, footnote, children }) {
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
      }}>{children}</div>
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

function SnPermDeniedNotifications({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <PdHeader title="Notifications"/>

      <div className="sn-scroll" style={{ flex: 1, paddingTop: 22, paddingBottom: 30 }}>
        {/* Hero red banner */}
        <div style={{ padding: '0 14px 18px' }}>
          <div style={{
            background: 'rgba(255, 77, 77, 0.10)',
            border: '0.5px solid rgba(255, 77, 77, 0.32)',
            borderRadius: 16,
            padding: '14px 14px 12px',
            display: 'flex', flexDirection: 'column', gap: 12,
          }}>
            <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12 }}>
              <div style={{
                width: 38, height: 38, borderRadius: 11,
                background: 'rgba(255, 77, 77, 0.18)', color: '#D03A3A',
                display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
              }}>
                <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
                  <path d="M12 4a5 5 0 015 5v4l2 3H5l2-3V9a5 5 0 015-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
                  <path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"/>
                </svg>
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14.5, fontWeight: 600, color: '#D03A3A', letterSpacing: -0.1 }}>
                  Notifications are turned off in {platform === 'ios' ? 'iOS' : 'system'} Settings
                </div>
                <div style={{
                  fontSize: 13, fontWeight: 500, lineHeight: '18px', letterSpacing: -0.05,
                  color: 'var(--sn-text-2)', marginTop: 4,
                }}>
                  Sinhron can't deliver pushes until you allow them. Calls and incoming messages will only arrive while the app is open in the foreground.
                </div>
              </div>
            </div>

            <div style={{ display: 'flex', gap: 8 }}>
              <div style={{
                flex: 1, height: 40, borderRadius: 12,
                background: '#FF4D4D', color: '#fff',
                display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
                fontSize: 14, fontWeight: 600, letterSpacing: -0.1,
                boxShadow: '0 1px 2px rgba(255,77,77,0.22), 0 4px 12px rgba(255,77,77,0.20)',
              }}>
                Open {platform === 'ios' ? 'iOS' : 'system'} settings
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                  <path d="M7 17L17 7M9 7h8v8" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </div>
              <div style={{
                height: 40, padding: '0 14px', borderRadius: 12,
                color: 'var(--sn-text-2)',
                background: 'rgba(15,23,32,0.04)',
                fontSize: 14, fontWeight: 600, letterSpacing: -0.05,
                display: 'flex', alignItems: 'center', justifyContent: 'center',
              }}>Later</div>
            </div>
          </div>
        </div>

        {/* What you'll miss — explainer */}
        <div style={{ padding: '0 14px 18px' }}>
          <div style={{
            background: 'var(--sn-surface)',
            borderRadius: 14,
            padding: '14px 16px',
            boxShadow: '0 0 0 0.5px var(--sn-divider)',
          }}>
            <div style={{
              fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase',
              color: 'var(--sn-text-3)', marginBottom: 10,
            }}>What you'll miss</div>
            {[
              { k: 'Incoming calls', v: "won't ring unless the app is open" },
              { k: 'New messages', v: 'silent — no preview on lock screen' },
              { k: 'Mentions in groups', v: '@you alerts are suppressed' },
            ].map((it, i, arr) => (
              <div key={it.k} style={{
                display: 'flex', alignItems: 'baseline', gap: 10,
                padding: '8px 0',
                borderTop: i === 0 ? 'none' : '0.5px solid var(--sn-divider)',
              }}>
                <div style={{ width: 6, height: 6, borderRadius: 3, background: 'var(--sn-text-4)', flexShrink: 0, marginTop: 7 }}/>
                <div style={{
                  flex: 1, fontSize: 13.5, lineHeight: '19px', letterSpacing: -0.05,
                  color: 'var(--sn-text-2)',
                }}>
                  <span style={{ fontWeight: 600, color: 'var(--sn-text)' }}>{it.k}</span> — {it.v}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* In-app toggles — visible but disabled */}
        <PdCard title="In-app preferences" footnote="These take effect once you allow notifications above. Your local settings are remembered.">
          <PdRow disabled toggleOn={true}
            icon={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <path d="M4 6.5C4 5.12 5.12 4 6.5 4h11A2.5 2.5 0 0120 6.5v8a2.5 2.5 0 01-2.5 2.5H10l-4 3.5V17H6.5A2.5 2.5 0 014 14.5v-8z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            } label="Direct messages"/>
          <PdRow disabled toggleOn={true}
            icon={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <circle cx="9" cy="9" r="3.5" stroke="currentColor" strokeWidth="1.8"/>
                <circle cx="16.5" cy="9.5" r="2.7" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M3 18.5c0-3 2.7-5.2 6-5.2s6 2.2 6 5.2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            } label="Groups · @mentions only"/>
          <PdRow disabled toggleOn={true}
            icon={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            } label="Calls"/>
          <PdRow disabled value="Hide previews"
            icon={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <rect x="5" y="11" width="14" height="10" rx="2" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M8 11V8a4 4 0 018 0v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            } label="Lock-screen preview" last/>
        </PdCard>

        {/* Foreground fallback — what we'll do while denied */}
        <PdCard title="Fallback while notifications are off">
          <PdRow disabled={false} toggleOn={true}
            icon={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <circle cx="12" cy="12" r="3" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M21 12c-3-5-7-7-9-7s-6 2-9 7c3 5 7 7 9 7s6-2 9-7z" stroke="currentColor" strokeWidth="1.8"/>
              </svg>
            } label="Keep WebSocket open in foreground"/>
          <PdRow disabled={false} toggleOn={false}
            icon={
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <rect x="3" y="6" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M3 10h18" stroke="currentColor" strokeWidth="1.8"/>
                <circle cx="8" cy="14" r="1" fill="currentColor"/>
                <circle cx="12" cy="14" r="1" fill="currentColor"/>
                <circle cx="16" cy="14" r="1" fill="currentColor"/>
              </svg>
            } label="Show in-app banner on new messages" last/>
        </PdCard>
      </div>
    </div>
  );
}

Object.assign(window, { SnPermDeniedNotifications });
