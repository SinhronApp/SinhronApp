// active-call-bar.jsx — Active-call mini-bar over the chat list
// Three states:
//   1. SnActiveCallBar       — group call ongoing, you've left the call screen
//   2. SnActiveCallBarSolo   — 1:1 call ongoing
//   3. SnIncomingCallBanner  — banner-form incoming call while you're using the app
//
// All three render the chat list behind so the bar reads in context.

// ─── A pure pill component, reused across all three ─────────────────
function CallPill({ children, kind = 'active' }) {
  const palette = {
    active:   { bg: '#1FAF6E', fg: '#fff', shadow: '0 8px 22px rgba(31,175,110,0.30), 0 2px 6px rgba(31,175,110,0.20)' },
    incoming: { bg: 'var(--sn-accent)', fg: '#fff', shadow: '0 8px 22px rgba(45,111,247,0.32), 0 2px 6px rgba(45,111,247,0.22)' },
  }[kind];
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 10,
      padding: '8px 8px 8px 14px',
      borderRadius: 999,
      background: palette.bg, color: palette.fg,
      boxShadow: palette.shadow,
      fontFamily: "'Geist', sans-serif",
    }}>{children}</div>
  );
}

// ─── Helper — overlay a pill below the system status bar of the device ─
function CallBarFrame({ children, top = 64 }) {
  return (
    <div style={{
      position: 'absolute', top, left: 14, right: 14,
      display: 'flex', justifyContent: 'center',
      zIndex: 8,
    }}>{children}</div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. Group call — ongoing in the background
// ════════════════════════════════════════════════════════════════════
function SnActiveCallBar({ dark = false, platform = 'ios' }) {
  return (
    <div style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden' }}>
      <SinhronChatList dark={dark} platform={platform}/>

      <CallBarFrame top={64}>
        <CallPill kind="active">
          {/* Avatar pile — 3 small overlapping */}
          <div style={{ position: 'relative', width: 50, height: 26, flexShrink: 0 }}>
            {['Maria Chen', 'Henry Park', 'Alex Müller'].map((n, i) => {
              const [c1, c2] = SN_AVATAR_PALETTES[snHashIdx(n, SN_AVATAR_PALETTES.length)];
              return (
                <div key={n} style={{
                  position: 'absolute', left: i * 12, top: 0,
                  width: 26, height: 26, borderRadius: 13,
                  background: `linear-gradient(150deg, ${c1} 0%, ${c2} 100%)`,
                  border: '2px solid #1FAF6E',
                  boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.20)',
                  color: '#fff',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontSize: 10, fontWeight: 700, letterSpacing: 0.2,
                }}>{snInitials(n)}</div>
              );
            })}
          </div>

          {/* Label */}
          <div style={{
            flex: 1, fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1,
            display: 'flex', alignItems: 'baseline', gap: 6,
            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
          }}>
            Engineering · 4
            <span className="sn-mono" style={{ fontSize: 12, fontWeight: 500, color: 'rgba(255,255,255,0.78)', letterSpacing: 0.3 }}>12:18</span>
          </div>

          {/* Tap-to-return chip */}
          <div style={{
            display: 'flex', alignItems: 'center', gap: 4,
            padding: '5px 10px 5px 9px', borderRadius: 999,
            background: 'rgba(0,0,0,0.20)',
            fontSize: 12, fontWeight: 600,
          }}>
            Tap to return
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
              <path d="M9 5l7 7-7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </div>
        </CallPill>
      </CallBarFrame>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. 1:1 call — leaner pill
// ════════════════════════════════════════════════════════════════════
function SnActiveCallBarSolo({ dark = false, platform = 'ios' }) {
  const name = 'Maria Chen';
  return (
    <div style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden' }}>
      <SinhronChatList dark={dark} platform={platform}/>

      <CallBarFrame top={64}>
        <CallPill kind="active">
          <SnAvatar name={name} size={26}/>
          <div style={{
            flex: 1, fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1,
            display: 'flex', alignItems: 'baseline', gap: 6,
            whiteSpace: 'nowrap',
          }}>
            {name}
            <span className="sn-mono" style={{ fontSize: 12, fontWeight: 500, color: 'rgba(255,255,255,0.78)', letterSpacing: 0.3 }}>04:21</span>
          </div>

          {/* Mute toggle */}
          <div style={{
            width: 28, height: 28, borderRadius: 14,
            background: 'rgba(0,0,0,0.20)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
              <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="2" fill="currentColor"/>
              <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
            </svg>
          </div>
          {/* End */}
          <div style={{
            width: 28, height: 28, borderRadius: 14,
            background: '#FF4D4D', boxShadow: '0 2px 6px rgba(255,77,77,0.35)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
              <path d="M3 12c0-2 5-5 9-5s9 3 9 5l-2 2-3-1-1-2c-2-1-4-1-6 0l-1 2-3 1-2-2z" fill="currentColor"/>
            </svg>
          </div>
        </CallPill>
      </CallBarFrame>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. Incoming call banner (in-app — user is mid-scroll, slim version)
// ════════════════════════════════════════════════════════════════════
function SnIncomingCallBanner({ dark = false, platform = 'ios' }) {
  const name = 'Henry Park';
  return (
    <div style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden' }}>
      <SinhronChatList dark={dark} platform={platform}/>

      <CallBarFrame top={64}>
        <div style={{
          width: '100%', maxWidth: 380,
          padding: '10px 10px 10px 14px',
          borderRadius: 22,
          background: 'rgba(20, 27, 37, 0.86)',
          backdropFilter: 'blur(28px)',
          color: '#fff',
          display: 'flex', alignItems: 'center', gap: 12,
          boxShadow: '0 18px 40px rgba(0,0,0,0.30), 0 0 0 0.5px rgba(255,255,255,0.06)',
          fontFamily: "'Geist', sans-serif",
        }}>
          <SnAvatar name={name} size={42}/>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 14.5, fontWeight: 600, letterSpacing: -0.15 }}>{name}</div>
            <div style={{ fontSize: 12, fontWeight: 500, color: 'rgba(255,255,255,0.7)', letterSpacing: -0.05 }}>
              Sinhron audio · incoming
            </div>
          </div>

          {/* Decline */}
          <div style={{
            width: 38, height: 38, borderRadius: 19,
            background: '#FF4D4D',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            boxShadow: '0 4px 12px rgba(255,77,77,0.40)',
          }}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <path d="M3 12c0-2 5-5 9-5s9 3 9 5l-2 2-3-1-1-2c-2-1-4-1-6 0l-1 2-3 1-2-2z" fill="currentColor"/>
            </svg>
          </div>
          {/* Accept */}
          <div style={{
            width: 38, height: 38, borderRadius: 19,
            background: '#1FAF6E',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            boxShadow: '0 4px 12px rgba(31,175,110,0.40)',
          }}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" fill="currentColor"/>
            </svg>
          </div>
        </div>
      </CallBarFrame>
    </div>
  );
}

Object.assign(window, { SnActiveCallBar, SnActiveCallBarSolo, SnIncomingCallBanner });
