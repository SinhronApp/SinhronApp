// group-calls.jsx — Sinhron group call UI
// Built for teams running their own server. Three layouts:
//   1. 2×2 grid — small calls, everyone equal size
//   2. 3×3 grid with raised-hand indicator — bigger rooms
//   3. Spotlight — one large speaker + filmstrip of the rest
//
// Exports: SnGroupCall2x2, SnGroupCall3x3, SnGroupCallSpotlight

// ─── Sample participants (a small product team) ─────────────────────
const SN_TEAM = [
  { name: 'Vera Kuznetsova', self: true,  mic: 'on'  },
  { name: 'Maria Chen',       speaking: true,         mic: 'on'  },
  { name: 'Henry Park',       mic: 'on'  },
  { name: 'Alex Müller',      mic: 'off', video: false },
  { name: 'Tasha Sokolova',   mic: 'on',  hand: true },
  { name: 'Nora Hayes',       mic: 'off' },
  { name: 'Sam Okonkwo',      mic: 'on'  },
  { name: 'Robin Vasquez',    mic: 'off', video: false },
  { name: 'Jordan Pierce',    mic: 'on',  hand: true },
];

// ─── Backdrop + tile primitives ─────────────────────────────────────
function GCallShell({ children, topPill }) {
  return (
    <div style={{
      width: '100%', height: '100%',
      position: 'relative', overflow: 'hidden',
      background: '#06090E',
      color: '#fff',
      fontFamily: "'Geist', sans-serif",
      display: 'flex', flexDirection: 'column',
    }}>
      {/* Ambient gradient — calls feel personal, not sterile */}
      <div style={{
        position: 'absolute', inset: 0,
        background: `
          radial-gradient(70% 50% at 20% 10%, rgba(45,111,247,0.18) 0%, transparent 60%),
          radial-gradient(80% 60% at 90% 100%, rgba(124,58,237,0.16) 0%, transparent 60%)
        `,
      }}/>

      {/* Top: connection pill + timer + leave-aware spacer */}
      <div style={{ position: 'relative', padding: '50px 16px 10px', display: 'flex', alignItems: 'center', gap: 10 }}>
        {topPill}
        <div style={{ flex: 1 }}/>
        <div style={{
          width: 36, height: 36, borderRadius: 18,
          background: 'rgba(255,255,255,0.10)', backdropFilter: 'blur(20px)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <rect x="3" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
            <rect x="14" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
            <rect x="3" y="14" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
            <rect x="14" y="14" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
          </svg>
        </div>
      </div>

      {children}
    </div>
  );
}

function GCallTopPill({ name = 'Engineering', count = 4, time = '12:18' }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 10,
      padding: '6px 14px 6px 8px', borderRadius: 999,
      background: 'rgba(255,255,255,0.10)', backdropFilter: 'blur(20px)',
    }}>
      <div style={{
        width: 22, height: 22, borderRadius: 11,
        background: 'linear-gradient(150deg, #A0C4FF 0%, #3B82F6 100%)',
        boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.20), inset 0 -1px 0 rgba(0,0,0,0.10)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: '#fff', flexShrink: 0,
      }}>
        <svg width="11" height="11" viewBox="0 0 24 24" fill="none">
          <circle cx="9" cy="9" r="3.5" fill="white"/>
          <circle cx="16.5" cy="9.5" r="2.7" fill="white" fillOpacity="0.75"/>
        </svg>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', lineHeight: 1.15 }}>
        <div style={{ fontSize: 13, fontWeight: 600, letterSpacing: -0.1 }}>{name} · {count}</div>
        <div className="sn-mono" style={{ fontSize: 10.5, fontWeight: 500, color: 'rgba(255,255,255,0.7)', letterSpacing: 0.2 }}>{time}</div>
      </div>
    </div>
  );
}

// ─── A single participant tile ──────────────────────────────────────
function ParticipantTile({ p, size = 'lg', spotlight = false, rounded = 18 }) {
  const [c1, c2] = SN_AVATAR_PALETTES[snHashIdx(p.name, SN_AVATAR_PALETTES.length)];
  const initials = snInitials(p.name);
  const videoOff = p.video === false;
  const avatarSize = { sm: 36, md: 56, lg: 76, xl: 110 }[size];
  const nameSize = { sm: 11, md: 12, lg: 13, xl: 15 }[size];

  return (
    <div style={{
      position: 'relative', borderRadius: rounded, overflow: 'hidden',
      background: videoOff
        ? '#0E141B'
        : `linear-gradient(150deg, ${c1} 0%, ${c2} 100%)`,
      boxShadow: p.speaking
        ? '0 0 0 2.5px #2BC58A, 0 6px 20px rgba(0,0,0,0.30)'
        : '0 0 0 0.5px rgba(255,255,255,0.10), 0 4px 14px rgba(0,0,0,0.25)',
      height: '100%', width: '100%',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
    }}>
      {/* "video" — soft scene from avatar palette */}
      {!videoOff && (
        <svg width="100%" height="100%" viewBox="0 0 100 130" preserveAspectRatio="xMidYMid slice"
          style={{ position: 'absolute', inset: 0, opacity: 0.55 }}>
          <circle cx="50" cy="46" r="22" fill="rgba(255,255,255,0.35)"/>
          <ellipse cx="50" cy="125" rx="55" ry="38" fill="rgba(0,0,0,0.22)"/>
        </svg>
      )}
      {/* video-off → big initials */}
      {videoOff && (
        <div style={{
          width: avatarSize, height: avatarSize, borderRadius: '50%',
          background: `linear-gradient(150deg, ${c1} 0%, ${c2} 100%)`,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: '#fff', fontSize: avatarSize * 0.38, fontWeight: 600, letterSpacing: 0.2,
          boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.20), inset 0 -1px 0 rgba(0,0,0,0.10)',
        }}>{initials}</div>
      )}

      {/* Top-left: raised hand */}
      {p.hand && (
        <div style={{
          position: 'absolute', top: 8, left: 8,
          padding: '4px 8px 4px 6px', borderRadius: 999,
          background: 'rgba(15,23,32,0.55)', backdropFilter: 'blur(12px)',
          display: 'flex', alignItems: 'center', gap: 4,
          fontSize: 11, fontWeight: 600, letterSpacing: -0.05,
        }}>
          <span style={{ fontSize: 12 }}>✋</span>
          {size !== 'sm' && 'Hand'}
        </div>
      )}

      {/* Top-right: pin/spotlight indicator */}
      {spotlight && size === 'xl' && (
        <div style={{
          position: 'absolute', top: 12, right: 12,
          padding: '5px 10px 5px 8px', borderRadius: 999,
          background: 'rgba(45,111,247,0.85)', color: '#fff',
          display: 'flex', alignItems: 'center', gap: 5,
          fontSize: 11.5, fontWeight: 600, letterSpacing: -0.05,
        }}>
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none">
            <path d="M12 2l4 4-1.5 1.5L17 10l-4 4-2.5-2.5L4 18v2h2l6.5-6.5L15 16l4-4-2.5-2.5L18 8l-4-4z" fill="currentColor"/>
          </svg>
          Spotlight
        </div>
      )}

      {/* Bottom-left: name + mic */}
      <div style={{
        position: 'absolute', left: 8, bottom: 8, right: 36,
        display: 'flex', alignItems: 'center', gap: 6,
      }}>
        <div style={{
          padding: '4px 8px', borderRadius: 8,
          background: 'rgba(15,23,32,0.55)', backdropFilter: 'blur(12px)',
          fontSize: nameSize, fontWeight: 600, letterSpacing: -0.1,
          maxWidth: '100%',
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
          display: 'flex', alignItems: 'center', gap: 6,
        }}>
          {p.self && <span style={{
            padding: '1px 5px', borderRadius: 4,
            background: 'rgba(255,255,255,0.18)', fontSize: nameSize - 2,
            fontWeight: 700, letterSpacing: 0.2,
          }}>YOU</span>}
          {p.self ? p.name.split(' ')[0] : p.name}
        </div>
      </div>
      {/* Bottom-right: mic state */}
      <div style={{
        position: 'absolute', right: 8, bottom: 8,
        width: 24, height: 24, borderRadius: 12,
        background: p.mic === 'off' ? '#FF4D4D' : 'rgba(15,23,32,0.55)',
        backdropFilter: 'blur(12px)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        {p.mic === 'off' ? (
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
            <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="#fff" strokeWidth="2"/>
            <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="#fff" strokeWidth="2" strokeLinecap="round"/>
            <path d="M3 3l18 18" stroke="#fff" strokeWidth="2.4" strokeLinecap="round"/>
          </svg>
        ) : (
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
            <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="#fff" strokeWidth="2" fill="#fff"/>
            <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="#fff" strokeWidth="2" strokeLinecap="round"/>
          </svg>
        )}
      </div>

      {/* speaking pulse — subtle inner ring */}
      {p.speaking && (
        <div style={{
          position: 'absolute', inset: 0, borderRadius: rounded,
          boxShadow: 'inset 0 0 0 1px rgba(43,197,138,0.45)',
          pointerEvents: 'none',
        }}/>
      )}
    </div>
  );
}

// ─── Bottom control dock — shared ───────────────────────────────────
function GCallControls({ raisedCount }) {
  const btn = (icon, kind = 'default') => {
    const pal = {
      default: { bg: 'rgba(255,255,255,0.14)', fg: '#fff' },
      active:  { bg: '#fff', fg: '#0B1016' },
      danger:  { bg: '#FF4D4D', fg: '#fff' },
    }[kind];
    return (
      <div style={{
        width: 52, height: 52, borderRadius: 26,
        background: pal.bg, color: pal.fg,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        backdropFilter: kind === 'default' ? 'blur(20px)' : 'none',
        boxShadow: kind === 'danger' ? '0 6px 20px rgba(255,77,77,0.45)' : 'none',
      }}>{icon}</div>
    );
  };

  return (
    <div style={{
      position: 'relative', padding: '14px 16px 38px',
      display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 10,
    }}>
      {btn(
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="2" fill="currentColor"/>
          <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
        </svg>
      )}
      {btn(
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="2"/>
          <path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
        </svg>,
        'active'
      )}
      <div style={{ position: 'relative' }}>
        {btn(<span style={{ fontSize: 22, lineHeight: 1 }}>✋</span>)}
        {raisedCount > 0 && (
          <div style={{
            position: 'absolute', top: -4, right: -4,
            minWidth: 20, height: 20, padding: '0 6px',
            borderRadius: 10, background: '#FFB800', color: '#0B1016',
            fontSize: 11, fontWeight: 700,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            border: '2px solid #06090E',
          }}>{raisedCount}</div>
        )}
      </div>
      {btn(
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <circle cx="11" cy="9" r="4" stroke="currentColor" strokeWidth="2"/>
          <path d="M3 21c0-4 3.2-7 7-7s7 3 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
          <path d="M19 6v6M16 9h6" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
        </svg>
      )}
      {btn(
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
          <path d="M3 12c0-2 5-5 9-5s9 3 9 5l-2 2-3-1-1-2c-2-1-4-1-6 0l-1 2-3 1-2-2z" fill="currentColor"/>
        </svg>,
        'danger'
      )}
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. 2×2 grid — 4 participants, equal weight
// ════════════════════════════════════════════════════════════════════
function SnGroupCall2x2({ dark = true, platform = 'ios' }) {
  const people = SN_TEAM.slice(0, 4);
  return (
    <GCallShell topPill={<GCallTopPill name="Engineering" count={4} time="12:18"/>}>
      <div style={{
        position: 'relative', flex: 1, padding: '6px 12px',
        display: 'grid', gridTemplateColumns: '1fr 1fr', gridTemplateRows: '1fr 1fr',
        gap: 8,
      }}>
        {people.map((p, i) => (
          <ParticipantTile key={i} p={p} size="lg"/>
        ))}
      </div>
      <GCallControls raisedCount={0}/>
    </GCallShell>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. 3×3 grid — 9 participants, includes raised hands
// ════════════════════════════════════════════════════════════════════
function SnGroupCall3x3({ dark = true, platform = 'ios' }) {
  const raised = SN_TEAM.filter(p => p.hand).length;
  return (
    <GCallShell topPill={<GCallTopPill name="All-hands" count={9} time="04:42"/>}>
      {/* Raised-hand banner — appears above the grid so the host sees it without scanning */}
      {raised > 0 && (
        <div style={{
          position: 'relative', margin: '0 16px 8px',
          padding: '8px 12px 8px 10px', borderRadius: 12,
          background: 'rgba(255, 184, 0, 0.18)',
          display: 'flex', alignItems: 'center', gap: 10,
          boxShadow: 'inset 0 0 0 0.5px rgba(255, 184, 0, 0.45)',
        }}>
          <span style={{ fontSize: 16 }}>✋</span>
          <div style={{ flex: 1, fontSize: 13, fontWeight: 600, letterSpacing: -0.1 }}>
            {raised} hands up
            <span style={{ color: 'rgba(255,255,255,0.6)', fontWeight: 500 }}> · Tasha, Jordan</span>
          </div>
          <div style={{ fontSize: 12.5, fontWeight: 600, color: '#FFB800' }}>View</div>
        </div>
      )}

      <div style={{
        position: 'relative', flex: 1, padding: '4px 12px',
        display: 'grid',
        gridTemplateColumns: 'repeat(3, 1fr)',
        gridAutoRows: '1fr',
        gap: 6,
      }}>
        {SN_TEAM.map((p, i) => (
          <ParticipantTile key={i} p={p} size="md" rounded={14}/>
        ))}
      </div>
      <GCallControls raisedCount={raised}/>
    </GCallShell>
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. Spotlight mode — one large + filmstrip
// ════════════════════════════════════════════════════════════════════
function SnGroupCallSpotlight({ dark = true, platform = 'ios' }) {
  const spotlight = SN_TEAM[1]; // Maria, speaking
  const others = SN_TEAM.filter(p => p !== spotlight);
  const raised = SN_TEAM.filter(p => p.hand).length;

  return (
    <GCallShell topPill={<GCallTopPill name="Engineering" count={9} time="08:04"/>}>
      {/* Spotlight tile — big */}
      <div style={{
        position: 'relative', margin: '4px 12px 8px',
        height: 360,
      }}>
        <ParticipantTile p={spotlight} size="xl" spotlight rounded={22}/>
      </div>

      {/* Filmstrip — horizontally scrollable */}
      <div style={{
        position: 'relative', padding: '0 12px 4px',
        display: 'flex', gap: 6, overflowX: 'hidden',
      }}>
        {others.slice(0, 5).map((p, i) => (
          <div key={i} style={{ width: 64, height: 80, flexShrink: 0 }}>
            <ParticipantTile p={p} size="sm" rounded={12}/>
          </div>
        ))}
        {/* "+N more" tile */}
        <div style={{
          width: 64, height: 80, borderRadius: 12,
          background: 'rgba(255,255,255,0.06)', backdropFilter: 'blur(20px)',
          boxShadow: 'inset 0 0 0 0.5px rgba(255,255,255,0.10)',
          display: 'flex', flexDirection: 'column', alignItems: 'center',
          justifyContent: 'center', gap: 4, flexShrink: 0,
        }}>
          <div style={{ fontSize: 16, fontWeight: 700, letterSpacing: -0.3 }}>+{others.length - 5}</div>
          <div style={{ fontSize: 10, fontWeight: 500, color: 'rgba(255,255,255,0.65)' }}>more</div>
        </div>
      </div>

      <div style={{ flex: 1 }}/>
      <GCallControls raisedCount={raised}/>
    </GCallShell>
  );
}

Object.assign(window, { SnGroupCall2x2, SnGroupCall3x3, SnGroupCallSpotlight });
