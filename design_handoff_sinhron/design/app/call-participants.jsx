// call-participants.jsx — Group call participants modal with host-actions
// Bottom sheet over the 3×3 grid. Shows all 9 participants with status icons
// (mic, video, hand), and exposes host-only actions on tap: Mute, Make
// co-host, Remove from call. Host's own row shows "You · host" pill.
//
// Exports: SnCallParticipants

const PARTICIPANTS = [
  { name: 'Vera Kuznetsova', role: 'host', mic: 'on',  video: true,  self: true },
  { name: 'Maria Chen',       role: 'cohost', mic: 'on', video: true,  speaking: true },
  { name: 'Henry Park',       mic: 'on',  video: true },
  { name: 'Alex Müller',      mic: 'off', video: false },
  { name: 'Tasha Sokolova',   mic: 'on',  video: true,  hand: true },
  { name: 'Nora Hayes',       mic: 'off', video: true },
  { name: 'Sam Okonkwo',      mic: 'on',  video: true },
  { name: 'Robin Vasquez',    mic: 'off', video: false },
  { name: 'Jordan Pierce',    mic: 'on',  video: true,  hand: true },
];

function StatusDot({ icon, on }) {
  return (
    <div style={{
      width: 22, height: 22, borderRadius: 11,
      background: on ? 'rgba(255,255,255,0.16)' : 'rgba(255,77,77,0.18)',
      color: on ? 'rgba(255,255,255,0.92)' : '#FF8888',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      flexShrink: 0,
    }}>{icon}</div>
  );
}

function RoleChip({ role, self }) {
  if (!role && !self) return null;
  const labels = [];
  if (self) labels.push('You');
  if (role === 'host') labels.push('Host');
  else if (role === 'cohost') labels.push('Co-host');
  const text = labels.join(' · ');
  return (
    <div style={{
      padding: '2px 7px', borderRadius: 6,
      background: role === 'host' || self
        ? 'rgba(45,111,247,0.28)'
        : 'rgba(255,255,255,0.12)',
      color: role === 'host' || self ? '#9DBEFF' : 'rgba(255,255,255,0.78)',
      fontSize: 10.5, fontWeight: 700, letterSpacing: 0.2, textTransform: 'uppercase',
      flexShrink: 0,
    }}>{text}</div>
  );
}

function ParticipantRow({ p, expanded }) {
  return (
    <div style={{
      display: 'flex', flexDirection: 'column',
      padding: '12px 16px',
      borderBottom: '0.5px solid rgba(255,255,255,0.08)',
      background: expanded ? 'rgba(45,111,247,0.10)' : 'transparent',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <SnAvatar name={p.name} size={36}/>
        <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 8,
            fontSize: 14.5, fontWeight: 600, letterSpacing: -0.15, color: '#fff',
          }}>
            <span style={{
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
              maxWidth: 180,
            }}>{p.name}</span>
            <RoleChip role={p.role} self={p.self}/>
          </div>
          <div style={{
            fontSize: 12, fontWeight: 500, letterSpacing: -0.05,
            color: p.speaking ? '#5DE5A8' : 'rgba(255,255,255,0.55)',
          }}>
            {p.speaking ? 'speaking' : (p.hand ? 'hand raised' : (p.mic === 'off' ? 'muted' : 'listening'))}
          </div>
        </div>

        {p.hand && (
          <div style={{
            padding: '4px 8px 4px 6px', borderRadius: 999,
            background: 'rgba(255, 184, 0, 0.20)', color: '#FFB800',
            display: 'flex', alignItems: 'center', gap: 4,
            fontSize: 11, fontWeight: 700, letterSpacing: 0.2,
          }}>
            <span>✋</span>
            {!expanded && '02:14'}
          </div>
        )}

        <StatusDot on={p.mic === 'on'} icon={
          p.mic === 'off' ? (
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
              <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="2"/>
              <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
              <path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"/>
            </svg>
          ) : (
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
              <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="2" fill="currentColor"/>
              <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
            </svg>
          )
        }/>
        <StatusDot on={p.video === true} icon={
          p.video === false ? (
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
              <rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="2"/>
              <path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
              <path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"/>
            </svg>
          ) : (
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
              <rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="2"/>
              <path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
            </svg>
          )
        }/>
      </div>

      {/* Host-action row — shown when this participant is the selected/expanded one */}
      {expanded && (
        <div style={{
          display: 'flex', gap: 8, marginTop: 12, paddingLeft: 48,
        }}>
          {[
            { label: 'Lower hand', icon: <svg width="14" height="14" viewBox="0 0 24 24" fill="none"><path d="M9 3v9M12 2v10M15 3v9M18 6v8a6 6 0 01-12 0v-2l-2-3 2-2 2 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></svg> },
            { label: 'Mute', icon: <svg width="14" height="14" viewBox="0 0 24 24" fill="none"><rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="1.8"/><path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"/></svg> },
            { label: 'Make co-host', icon: <svg width="14" height="14" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="9" r="4" stroke="currentColor" strokeWidth="1.8"/><path d="M4 21c0-4 3.6-7 8-7s8 3 8 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M16 4l2 2 4-4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></svg> },
            { label: 'Remove', icon: <svg width="14" height="14" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="9" r="4" stroke="currentColor" strokeWidth="1.8"/><path d="M4 21c0-4 3.6-7 8-7s8 3 8 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M16 4l5 5M21 4l-5 5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></svg>, danger: true },
          ].map(a => (
            <div key={a.label} style={{
              padding: '6px 10px 6px 8px', borderRadius: 999,
              background: a.danger ? 'rgba(255,77,77,0.20)' : 'rgba(255,255,255,0.10)',
              color: a.danger ? '#FF8888' : '#fff',
              display: 'inline-flex', alignItems: 'center', gap: 5,
              fontSize: 12, fontWeight: 600, letterSpacing: -0.05,
            }}>
              {a.icon}
              {a.label}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function SnCallParticipants({ dark = true, platform = 'ios' }) {
  // Tasha (raised hand, index 4) is "selected" so we can show host actions.
  const expandedIdx = 4;

  return (
    <div style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden' }}>
      {/* 3×3 grid behind */}
      <SnGroupCall3x3/>

      {/* Scrim */}
      <div style={{ position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.45)', backdropFilter: 'blur(2px)' }}/>

      {/* Sheet */}
      <div style={{
        position: 'absolute', left: 0, right: 0, bottom: 0,
        background: 'rgba(14, 20, 27, 0.92)',
        backdropFilter: 'blur(40px)',
        WebkitBackdropFilter: 'blur(40px)',
        borderTopLeftRadius: 22, borderTopRightRadius: 22,
        boxShadow: '0 -10px 40px rgba(0,0,0,0.30), 0 0 0 0.5px rgba(255,255,255,0.06) inset',
        color: '#fff',
        fontFamily: "'Geist', sans-serif",
        display: 'flex', flexDirection: 'column',
        maxHeight: '80%',
      }}>
        <div style={{ display: 'flex', justifyContent: 'center', paddingTop: 10 }}>
          <div style={{ width: 38, height: 5, borderRadius: 3, background: 'rgba(255,255,255,0.22)' }}/>
        </div>

        {/* Title row */}
        <div style={{ padding: '12px 16px 10px', display: 'flex', alignItems: 'baseline', gap: 10 }}>
          <div style={{ fontSize: 18, fontWeight: 600, letterSpacing: -0.3 }}>In this call</div>
          <div style={{
            padding: '2px 8px', borderRadius: 999,
            background: 'rgba(255,255,255,0.12)',
            fontSize: 11.5, fontWeight: 700, color: 'rgba(255,255,255,0.85)',
          }}>{PARTICIPANTS.length}</div>
          <div style={{ flex: 1 }}/>
          <div style={{
            padding: '5px 10px 5px 8px', borderRadius: 999,
            background: 'rgba(45,111,247,0.22)', color: '#9DBEFF',
            display: 'flex', alignItems: 'center', gap: 5,
            fontSize: 12, fontWeight: 600,
          }}>
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
              <circle cx="11" cy="9" r="4" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M3 21c0-4 3.2-7 7-7s7 3 7 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              <path d="M19 6v6M16 9h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
            Invite
          </div>
        </div>

        {/* Raised hands strip */}
        <div style={{ padding: '0 16px 10px' }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 10,
            padding: '9px 12px 9px 10px',
            borderRadius: 12,
            background: 'rgba(255, 184, 0, 0.14)',
            boxShadow: 'inset 0 0 0 0.5px rgba(255, 184, 0, 0.40)',
          }}>
            <span style={{ fontSize: 16 }}>✋</span>
            <div style={{
              flex: 1, fontSize: 13, fontWeight: 600, letterSpacing: -0.05, color: 'rgba(255,255,255,0.92)',
            }}>
              2 hands up
              <span style={{ color: 'rgba(255,255,255,0.6)', fontWeight: 500 }}> · Tasha, Jordan</span>
            </div>
            <div style={{ fontSize: 12, fontWeight: 700, color: '#FFB800' }}>Allow to speak</div>
          </div>
        </div>

        {/* Participants list */}
        <div className="sn-scroll" style={{
          flex: 1, overflowY: 'auto', overflowX: 'hidden',
          maxHeight: 380,
        }}>
          {PARTICIPANTS.map((p, i) => (
            <ParticipantRow key={p.name} p={p} expanded={i === expandedIdx}/>
          ))}
        </div>

        {/* Footer — global host controls */}
        <div style={{
          padding: '12px 16px 26px',
          borderTop: '0.5px solid rgba(255,255,255,0.08)',
          display: 'flex', gap: 8,
        }}>
          <div style={{
            flex: 1, height: 44, borderRadius: 12,
            background: 'rgba(255,255,255,0.10)', color: '#fff',
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
            fontSize: 14, fontWeight: 600, letterSpacing: -0.05,
          }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              <path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"/>
            </svg>
            Mute everyone
          </div>
          <div style={{
            flex: 1, height: 44, borderRadius: 12,
            background: 'rgba(255,255,255,0.10)', color: '#fff',
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
            fontSize: 14, fontWeight: 600, letterSpacing: -0.05,
          }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <rect x="5" y="11" width="14" height="10" rx="2" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M8 11V8a4 4 0 018 0v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
            Lock room
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SnCallParticipants });
