// lockscreen.jsx — iOS-style lock-screen showing how Sinhron previews look
// THE one place E2EE story becomes legible to a civilian:
//   • With content  — "Maria Chen · Sounds great, see you at 9 ☕"
//   • Private       — "Sinhron · 2 new messages"  (no sender, no body)
//
// Same wallpaper, same chrome, same clock — only the notification card body
// changes. We render BOTH side by side as separate screens so the design
// comparison is one glance, not a Tweak toggle.
//
// Exports: SnLockContent, SnLockPrivate

// ─── Wallpaper — abstract, premium, warm-cool gradient blobs ────────
function LockWallpaper() {
  return (
    <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', background: '#0E141B' }}>
      <div style={{
        position: 'absolute', inset: 0,
        background: `
          radial-gradient(60% 45% at 22% 18%, rgba(255,176,137,0.45) 0%, transparent 65%),
          radial-gradient(70% 55% at 78% 90%, rgba(124,58,237,0.40) 0%, transparent 70%),
          radial-gradient(50% 40% at 70% 30%, rgba(45,111,247,0.32) 0%, transparent 65%),
          linear-gradient(170deg, #1A1730 0%, #0B1016 60%, #04060A 100%)
        `,
      }}/>
      {/* film grain */}
      <svg width="100%" height="100%" style={{ position: 'absolute', inset: 0, opacity: 0.06, mixBlendMode: 'overlay' }}>
        <filter id="noise"><feTurbulence baseFrequency="0.9" numOctaves="3"/></filter>
        <rect width="100%" height="100%" filter="url(#noise)"/>
      </svg>
    </div>
  );
}

// ─── Notification card shell (system style, Sinhron-branded) ────────
function NotifCard({ app = 'Sinhron', when = 'now', children, count }) {
  return (
    <div style={{
      background: 'rgba(20, 27, 37, 0.55)',
      backdropFilter: 'blur(28px)',
      WebkitBackdropFilter: 'blur(28px)',
      borderRadius: 18,
      padding: '12px 14px 12px 12px',
      boxShadow: '0 1px 0 rgba(255,255,255,0.06) inset, 0 12px 30px rgba(0,0,0,0.30)',
      color: '#fff',
      fontFamily: "'Geist', sans-serif",
      display: 'flex', gap: 12,
    }}>
      {/* App icon */}
      <div style={{
        width: 38, height: 38, borderRadius: 9,
        background: 'linear-gradient(150deg, #4F8AFF 0%, #2D6FF7 100%)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        flexShrink: 0,
        boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.18), inset 0 -1px 0 rgba(0,0,0,0.12)',
      }}>
        {/* Sinhron mark — same as the rest of the app */}
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <path d="M5 8a3 3 0 013-3h8M19 16a3 3 0 01-3 3H8" stroke="white" strokeWidth="2.2" strokeLinecap="round"/>
          <circle cx="16" cy="5" r="2" fill="white"/>
          <circle cx="8" cy="19" r="2" fill="white"/>
        </svg>
      </div>

      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{
          display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 2,
        }}>
          <div style={{ fontSize: 11.5, fontWeight: 600, letterSpacing: 0.2, color: 'rgba(255,255,255,0.75)', textTransform: 'uppercase' }}>{app}</div>
          <div style={{ flex: 1 }}/>
          <div style={{ fontSize: 11.5, fontWeight: 500, color: 'rgba(255,255,255,0.55)' }}>{when}</div>
        </div>
        {children}
      </div>

      {/* Count chip */}
      {count > 1 && (
        <div style={{
          alignSelf: 'flex-start',
          marginTop: 2,
          minWidth: 22, height: 22, padding: '0 7px',
          borderRadius: 11, background: 'rgba(255,255,255,0.16)',
          fontSize: 11, fontWeight: 700, letterSpacing: -0.05,
          color: '#fff',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          flexShrink: 0,
        }}>{count}</div>
      )}
    </div>
  );
}

// ─── Lock screen layout shell ───────────────────────────────────────
function LockShell({ children, mode, modeLabel }) {
  return (
    <div style={{
      width: '100%', height: '100%',
      position: 'relative', overflow: 'hidden',
      color: '#fff',
      fontFamily: "'Geist', sans-serif",
      display: 'flex', flexDirection: 'column',
    }}>
      <LockWallpaper/>

      {/* Clock & date */}
      <div style={{ position: 'relative', textAlign: 'center', paddingTop: 70 }}>
        <div style={{
          fontSize: 14, fontWeight: 500, letterSpacing: 0.3,
          color: 'rgba(255,255,255,0.85)', marginBottom: 4,
        }}>Monday, April 14</div>
        <div style={{
          fontSize: 96, fontWeight: 200, letterSpacing: -4,
          color: '#fff', lineHeight: 1,
          fontVariantNumeric: 'tabular-nums',
        }}>13:24</div>
      </div>

      {/* Privacy-mode chip — sits above the notifications so the comparison reads instantly */}
      <div style={{
        position: 'relative', display: 'flex', justifyContent: 'center',
        marginTop: 22, marginBottom: 12,
      }}>
        <div style={{
          padding: '5px 12px 5px 10px', borderRadius: 999,
          background: mode === 'private' ? 'rgba(43,197,138,0.18)' : 'rgba(255,255,255,0.10)',
          color: mode === 'private' ? '#5DE5A8' : 'rgba(255,255,255,0.85)',
          fontSize: 11.5, fontWeight: 600, letterSpacing: -0.05,
          display: 'flex', alignItems: 'center', gap: 6,
          backdropFilter: 'blur(20px)',
          boxShadow: mode === 'private'
            ? 'inset 0 0 0 0.5px rgba(43,197,138,0.4)'
            : 'inset 0 0 0 0.5px rgba(255,255,255,0.15)',
        }}>
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
            <rect x="5" y="11" width="14" height="10" rx="2" stroke="currentColor" strokeWidth="1.9"/>
            <path d="M8 11V8a4 4 0 018 0v3" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round"/>
          </svg>
          {modeLabel}
        </div>
      </div>

      {/* Notifications */}
      <div style={{
        position: 'relative', flex: 1,
        padding: '0 14px',
        display: 'flex', flexDirection: 'column', gap: 8,
      }}>
        {children}
      </div>

      {/* Bottom indicators — flashlight + camera + home indicator */}
      <div style={{
        position: 'relative', padding: '0 28px 14px',
        display: 'flex', justifyContent: 'space-between', alignItems: 'center',
      }}>
        <div style={{
          width: 42, height: 42, borderRadius: 21,
          background: 'rgba(0,0,0,0.30)', backdropFilter: 'blur(14px)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: '#fff',
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <path d="M9 3h6l2 5-2 3v8a2 2 0 01-2 2h-2a2 2 0 01-2-2v-8L7 8l2-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
          </svg>
        </div>
        <div style={{
          width: 42, height: 42, borderRadius: 21,
          background: 'rgba(0,0,0,0.30)', backdropFilter: 'blur(14px)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: '#fff',
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <rect x="3" y="6" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
            <circle cx="12" cy="13" r="4" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M8 6l1.5-2.5h5L16 6" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
          </svg>
        </div>
      </div>
      <div style={{
        position: 'relative', display: 'flex', justifyContent: 'center', paddingBottom: 8,
      }}>
        <div style={{ width: 134, height: 5, borderRadius: 3, background: '#fff' }}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. With content — sender + body visible
// ════════════════════════════════════════════════════════════════════
function SnLockContent({ dark = true, platform = 'ios' }) {
  return (
    <LockShell mode="content" modeLabel="Show previews">
      <NotifCard when="now">
        <div style={{ fontSize: 14.5, fontWeight: 600, letterSpacing: -0.15, marginBottom: 1 }}>Maria Chen</div>
        <div style={{
          fontSize: 14, fontWeight: 400, lineHeight: '19px', letterSpacing: -0.1,
          color: 'rgba(255,255,255,0.92)',
          display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden',
        }}>Sounds great — see you at 9 tomorrow ☕</div>
      </NotifCard>

      <NotifCard when="11m">
        <div style={{ fontSize: 14.5, fontWeight: 600, letterSpacing: -0.15, marginBottom: 1 }}>Engineering · Alex Müller</div>
        <div style={{
          fontSize: 14, fontWeight: 400, lineHeight: '19px', letterSpacing: -0.1,
          color: 'rgba(255,255,255,0.92)',
          display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden',
        }}>pushed the new SFrame implementation — ready for review when you have a sec</div>
      </NotifCard>

      <NotifCard when="32m" count={3}>
        <div style={{ fontSize: 14.5, fontWeight: 600, letterSpacing: -0.15, marginBottom: 1 }}>Henry Park</div>
        <div style={{
          fontSize: 14, fontWeight: 400, lineHeight: '19px', letterSpacing: -0.1,
          color: 'rgba(255,255,255,0.92)',
          display: '-webkit-box', WebkitLineClamp: 1, WebkitBoxOrient: 'vertical', overflow: 'hidden',
        }}>Voice message · 0:42</div>
      </NotifCard>

      <div style={{ flex: 1 }}/>

      <NoteFootnote>
        Sender and content are visible. The OS pulls these previews from your local Sinhron data — your server never sees them.
      </NoteFootnote>
    </LockShell>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Private — single neutral notification, no content
// ════════════════════════════════════════════════════════════════════
function SnLockPrivate({ dark = true, platform = 'ios' }) {
  return (
    <LockShell mode="private" modeLabel="Hide previews">
      <NotifCard when="now">
        <div style={{
          fontSize: 14.5, fontWeight: 600, letterSpacing: -0.15,
          color: 'rgba(255,255,255,0.95)',
        }}>2 new messages</div>
        <div style={{
          fontSize: 13, fontWeight: 500, color: 'rgba(255,255,255,0.55)', letterSpacing: -0.05,
          marginTop: 2,
        }}>Unlock to read</div>
      </NotifCard>

      {/* "Old" preview, dimmed — illustrates the rule even after a screen wake */}
      <NotifCard when="32m">
        <div style={{
          fontSize: 14.5, fontWeight: 600, letterSpacing: -0.15,
          color: 'rgba(255,255,255,0.95)',
        }}>1 new message</div>
        <div style={{
          fontSize: 13, fontWeight: 500, color: 'rgba(255,255,255,0.55)', letterSpacing: -0.05,
          marginTop: 2,
        }}>Unlock to read</div>
      </NotifCard>

      <div style={{ flex: 1 }}/>

      <NoteFootnote>
        Sender and body are hidden until you unlock. Useful in shared spaces. Toggle in Settings → Notifications.
      </NoteFootnote>
    </LockShell>
  );
}

// ─── small footnote at the bottom of each lock screen — designer note,
// not part of the OS — sits inside the safe area, low contrast
function NoteFootnote({ children }) {
  return (
    <div style={{
      margin: '0 4px 14px',
      padding: '10px 12px',
      borderRadius: 12,
      background: 'rgba(0,0,0,0.30)', backdropFilter: 'blur(12px)',
      boxShadow: 'inset 0 0 0 0.5px rgba(255,255,255,0.06)',
      display: 'flex', gap: 8,
    }}>
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style={{ color: 'rgba(255,255,255,0.55)', marginTop: 1, flexShrink: 0 }}>
        <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
        <path d="M12 11v5M12 8v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
      </svg>
      <div style={{
        fontSize: 11.5, fontWeight: 500, lineHeight: '16px', letterSpacing: -0.05,
        color: 'rgba(255,255,255,0.65)',
      }}>{children}</div>
    </div>
  );
}

Object.assign(window, { SnLockContent, SnLockPrivate });
