// calls.jsx — Incoming, In-call (audio), In-call (video), Missed/ended
// Calls always render in dark scheme (the whole industry does this — focus on
// the conversation, fade the rest). The "dark" prop is accepted but ignored
// for in-call. Exports: SnIncomingCall, SnInCallAudio, SnInCallVideo, SnCallEnded

// ─── Avatar gradient backdrop ───────────────────────────────────────
function CallBackdrop({ name }) {
  const [c1, c2] = SN_AVATAR_PALETTES[snHashIdx(name, SN_AVATAR_PALETTES.length)];
  return (
    <div style={{
      position: 'absolute', inset: 0,
      background: `
        radial-gradient(60% 50% at 50% 20%, ${c1}66 0%, transparent 65%),
        radial-gradient(80% 60% at 50% 80%, ${c2}55 0%, transparent 70%),
        #0B1016
      `,
    }}/>
  );
}

// ─── Round control button ──────────────────────────────────────────
function CallBtn({ icon, label, kind = 'default', size = 64 }) {
  const palette = {
    default: { bg: 'rgba(255,255,255,0.14)', fg: '#fff' },
    active:  { bg: '#fff', fg: '#0B1016' },
    danger:  { bg: '#FF4D4D', fg: '#fff' },
    accept:  { bg: '#1FAF6E', fg: '#fff' },
  }[kind];
  return (
    <div style={{
      display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8,
    }}>
      <div style={{
        width: size, height: size, borderRadius: size / 2,
        background: palette.bg, color: palette.fg,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        backdropFilter: kind === 'default' ? 'blur(20px)' : 'none',
        boxShadow: kind === 'danger'
          ? '0 6px 20px rgba(255,77,77,0.45)'
          : kind === 'accept'
          ? '0 6px 20px rgba(31,175,110,0.40)'
          : 'none',
      }}>{icon}</div>
      {label && (
        <div style={{
          fontSize: 12, fontWeight: 500,
          color: 'rgba(255,255,255,0.85)', letterSpacing: -0.05,
        }}>{label}</div>
      )}
    </div>
  );
}

// ─── Icons used across call screens ────────────────────────────────
const CALL_ICONS = {
  mic: (
    <svg width="26" height="26" viewBox="0 0 24 24" fill="none">
      <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="2" fill="currentColor"/>
      <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
    </svg>
  ),
  micOff: (
    <svg width="26" height="26" viewBox="0 0 24 24" fill="none">
      <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="2"/>
      <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
      <path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"/>
    </svg>
  ),
  speaker: (
    <svg width="26" height="26" viewBox="0 0 24 24" fill="none">
      <path d="M11 5L6 9H3v6h3l5 4V5z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
      <path d="M16 9a4 4 0 010 6M19 6a8 8 0 010 12" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
    </svg>
  ),
  video: (
    <svg width="26" height="26" viewBox="0 0 24 24" fill="none">
      <rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="2"/>
      <path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
    </svg>
  ),
  videoOff: (
    <svg width="26" height="26" viewBox="0 0 24 24" fill="none">
      <rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="2"/>
      <path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
      <path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"/>
    </svg>
  ),
  flip: (
    <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
      <path d="M3 9a4 4 0 014-4h10l-3-3M21 15a4 4 0 01-4 4H7l3 3" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  ),
  endCall: (
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
      <path d="M3 12c0-2 5-5 9-5s9 3 9 5l-2 2-3-1-1-2c-2-1-4-1-6 0l-1 2-3 1-2-2z" fill="currentColor"/>
    </svg>
  ),
  message: (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
      <path d="M4 6.5C4 5.12 5.12 4 6.5 4h11A2.5 2.5 0 0120 6.5v8a2.5 2.5 0 01-2.5 2.5H10l-4 3.5V17H6.5A2.5 2.5 0 014 14.5v-8z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
    </svg>
  ),
};

// ════════════════════════════════════════════════════════════════════
// 1. Incoming call — full-screen, gradient backdrop, name + 2 buttons
// ════════════════════════════════════════════════════════════════════
function SnIncomingCall({ dark = true, platform = 'ios' }) {
  const name = 'Maria Chen';
  return (
    <div style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      position: 'relative', overflow: 'hidden',
      color: '#fff',
      fontFamily: "'Geist', sans-serif",
    }}>
      <CallBackdrop name={name}/>

      {/* Top — calling label */}
      <div style={{ position: 'relative', padding: '60px 24px 0', textAlign: 'center' }}>
        <div style={{
          fontSize: 13, fontWeight: 600, letterSpacing: 0.6,
          color: 'rgba(255,255,255,0.7)', textTransform: 'uppercase',
        }}>Sinhron audio</div>
      </div>

      {/* Avatar + name */}
      <div style={{
        position: 'relative', flex: 1,
        display: 'flex', flexDirection: 'column', alignItems: 'center',
        justifyContent: 'center', gap: 22,
      }}>
        <div style={{
          width: 132, height: 132, borderRadius: '50%',
          position: 'relative',
        }}>
          {/* pulse ring */}
          <div style={{
            position: 'absolute', inset: -12, borderRadius: '50%',
            boxShadow: '0 0 0 1px rgba(255,255,255,0.15), 0 0 0 6px rgba(255,255,255,0.06)',
          }}/>
          <SnAvatar name={name} size={132}/>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
          <div style={{
            fontSize: 32, fontWeight: 600, letterSpacing: -0.7,
          }}>{name}</div>
          <div style={{
            fontSize: 16, fontWeight: 500, color: 'rgba(255,255,255,0.65)',
            letterSpacing: -0.1,
          }}>incoming call…</div>
        </div>
      </div>

      {/* Action row */}
      <div style={{
        position: 'relative',
        padding: '0 36px 60px',
        display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end',
      }}>
        <CallBtn icon={CALL_ICONS.endCall} label="Decline" kind="danger" size={68}/>
        <CallBtn icon={CALL_ICONS.message} label="Message" size={48}/>
        <CallBtn icon={
          <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
            <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" fill="currentColor"/>
          </svg>
        } label="Accept" kind="accept" size={68}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. In-call audio — large avatar, timer, 4 controls + end
// ════════════════════════════════════════════════════════════════════
function SnInCallAudio({ dark = true, platform = 'ios' }) {
  const name = 'Maria Chen';
  return (
    <div style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      position: 'relative', overflow: 'hidden',
      color: '#fff',
      fontFamily: "'Geist', sans-serif",
    }}>
      <CallBackdrop name={name}/>

      {/* Top — minimised pill */}
      <div style={{
        position: 'relative', padding: '50px 16px 0',
        display: 'flex', justifyContent: 'center',
      }}>
        <div style={{
          padding: '8px 14px', borderRadius: 999,
          background: 'rgba(255,255,255,0.10)',
          backdropFilter: 'blur(20px)',
          display: 'flex', alignItems: 'center', gap: 8,
          fontSize: 12.5, fontWeight: 600, letterSpacing: -0.1,
          color: 'rgba(255,255,255,0.95)',
        }}>
          <span style={{ width: 6, height: 6, borderRadius: 3, background: '#1FAF6E' }}/>
          Connected · audio
        </div>
      </div>

      {/* Avatar + name + timer */}
      <div style={{
        position: 'relative', flex: 1,
        display: 'flex', flexDirection: 'column', alignItems: 'center',
        justifyContent: 'center', gap: 18,
      }}>
        <SnAvatar name={name} size={148}/>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
          <div style={{ fontSize: 30, fontWeight: 600, letterSpacing: -0.7 }}>{name}</div>
          <div className="sn-mono" style={{
            fontSize: 17, fontWeight: 500, letterSpacing: 0.4,
            color: 'rgba(255,255,255,0.7)',
            fontVariantNumeric: 'tabular-nums',
          }}>04:21</div>
        </div>
      </div>

      {/* Controls — 4 round + end button */}
      <div style={{ position: 'relative', padding: '0 24px 50px' }}>
        <div style={{
          display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12,
          marginBottom: 28,
        }}>
          <CallBtn icon={CALL_ICONS.mic} label="Mute"/>
          <CallBtn icon={CALL_ICONS.speaker} label="Speaker" kind="active"/>
          <CallBtn icon={CALL_ICONS.video} label="Video"/>
          <CallBtn icon={
            <svg width="26" height="26" viewBox="0 0 24 24" fill="none">
              <circle cx="11" cy="9" r="4" stroke="currentColor" strokeWidth="2"/>
              <path d="M3 21c0-4 3.2-7 7-7s7 3 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
              <path d="M19 6v6M16 9h6" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
            </svg>
          } label="Add"/>
        </div>
        <div style={{ display: 'flex', justifyContent: 'center' }}>
          <CallBtn icon={CALL_ICONS.endCall} kind="danger" size={68}/>
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. In-call video — full-bleed video, self PiP, floating controls
// ════════════════════════════════════════════════════════════════════
function SnInCallVideo({ dark = true, platform = 'ios' }) {
  const name = 'Maria Chen';
  const [c1, c2] = SN_AVATAR_PALETTES[snHashIdx(name, SN_AVATAR_PALETTES.length)];
  const [s1, s2] = SN_AVATAR_PALETTES[snHashIdx('Vera Kuznetsova', SN_AVATAR_PALETTES.length)];
  return (
    <div style={{
      width: '100%', height: '100%',
      position: 'relative', overflow: 'hidden',
      color: '#fff',
      fontFamily: "'Geist', sans-serif",
    }}>
      {/* Main video feed (placeholder = abstract scene from peer's avatar palette) */}
      <div style={{
        position: 'absolute', inset: 0,
        background: `
          radial-gradient(50% 40% at 50% 35%, ${c1} 0%, ${c2} 60%, #060a10 100%)
        `,
      }}>
        <svg width="100%" height="100%" preserveAspectRatio="xMidYMid slice" viewBox="0 0 400 700" style={{ position: 'absolute', inset: 0, opacity: 0.4 }}>
          <circle cx="200" cy="240" r="80" fill="rgba(0,0,0,0.25)"/>
          <circle cx="200" cy="380" r="160" fill="rgba(0,0,0,0.20)"/>
        </svg>
        {/* Subtle vignette */}
        <div style={{
          position: 'absolute', inset: 0,
          background: 'linear-gradient(180deg, rgba(0,0,0,0.45) 0%, transparent 22%, transparent 70%, rgba(0,0,0,0.55) 100%)',
        }}/>
      </div>

      {/* Top — name + timer */}
      <div style={{
        position: 'absolute', top: 50, left: 16, right: 16,
        display: 'flex', alignItems: 'center', gap: 12,
      }}>
        <div style={{
          padding: '8px 12px 8px 8px', borderRadius: 999,
          background: 'rgba(0,0,0,0.36)', backdropFilter: 'blur(20px)',
          display: 'flex', alignItems: 'center', gap: 8,
          fontSize: 13, fontWeight: 600, letterSpacing: -0.1,
        }}>
          <span style={{ width: 6, height: 6, borderRadius: 3, background: '#1FAF6E' }}/>
          {name}
          <span className="sn-mono" style={{ color: 'rgba(255,255,255,0.7)', marginLeft: 2 }}>04:21</span>
        </div>
        <div style={{ flex: 1 }}/>
        <div style={{
          width: 36, height: 36, borderRadius: 18,
          background: 'rgba(0,0,0,0.36)', backdropFilter: 'blur(20px)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" style={{ color: '#fff' }}>
            <path d="M4 16L8 12 4 8M20 16l-4-4 4-4M8 12h12" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
      </div>

      {/* Self PiP — top right */}
      <div style={{
        position: 'absolute', top: 100, right: 16,
        width: 96, height: 130, borderRadius: 14,
        background: `linear-gradient(150deg, ${s1} 0%, ${s2} 100%)`,
        overflow: 'hidden',
        boxShadow: '0 6px 20px rgba(0,0,0,0.30), 0 0 0 1px rgba(255,255,255,0.10) inset',
      }}>
        <svg width="100%" height="100%" preserveAspectRatio="xMidYMid slice" viewBox="0 0 100 130" style={{ position: 'absolute', inset: 0, opacity: 0.5 }}>
          <circle cx="50" cy="50" r="22" fill="rgba(255,255,255,0.35)"/>
          <ellipse cx="50" cy="120" rx="48" ry="36" fill="rgba(0,0,0,0.20)"/>
        </svg>
      </div>

      {/* Bottom floating controls */}
      <div style={{
        position: 'absolute', bottom: 38, left: 0, right: 0,
        display: 'flex', justifyContent: 'center', gap: 14,
        padding: '0 20px',
      }}>
        <CallBtn icon={CALL_ICONS.micOff} kind="active" size={54}/>
        <CallBtn icon={CALL_ICONS.video} size={54}/>
        <CallBtn icon={CALL_ICONS.flip} size={54}/>
        <CallBtn icon={CALL_ICONS.endCall} kind="danger" size={62}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 4. Call ended — summary card on chat-like background
// ════════════════════════════════════════════════════════════════════
function SnCallEnded({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* Mini header */}
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
        }}>Call details</div>
        <div style={{ width: 32 }}/>
      </div>

      {/* Hero */}
      <div style={{
        display: 'flex', flexDirection: 'column', alignItems: 'center',
        padding: '28px 24px 24px', gap: 12,
      }}>
        <SnAvatar name="Maria Chen" size={88}/>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}>
          <div style={{ fontSize: 24, fontWeight: 600, letterSpacing: -0.5, color: 'var(--sn-text)' }}>Maria Chen</div>
          <div style={{ fontSize: 14, fontWeight: 500, color: 'var(--sn-text-3)' }}>Today · 14:08</div>
        </div>
      </div>

      {/* Summary card */}
      <div style={{
        margin: '0 14px',
        background: 'var(--sn-surface)',
        borderRadius: 'var(--sn-radius-card)',
        boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
        overflow: 'hidden',
      }}>
        {[
          { label: 'Type', value: 'Audio · incoming',
            icon: (
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            ) },
          { label: 'Duration', value: '12m 14s',
            icon: (
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M12 7v5l3.5 2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            ) },
          { label: 'Status', value: 'Ended', valueColor: 'var(--sn-text-2)',
            icon: (
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            ), last: true },
        ].map((r, i, arr) => (
          <div key={r.label} style={{
            display: 'flex', alignItems: 'center', gap: 14,
            padding: '14px 20px', position: 'relative',
            minHeight: 56,
          }}>
            <div style={{
              width: 32, height: 32, borderRadius: 9,
              background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>{r.icon}</div>
            <div style={{ flex: 1, fontSize: 15, fontWeight: 500, color: 'var(--sn-text)' }}>{r.label}</div>
            <div style={{ fontSize: 15, fontWeight: 500, color: r.valueColor || 'var(--sn-text-2)' }}>{r.value}</div>
            {i < arr.length - 1 && (
              <div style={{ position: 'absolute', left: 66, right: 0, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
            )}
          </div>
        ))}
      </div>

      <div style={{ flex: 1 }}/>

      {/* Call back buttons */}
      <div style={{ padding: '0 20px 24px', display: 'flex', gap: 10 }}>
        <DsButton variant="secondary" leading={
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
          </svg>
        }>Audio</DsButton>
        <DsButton variant="primary" leading={
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
          </svg>
        }>Video</DsButton>
      </div>
    </div>
  );
}

Object.assign(window, { SnIncomingCall, SnInCallAudio, SnInCallVideo, SnCallEnded });
