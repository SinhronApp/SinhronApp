// disappearing-active.jsx — Chat with disappearing messages enabled
// Two visible affordances throughout:
//   • Header subtitle replaced with "🕒 messages disappear after 1 day"
//   • Each bubble carries a small countdown ring chip beside the time
//
// The countdown is *visual* (not animated) — every message shows its remaining
// time at the moment of the screenshot. Engineers can wire animation in code.
//
// Exports: SnDisappearingActive

// ─── Countdown ring chip — SVG, fixed-frame ─────────────────────────
// `pct` 0..1 — fraction of TTL remaining
function CountdownChip({ label, pct = 0.65, onAccent = false }) {
  const r = 6, c = 2 * Math.PI * r;
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 4,
      fontSize: 10.5, fontWeight: 600,
      color: onAccent ? 'rgba(255,255,255,0.92)' : 'var(--sn-text-3)',
      letterSpacing: -0.05,
    }}>
      <svg width="14" height="14" viewBox="-7 -7 14 14" style={{ flexShrink: 0 }}>
        <circle r={r} cx="0" cy="0" fill="none" stroke={onAccent ? 'rgba(255,255,255,0.30)' : 'var(--sn-text-4)'} strokeWidth="1.5"/>
        <circle r={r} cx="0" cy="0" fill="none"
          stroke={onAccent ? '#fff' : 'var(--sn-accent)'}
          strokeWidth="1.5" strokeLinecap="round"
          strokeDasharray={c}
          strokeDashoffset={c * (1 - pct)}
          transform="rotate(-90)"/>
      </svg>
      {label}
    </span>
  );
}

// Bubble — extends the chat-view pattern with a trailing CountdownChip
function DAppBubble({ side = 'in', tail = true, ttl, time, read, children }) {
  const isOut = side === 'out';
  const align = isOut ? 'flex-end' : 'flex-start';
  const bg = isOut ? 'var(--sn-accent)' : 'var(--sn-surface)';
  const fg = isOut ? '#FFFFFF' : 'var(--sn-text)';
  const metaFg = isOut ? 'rgba(255,255,255,0.78)' : 'var(--sn-text-3)';
  const r = 18, rTail = 6;
  const radius = isOut
    ? `${r}px ${r}px ${tail ? rTail : r}px ${r}px`
    : `${r}px ${r}px ${r}px ${tail ? rTail : r}px`;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: align, padding: '1.5px 12px', marginTop: tail ? 6 : 1 }}>
      <div style={{
        maxWidth: '80%', minWidth: 80, background: bg, color: fg, borderRadius: radius,
        padding: '8px 12px 7px', fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
        boxShadow: isOut ? '0 1px 1px rgba(45,111,247,0.18)' : '0 1px 1px rgba(15,23,32,0.05)',
      }}>
        {children}
        <div style={{
          display: 'inline-flex', alignItems: 'center', gap: 8,
          float: 'right', marginLeft: 10, marginTop: 4, marginBottom: -2,
          fontSize: 11, fontWeight: 500, color: metaFg, letterSpacing: -0.05,
        }}>
          {ttl && <CountdownChip label={ttl.label} pct={ttl.pct} onAccent={isOut}/>}
          <span>{time}</span>
          {isOut && (
            <svg width="14" height="10" viewBox="0 0 22 14" fill="none">
              <path d="M1 7l4.5 4.5L13 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              {read && <path d="M9 7l4.5 4.5L21 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>}
            </svg>
          )}
        </div>
      </div>
    </div>
  );
}

// ─── Header with disappearing-mode subtitle pill ────────────────────
function DAppHeader({ name = 'Maria Chen' }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '8px 14px 10px',
      borderBottom: '0.5px solid var(--sn-divider)',
    }}>
      <div style={{ width: 32, height: 32, color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center', marginLeft: -6 }}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </div>
      <SnAvatar name={name} size={36} online/>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: -0.2, color: 'var(--sn-text)' }}>{name}</div>
        <div style={{
          display: 'inline-flex', alignItems: 'center', gap: 5,
          fontSize: 12, fontWeight: 600, color: 'var(--sn-accent)', letterSpacing: -0.05,
          marginTop: 1,
        }}>
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
            <circle cx="12" cy="13" r="8" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M12 9v4l3 2M8 3l-2 3M16 3l2 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
          Disappearing · 1 day
        </div>
      </div>
      <div style={{ width: 36, height: 36, color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="1.8"/>
          <path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        </svg>
      </div>
      <div style={{ width: 36, height: 36, color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        </svg>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// SnDisappearingActive — chat with timers running
// ════════════════════════════════════════════════════════════════════
function SnDisappearingActive({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DAppHeader name="Maria Chen"/>

      <div className="sn-scroll" style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: '8px 0' }}>
        {/* System pill — disappearing turned on */}
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 14px' }}>
          <div style={{
            display: 'inline-flex', alignItems: 'center', gap: 8,
            padding: '7px 14px 7px 12px',
            background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
            borderRadius: 999,
            fontSize: 12.5, fontWeight: 600, letterSpacing: -0.05,
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
              <circle cx="12" cy="13" r="8" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M12 9v4l3 2M8 3l-2 3M16 3l2 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
            You set messages to disappear after 1 day
          </div>
        </div>

        {/* Day */}
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Yesterday</div>
        </div>

        {/* Older bubbles — small remaining ring (~10–15%) */}
        <DAppBubble side="in" time="20:42" ttl={{ label: '2h', pct: 0.08 }}>
          shall we move the standup to 10? mornings are chaotic this week
        </DAppBubble>
        <DAppBubble side="out" time="20:44" ttl={{ label: '2h', pct: 0.09 }} read>
          works for me — locking it in
        </DAppBubble>

        {/* Day */}
        <div style={{ display: 'flex', justifyContent: 'center', padding: '12px 0 6px' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Today</div>
        </div>

        {/* Middle bubbles — about 40-60% */}
        <DAppBubble side="in" time="09:08" ttl={{ label: '14h', pct: 0.58 }}>
          got a new contractor coming in this afternoon, BTW
        </DAppBubble>
        <DAppBubble side="in" tail={false} time="09:08" ttl={{ label: '14h', pct: 0.58 }}>
          can you drop them in the eng group?
        </DAppBubble>
        <DAppBubble side="out" time="09:12" ttl={{ label: '14h', pct: 0.59 }} read>
          done. her username is <span className="sn-mono" style={{ background: 'rgba(255,255,255,0.18)', padding: '0 5px', borderRadius: 4 }}>@vlado</span>
        </DAppBubble>

        {/* Recent — almost full ring */}
        <DAppBubble side="in" time="13:21" ttl={{ label: '23h', pct: 0.96 }}>
          🙏 perfect
        </DAppBubble>
        <DAppBubble side="out" time="13:22" ttl={{ label: '23h', pct: 0.97 }} read>
          ttyl
        </DAppBubble>
      </div>

      {/* Composer — accent pill prompt so it's obvious messages will burn */}
      <div style={{
        display: 'flex', alignItems: 'flex-end', gap: 8,
        padding: '8px 10px 10px',
        background: 'var(--sn-bg)',
        borderTop: '0.5px solid var(--sn-divider)',
      }}>
        <div style={{
          width: 36, height: 36, borderRadius: '50%',
          background: 'var(--sn-bg-soft)', color: 'var(--sn-text-2)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
          </svg>
        </div>
        <div style={{
          flex: 1, minHeight: 36, borderRadius: 18,
          background: 'var(--sn-bg-soft)',
          display: 'flex', alignItems: 'center', gap: 8,
          padding: '0 14px',
        }}>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-accent)', flexShrink: 0 }}>
            <circle cx="12" cy="13" r="8" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M12 9v4l3 2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
          <div style={{
            flex: 1, fontSize: 15, color: 'var(--sn-text-3)', letterSpacing: -0.15,
          }}>Disappears in 1 day…</div>
        </div>
        <div style={{
          width: 36, height: 36, borderRadius: '50%',
          background: 'var(--sn-accent)', color: '#fff',
          display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
          boxShadow: '0 2px 6px rgba(45,111,247,0.30)',
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="2" fill="currentColor"/>
            <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
          </svg>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SnDisappearingActive });
