// chat-view.jsx — Sinhron 1:1 chat screen
// Uses tokens from app/tokens.css. Theme via parent class .sn-theme-light / .sn-theme-dark
// Exports: SinhronChatView

// ─── Header ─────────────────────────────────────────────────────────
function ChatHeader({ name = 'Maria Chen', status = 'online' }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '8px 14px 10px',
      background: 'var(--sn-bg)',
      borderBottom: '0.5px solid var(--sn-divider)',
      position: 'relative', zIndex: 4,
    }}>
      {/* back */}
      <button style={{
        width: 32, height: 32, borderRadius: 10, border: 'none',
        background: 'transparent', padding: 0, cursor: 'pointer',
        color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center',
        marginLeft: -6,
      }}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </button>

      <SnAvatar name={name} size={36} online={status === 'online'}/>

      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 1 }}>
        <div style={{
          fontSize: 15, fontWeight: 600, letterSpacing: -0.2,
          color: 'var(--sn-text)',
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>{name}</div>
        <div style={{
          fontSize: 12, fontWeight: 500, letterSpacing: -0.05,
          color: status === 'online' ? 'var(--sn-success)' : 'var(--sn-text-3)',
        }}>{status === 'online' ? 'online' : status}</div>
      </div>

      {/* video */}
      <button style={{
        width: 36, height: 36, borderRadius: 10, border: 'none',
        background: 'transparent', padding: 0, cursor: 'pointer',
        color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="1.8"/>
          <path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        </svg>
      </button>
      {/* call */}
      <button style={{
        width: 36, height: 36, borderRadius: 10, border: 'none',
        background: 'transparent', padding: 0, cursor: 'pointer',
        color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        </svg>
      </button>
    </div>
  );
}

// ─── Day separator ──────────────────────────────────────────────────
function DaySep({ label = 'Today' }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'center', padding: '12px 0 6px' }}>
      <div style={{
        padding: '4px 12px', borderRadius: 999,
        background: 'var(--sn-bg-soft)',
        fontSize: 11, fontWeight: 600, letterSpacing: 0.2,
        color: 'var(--sn-text-3)',
        textTransform: 'uppercase',
      }}>{label}</div>
    </div>
  );
}

// ─── Bubble ─────────────────────────────────────────────────────────
function Bubble({
  side = 'in', // 'in' | 'out'
  tail = true,
  text,
  time,
  read,
  reactions,   // [{ emoji, count }]
  reply,       // { name, text }
  children,
}) {
  const isOut = side === 'out';
  const align = isOut ? 'flex-end' : 'flex-start';
  const bg = isOut ? 'var(--sn-accent)' : 'var(--sn-surface)';
  const fg = isOut ? '#FFFFFF' : 'var(--sn-text)';
  const metaFg = isOut ? 'rgba(255,255,255,0.78)' : 'var(--sn-text-3)';

  // Tail radius cluster
  const r = 18, rTail = 6;
  const radius = isOut
    ? `${r}px ${r}px ${tail ? rTail : r}px ${r}px`
    : `${r}px ${r}px ${r}px ${tail ? rTail : r}px`;

  return (
    <div style={{
      display: 'flex', flexDirection: 'column', alignItems: align,
      padding: '1.5px 12px',
      marginTop: tail ? 6 : 1,
    }}>
      <div style={{
        maxWidth: '78%', minWidth: 60,
        background: bg, color: fg,
        borderRadius: radius,
        padding: '8px 12px 7px',
        boxShadow: isOut
          ? '0 1px 1px rgba(45,111,247,0.18)'
          : '0 1px 1px rgba(15,23,32,0.05)',
        position: 'relative',
        fontSize: 15, fontWeight: 400, letterSpacing: -0.15,
        lineHeight: '20px',
        wordBreak: 'break-word',
      }}>
        {/* Reply quote */}
        {reply && (
          <div style={{
            display: 'flex', gap: 8, padding: '4px 8px 5px',
            background: isOut ? 'rgba(255,255,255,0.16)' : 'var(--sn-accent-soft)',
            borderRadius: 8, marginBottom: 6,
            borderLeft: `3px solid ${isOut ? 'rgba(255,255,255,0.7)' : 'var(--sn-accent)'}`,
          }}>
            <div style={{ minWidth: 0 }}>
              <div style={{
                fontSize: 12, fontWeight: 600,
                color: isOut ? '#fff' : 'var(--sn-accent)',
                letterSpacing: -0.1,
              }}>{reply.name}</div>
              <div style={{
                fontSize: 12.5,
                color: isOut ? 'rgba(255,255,255,0.85)' : 'var(--sn-text-2)',
                whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                maxWidth: 220,
              }}>{reply.text}</div>
            </div>
          </div>
        )}

        {children}
        {text && <div>{text}</div>}

        {/* Meta — time + read tick */}
        {(time || read != null) && (
          <div style={{
            display: 'inline-flex', alignItems: 'center', gap: 4,
            float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
            fontSize: 11, fontWeight: 500, letterSpacing: -0.05,
            color: metaFg, userSelect: 'none',
            whiteSpace: 'nowrap', flexShrink: 0,
          }}>
            <span>{time}</span>
            {isOut && (
              <svg width="14" height="10" viewBox="0 0 22 14" fill="none">
                <path d="M1 7l4.5 4.5L13 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
                {read && <path d="M9 7l4.5 4.5L21 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" fill="none"/>}
              </svg>
            )}
          </div>
        )}
      </div>

      {/* Reactions */}
      {reactions && reactions.length > 0 && (
        <div style={{
          display: 'flex', gap: 4, marginTop: -10, marginRight: isOut ? 8 : 0, marginLeft: isOut ? 0 : 8,
          zIndex: 1,
        }}>
          {reactions.map((r, i) => (
            <div key={i} style={{
              display: 'inline-flex', alignItems: 'center', gap: 3,
              padding: '3px 8px 3px 6px',
              borderRadius: 999,
              background: 'var(--sn-surface)',
              boxShadow: '0 1px 2px rgba(15,23,32,0.10), 0 0 0 0.5px var(--sn-divider-strong)',
              fontSize: 13, fontWeight: 600,
              color: 'var(--sn-text-2)',
            }}>
              <span style={{ fontSize: 13 }}>{r.emoji}</span>
              {r.count > 1 && <span style={{ fontSize: 11, fontWeight: 700 }}>{r.count}</span>}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ─── Voice bubble ───────────────────────────────────────────────────
function VoiceContent({ duration = '0:42', played = false, isOut }) {
  // Build a waveform — varied amplitudes
  const samples = [3,5,8,12,9,14,18,16,11,8,12,16,20,18,14,10,7,11,15,19,17,13,9,6,10,14,12,8,5,9,13,16,14,10,7,4,8];
  const baseColor = isOut ? 'rgba(255,255,255,0.45)' : 'var(--sn-text-4)';
  const playedColor = isOut ? '#fff' : 'var(--sn-accent)';
  const cut = played ? samples.length : Math.floor(samples.length * 0.35);

  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '2px 2px 2px 0', minWidth: 200 }}>
      <div style={{
        width: 34, height: 34, borderRadius: '50%',
        background: isOut ? 'rgba(255,255,255,0.22)' : 'var(--sn-accent)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: '#fff', flexShrink: 0,
      }}>
        <svg width="12" height="14" viewBox="0 0 12 14" fill="none">
          <path d="M1 1l10 6-10 6z" fill="currentColor"/>
        </svg>
      </div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 4, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 1.5, height: 24 }}>
          {samples.map((amp, i) => (
            <div key={i} style={{
              width: 2, height: amp, borderRadius: 1.5,
              background: i < cut ? playedColor : baseColor,
            }}/>
          ))}
        </div>
        <div style={{
          fontSize: 11, fontWeight: 500, letterSpacing: 0.2,
          color: isOut ? 'rgba(255,255,255,0.78)' : 'var(--sn-text-3)',
        }}>{duration}</div>
      </div>
    </div>
  );
}

// ─── Photo bubble ───────────────────────────────────────────────────
function PhotoContent({ caption }) {
  return (
    <div style={{ margin: -8, marginBottom: caption ? 6 : -7, borderRadius: 12, overflow: 'hidden' }}>
      <div style={{
        width: 220, height: 160,
        background: 'linear-gradient(135deg, #FFB089 0%, #FF6E54 35%, #C5A0FF 75%, #7C3AED 100%)',
        position: 'relative',
      }}>
        {/* Abstract scene */}
        <svg width="100%" height="100%" viewBox="0 0 220 160" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
          <circle cx="170" cy="40" r="22" fill="rgba(255,255,255,0.5)"/>
          <path d="M0 130 Q 55 100 110 120 T 220 110 L 220 160 L 0 160 Z" fill="rgba(15,23,32,0.30)"/>
          <path d="M0 145 Q 70 125 140 140 T 220 130 L 220 160 L 0 160 Z" fill="rgba(15,23,32,0.45)"/>
        </svg>
      </div>
      {caption && (
        <div style={{ padding: '8px 4px 0', fontSize: 15, lineHeight: '20px' }}>{caption}</div>
      )}
    </div>
  );
}

// ─── Typing indicator ───────────────────────────────────────────────
function TypingDots() {
  return (
    <div style={{ display: 'flex', justifyContent: 'flex-start', padding: '4px 12px' }}>
      <div style={{
        background: 'var(--sn-surface)',
        borderRadius: '18px 18px 18px 6px',
        padding: '10px 14px',
        boxShadow: '0 1px 1px rgba(15,23,32,0.05)',
        display: 'flex', gap: 4, alignItems: 'center',
      }}>
        {[0,1,2].map(i => (
          <div key={i} style={{
            width: 6, height: 6, borderRadius: 3,
            background: 'var(--sn-text-3)',
            opacity: 0.5,
          }}/>
        ))}
      </div>
    </div>
  );
}

// ─── Composer ───────────────────────────────────────────────────────
function Composer({ platform }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'flex-end', gap: 8,
      padding: '8px 10px 10px',
      background: 'var(--sn-bg)',
      borderTop: '0.5px solid var(--sn-divider)',
    }}>
      {/* Plus / attach */}
      <button style={{
        width: 36, height: 36, borderRadius: '50%', border: 'none',
        background: 'var(--sn-bg-soft)', padding: 0, cursor: 'pointer',
        color: 'var(--sn-text-2)',
        display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
      }}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
        </svg>
      </button>

      {/* Input pill */}
      <div style={{
        flex: 1, minHeight: 36, borderRadius: 18,
        background: 'var(--sn-bg-soft)',
        display: 'flex', alignItems: 'center', gap: 8,
        padding: '0 6px 0 14px',
      }}>
        <div style={{
          flex: 1,
          fontSize: 15, color: 'var(--sn-text-3)', letterSpacing: -0.15,
          padding: '8px 0',
        }}>Message</div>
        <button style={{
          width: 28, height: 28, borderRadius: '50%', border: 'none',
          background: 'transparent', padding: 0, cursor: 'pointer',
          color: 'var(--sn-text-3)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.6"/>
            <path d="M8.5 14c.7 1 1.9 1.7 3.5 1.7s2.8-.7 3.5-1.7" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" fill="none"/>
            <circle cx="9" cy="10" r="1.1" fill="currentColor"/>
            <circle cx="15" cy="10" r="1.1" fill="currentColor"/>
          </svg>
        </button>
      </div>

      {/* Mic / send */}
      <button style={{
        width: 36, height: 36, borderRadius: '50%', border: 'none',
        background: 'var(--sn-accent)', padding: 0, cursor: 'pointer',
        color: '#fff',
        display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
        boxShadow: '0 2px 6px rgba(45,111,247,0.30)',
      }}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="2" fill="currentColor"/>
          <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
        </svg>
      </button>
    </div>
  );
}

// ─── Full screen ────────────────────────────────────────────────────
function SinhronChatView({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <ChatHeader name="Maria Chen" status="online"/>

      <div className="sn-scroll" style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
        <DaySep label="Yesterday"/>

        <Bubble side="in" time="20:14" text="Hey! Are we still on for coffee tomorrow?"/>
        <Bubble side="out" time="20:16" read
          text="Of course — same place at 9?"/>
        <Bubble side="in" tail={false}>
          <PhotoContent caption="Found this new spot ☀️"/>
        </Bubble>
        <Bubble side="in" time="20:18"
          text="Actually, let's try here instead. Their pour-over is unreal."
          reactions={[{ emoji: '🔥', count: 1 }]}/>

        <DaySep label="Today"/>

        <Bubble side="out" time="08:42" read
          reply={{ name: 'Maria Chen', text: 'Their pour-over is unreal.' }}
          text="Sold. See you at 9 ☕"/>

        <Bubble side="in" tail={false}>
          <VoiceContent duration="0:14" isOut={false}/>
        </Bubble>
        <Bubble side="in" time="08:51"
          text="Sounds great — see you at 9 tomorrow ☕"
          reactions={[{ emoji: '❤️', count: 1 }]}/>

        <Bubble side="out" time="09:02" read
          text="On my way, 2 mins out"/>

        <TypingDots/>
      </div>

      <Composer platform={platform}/>
    </div>
  );
}

Object.assign(window, { SinhronChatView });
