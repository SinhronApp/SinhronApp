// chat-events.jsx — System messages inside a chat (MLS-driven events)
// Maps to RFC 9420 Commits: Add / Remove / Update + app-level events:
//   add member, remove member, leave, group rename, group photo,
//   missed call, disappearing-messages set, safety-number changed,
//   epoch-update silent indicator (subtle).
//
// Exports: SnChatEvents

// ─── Centered pill style — neutral, dim, monospaced details ──────────
function EventPill({ icon, text, tone = 'neutral' }) {
  const palette = {
    neutral: { bg: 'var(--sn-bg-soft)', fg: 'var(--sn-text-2)', iconFg: 'var(--sn-text-3)' },
    accent:  { bg: 'var(--sn-accent-soft)', fg: 'var(--sn-accent)', iconFg: 'var(--sn-accent)' },
    warn:    { bg: 'rgba(217, 119, 6, 0.14)', fg: '#C2410C', iconFg: '#C2410C' },
    danger:  { bg: 'rgba(255, 77, 77, 0.14)', fg: '#D03A3A', iconFg: '#D03A3A' },
  }[tone];
  return (
    <div style={{ display: 'flex', justifyContent: 'center', padding: '6px 14px' }}>
      <div style={{
        display: 'inline-flex', alignItems: 'center', gap: 8,
        padding: '6px 12px 6px 10px',
        background: palette.bg, color: palette.fg,
        borderRadius: 999, maxWidth: '85%',
        fontSize: 12.5, fontWeight: 500, letterSpacing: -0.05,
        lineHeight: '17px',
      }}>
        {icon && <span style={{ color: palette.iconFg, display: 'inline-flex' }}>{icon}</span>}
        <span style={{ minWidth: 0, textAlign: 'center' }}>{text}</span>
      </div>
    </div>
  );
}

// ─── Lightweight bubble (we don't pull in chat-view's Bubble to keep
// this file independent of insertion-order in index.html) ─────────────
function EvBubble({ side = 'in', tail = true, sender, senderColor, children, time, read }) {
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
        maxWidth: '78%', minWidth: 60, background: bg, color: fg, borderRadius: radius,
        padding: '8px 12px 7px', fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
        boxShadow: isOut ? '0 1px 1px rgba(45,111,247,0.18)' : '0 1px 1px rgba(15,23,32,0.05)',
      }}>
        {sender && (
          <div style={{
            fontSize: 12.5, fontWeight: 600,
            color: senderColor || 'var(--sn-accent)',
            letterSpacing: -0.1,
            marginBottom: 2,
          }}>{sender}</div>
        )}
        {children}
        <div style={{
          display: 'inline-flex', alignItems: 'center', gap: 4,
          float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
          fontSize: 11, fontWeight: 500, color: metaFg, letterSpacing: -0.05,
        }}>
          {time}
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

// ─── Group header shared with groups.jsx (kept inline for independence) ─
function EvHeader({ name, subtitle }) {
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
      <SnAvatar name={name} size={36} group/>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: -0.2, color: 'var(--sn-text)' }}>{name}</div>
        <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)' }}>{subtitle}</div>
      </div>
      <div style={{ width: 36, height: 36, color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/>
          <path d="M16.5 16.5L21 21" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
        </svg>
      </div>
    </div>
  );
}

// Sender color (small palette per name — same scheme as groups.jsx)
const EV_SENDER_COLORS = ['#FF6E54', '#10B981', '#7C3AED', '#F59E0B', '#3B82F6', '#EC4899', '#65A30D', '#E0683B', '#0EA5A5', '#A21CAF'];
function snSenderColor(name) {
  return EV_SENDER_COLORS[snHashIdx(name, EV_SENDER_COLORS.length)];
}

// Icons used in event pills (small)
const EV_ICONS = {
  add: <svg width="13" height="13" viewBox="0 0 24 24" fill="none"><circle cx="11" cy="9" r="4" stroke="currentColor" strokeWidth="1.8"/><path d="M3 21c0-4 3.2-7 7-7s7 3 7 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M19 6v6M16 9h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></svg>,
  leave: <svg width="13" height="13" viewBox="0 0 24 24" fill="none"><path d="M14 4h5a1 1 0 011 1v14a1 1 0 01-1 1h-5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M9 8l-4 4 4 4M5 12h11" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></svg>,
  rename: <svg width="13" height="13" viewBox="0 0 24 24" fill="none"><path d="M16.5 3.5l4 4-12 12H4.5v-4l12-12z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><path d="M13.5 6.5l4 4" stroke="currentColor" strokeWidth="1.8"/></svg>,
  photo: <svg width="13" height="13" viewBox="0 0 24 24" fill="none"><rect x="3" y="5" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/><circle cx="9" cy="11" r="2" stroke="currentColor" strokeWidth="1.8"/><path d="M3 17l5-4 4 3 3-2 6 5" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></svg>,
  call: <svg width="13" height="13" viewBox="0 0 24 24" fill="none"><path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></svg>,
  timer: <svg width="13" height="13" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="13" r="8" stroke="currentColor" strokeWidth="1.8"/><path d="M12 9v4l3 2M8 3l-2 3M16 3l2 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></svg>,
  shield: <svg width="13" height="13" viewBox="0 0 24 24" fill="none"><path d="M12 3l9 4v6c0 5-4 9-9 10-5-1-9-5-9-10V7l9-4z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><path d="M12 8v5M12 16v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></svg>,
  refresh: <svg width="13" height="13" viewBox="0 0 24 24" fill="none"><path d="M21 5v6h-6M3 19v-6h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/><path d="M19 11a8 8 0 00-14-3M5 13a8 8 0 0014 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></svg>,
};

// ════════════════════════════════════════════════════════════════════
// SnChatEvents — group chat populated with every system-event variant
// ════════════════════════════════════════════════════════════════════
function SnChatEvents({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <EvHeader name="Engineering" subtitle="6 members · 3 online"/>

      <div className="sn-scroll" style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: '8px 0' }}>
        {/* Day label */}
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Yesterday</div>
        </div>

        {/* MLS Add — Tasha added Maria */}
        <EventPill icon={EV_ICONS.add} text={<span><b style={{ color: 'var(--sn-text)', fontWeight: 600 }}>Tasha</b> added <b style={{ color: 'var(--sn-text)', fontWeight: 600 }}>Maria Chen</b></span>}/>

        <EvBubble side="in" sender="Maria Chen" senderColor={snSenderColor('Maria Chen')} time="14:02">
          hi everyone 👋 happy to be here
        </EvBubble>

        <EvBubble side="in" sender="Alex Park" senderColor={snSenderColor('Alex Park')} time="14:04">
          welcome 🎉
        </EvBubble>

        {/* Group rename */}
        <EventPill icon={EV_ICONS.rename}
          text={<span><b style={{ color: 'var(--sn-text)', fontWeight: 600 }}>Henry</b> renamed the group to <span className="sn-mono" style={{ color: 'var(--sn-text)', fontSize: 12, padding: '0 2px' }}>"Engineering"</span></span>}/>

        {/* Photo */}
        <EventPill icon={EV_ICONS.photo}
          text={<span><b style={{ color: 'var(--sn-text)', fontWeight: 600 }}>Henry</b> changed the group photo</span>}/>

        {/* Disappearing on */}
        <EventPill tone="accent" icon={EV_ICONS.timer}
          text={<span><b style={{ color: 'var(--sn-accent)', fontWeight: 700 }}>Tasha</b> set messages to disappear after <b style={{ fontWeight: 700 }}>1 day</b></span>}/>

        <EvBubble side="out" time="14:31" read>
          OK, archiving the old thread then 📦
        </EvBubble>

        {/* Day label */}
        <div style={{ display: 'flex', justifyContent: 'center', padding: '12px 0 6px' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Today</div>
        </div>

        {/* Missed call */}
        <EventPill icon={EV_ICONS.call}
          text={<span>Missed call from <b style={{ color: 'var(--sn-text)', fontWeight: 600 }}>Henry</b> · 4m</span>}/>

        <EvBubble side="in" sender="Henry Park" senderColor={snSenderColor('Henry Park')} time="09:15">
          sorry, just woke up — call back in 5?
        </EvBubble>

        {/* Safety number changed — single most important "show" of E2EE */}
        <EventPill tone="warn" icon={EV_ICONS.shield}
          text={<span>Safety number with <b style={{ color: '#C2410C', fontWeight: 700 }}>Maria Chen</b> changed · <b style={{ fontWeight: 700 }}>Verify</b></span>}/>

        <EvBubble side="in" sender="Maria Chen" senderColor={snSenderColor('Maria Chen')} time="09:18">
          got a new phone last night — same me 🙂
        </EvBubble>

        {/* Member leaves */}
        <EventPill icon={EV_ICONS.leave}
          text={<span><b style={{ color: 'var(--sn-text)', fontWeight: 600 }}>Vera</b> left the group</span>}/>

        <EvBubble side="in" sender="Tasha Lim" senderColor={snSenderColor('Tasha Lim')} time="11:02">
          fwiw she said she'd be back after vacation
        </EvBubble>

        {/* Epoch update — silent maintenance line, very dim, mono details */}
        <EventPill icon={EV_ICONS.refresh}
          text={<span style={{ color: 'var(--sn-text-3)' }}>Group keys refreshed <span className="sn-mono" style={{ fontSize: 11, color: 'var(--sn-text-4)', marginLeft: 4 }}>· epoch 248</span></span>}/>

        <EvBubble side="out" time="11:14" read>
          all good — let's move on
        </EvBubble>
      </div>

      {/* Composer (real, simple) */}
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
          background: 'var(--sn-bg-soft)', padding: '0 14px',
          display: 'flex', alignItems: 'center',
          fontSize: 15, color: 'var(--sn-text-3)', letterSpacing: -0.15,
        }}>Message</div>
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

Object.assign(window, { SnChatEvents });
