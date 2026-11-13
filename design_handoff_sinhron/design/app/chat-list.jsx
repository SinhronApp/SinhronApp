// chat-list.jsx — Sinhron main screen (chat list)
// Shared across iOS + Android frames. Theme via parent class .sn-theme-light / .sn-theme-dark
// Exports: SinhronChatList, ChatListAnatomy, SinhronTypeSpec, SinhronColorSpec

const SN_AVATAR_PALETTES = [
  ['#FFB089', '#FF6E54'], // amber
  ['#9DE6CB', '#10B981'], // teal
  ['#C5A0FF', '#7C3AED'], // violet
  ['#FFE08A', '#F59E0B'], // gold
  ['#A0C4FF', '#3B82F6'], // blue
  ['#FFC2D1', '#EC4899'], // pink
  ['#B5E2A1', '#65A30D'], // olive
  ['#FFCFA5', '#E0683B'], // peach
  ['#9FE7E3', '#0EA5A5'], // cyan
  ['#E8B4FF', '#A21CAF'], // magenta
];

function snHashIdx(s, n) {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return h % n;
}

function snInitials(name) {
  // Strip non-letter prefix, then take first 1-2 word initials
  const parts = name.replace(/^[^A-Za-z]+/, '').split(/\s+/).filter(Boolean);
  if (!parts.length) return name.slice(0, 2).toUpperCase();
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

function SnAvatar({ name, size = 48, group = false, online = false, ring = false }) {
  const [c1, c2] = SN_AVATAR_PALETTES[snHashIdx(name, SN_AVATAR_PALETTES.length)];
  const initials = snInitials(name);
  return (
    <div style={{ position: 'relative', width: size, height: size, flexShrink: 0 }}>
      <div style={{
        width: size, height: size, borderRadius: '50%',
        background: `linear-gradient(150deg, ${c1} 0%, ${c2} 100%)`,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        color: '#fff',
        fontWeight: 600, fontSize: size * 0.38, letterSpacing: 0.2,
        boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.20), inset 0 -1px 0 rgba(0,0,0,0.08)',
        position: 'relative', overflow: 'hidden',
      }}>
        {group ? (
          <svg width={size * 0.5} height={size * 0.5} viewBox="0 0 24 24" fill="none">
            <circle cx="9" cy="9" r="3.5" fill="white" fillOpacity="0.95"/>
            <circle cx="16.5" cy="9.5" r="2.7" fill="white" fillOpacity="0.7"/>
            <path d="M3 18.5c0-3 2.7-5.2 6-5.2s6 2.2 6 5.2v.5H3v-.5z" fill="white" fillOpacity="0.95"/>
            <path d="M14.5 18c.4-1.6 1.7-2.9 3.5-3.4 2.4-.6 3.5 1.1 3.5 3.4v1h-7v-1z" fill="white" fillOpacity="0.7"/>
          </svg>
        ) : initials}
        <div style={{
          position: 'absolute', inset: 0, borderRadius: '50%',
          background: 'var(--sn-avatar-shade)', pointerEvents: 'none',
        }}/>
      </div>
      {online && (
        <div style={{
          position: 'absolute', right: -1, bottom: -1,
          width: size * 0.28, height: size * 0.28, borderRadius: '50%',
          background: 'var(--sn-success)',
          border: '2.5px solid var(--sn-bg)',
        }}/>
      )}
    </div>
  );
}

function SnIconBtn({ children, size = 36, onClick, badge }) {
  return (
    <button onClick={onClick} style={{
      width: size, height: size, borderRadius: 10,
      background: 'transparent', border: 'none', padding: 0,
      cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center',
      color: 'var(--sn-text)', position: 'relative',
    }}>
      {children}
      {badge != null && (
        <span style={{
          position: 'absolute', top: 2, right: 2,
          minWidth: 16, height: 16, padding: '0 4px',
          borderRadius: 8, background: 'var(--sn-accent)',
          color: '#fff', fontSize: 10, fontWeight: 700,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          border: '2px solid var(--sn-bg)', boxSizing: 'content-box',
        }}>{badge}</span>
      )}
    </button>
  );
}

// Header bar — avatar (menu) + title + single search action.
// Compose lives in the FAB at the bottom-right, not duplicated here.
function SnHeader({ unread }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '6px 16px 12px',
    }}>
      <SnAvatar name="Vera Kuznetsova" size={40}/>
      <div style={{
        flex: 1, fontSize: 24, fontWeight: 600, letterSpacing: -0.5,
        color: 'var(--sn-text)',
      }}>Chats</div>
      <SnIconBtn>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/>
          <path d="M16.5 16.5L21 21" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
        </svg>
      </SnIconBtn>
    </div>
  );
}

// Filter pills — 3 only. Active state uses accent-soft + accent text
// so the chip sits inside the system's accent vocabulary, not against it.
function SnFilters({ active = 'All', counts = {} }) {
  const filters = ['All', 'Unread', 'Groups'];
  return (
    <div style={{
      display: 'flex', gap: 8, padding: '4px 16px 10px',
      overflowX: 'auto', scrollbarWidth: 'none',
    }}>
      {filters.map(f => {
        const isActive = f === active;
        return (
          <div key={f} style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '7px 14px',
            borderRadius: 'var(--sn-radius-pill)',
            background: isActive ? 'var(--sn-accent-soft)' : 'transparent',
            color: isActive ? 'var(--sn-accent)' : 'var(--sn-text-2)',
            fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1,
            whiteSpace: 'nowrap', flexShrink: 0,
          }}>
            {f}
            {counts[f] != null && (
              <span style={{
                background: isActive ? 'var(--sn-accent)' : 'var(--sn-bg-soft)',
                color: isActive ? '#fff' : 'var(--sn-text-3)',
                padding: '1px 6px', borderRadius: 999,
                fontSize: 11, fontWeight: 700,
              }}>{counts[f]}</span>
            )}
          </div>
        );
      })}
    </div>
  );
}

// One chat row
function SnChatRow({ chat, isLast }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '10px 16px',
      position: 'relative',
    }}>
      <SnAvatar name={chat.name} size={50} group={chat.group} online={chat.online}/>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 3 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <div style={{
            flex: 1, minWidth: 0,
            fontSize: 16, fontWeight: 600, letterSpacing: -0.2,
            color: 'var(--sn-text)',
            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            display: 'flex', alignItems: 'center', gap: 5,
          }}>
            <span style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
              {chat.name}
            </span>
            {chat.muted && (
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" style={{ flexShrink: 0, color: 'var(--sn-text-3)' }}>
                <path d="M12 4a5 5 0 015 5v4l2 3H5l2-3V9a5 5 0 015-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
                <path d="M3 3l18 18" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            )}
          </div>
          <div style={{
            fontSize: 12, fontWeight: 500, letterSpacing: -0.1,
            color: chat.unread ? 'var(--sn-accent)' : 'var(--sn-text-3)',
            whiteSpace: 'nowrap',
          }}>{chat.time}</div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <div style={{
            flex: 1, minWidth: 0,
            fontSize: 14, fontWeight: 400, lineHeight: '19px',
            color: chat.typing ? 'var(--sn-accent)' : 'var(--sn-text-2)',
            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            display: 'flex', alignItems: 'center', gap: 4,
          }}>
            {chat.sender && (
              <span style={{ color: 'var(--sn-text)', fontWeight: 500 }}>{chat.sender}: </span>
            )}
            {chat.kind === 'voice' && (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style={{ flexShrink: 0, color: 'var(--sn-text-3)' }}>
                <path d="M2 12h2M6 8v8M10 5v14M14 8v8M18 10v4M22 12h-2" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
              </svg>
            )}
            {chat.kind === 'photo' && (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style={{ flexShrink: 0, color: 'var(--sn-text-3)' }}>
                <rect x="3" y="5" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
                <circle cx="9" cy="11" r="2" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M3 17l5-4 4 3 3-2 6 5" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            )}
            {chat.kind === 'call' && (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style={{ flexShrink: 0, color: 'var(--sn-text-3)' }}>
                <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            )}
            {chat.typing ? <i style={{ fontStyle: 'normal' }}>typing…</i> : <span style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{chat.preview}</span>}
          </div>

          {/* trailing indicators */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexShrink: 0 }}>
            {chat.pinned && !chat.unread && (
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-text-3)' }}>
                <path d="M12 2l4 4-1.5 1.5L17 10l-4 4-2.5-2.5L4 18v2h2l6.5-6.5L15 16l4-4-2.5-2.5L18 8l-4-4z" fill="currentColor"/>
              </svg>
            )}
            {chat.sent && !chat.unread && (
              <svg width="16" height="11" viewBox="0 0 22 14" fill="none" style={{ color: chat.read ? 'var(--sn-accent)' : 'var(--sn-text-3)' }}>
                <path d="M1 7l4.5 4.5L13 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
                {chat.read && <path d="M9 7l4.5 4.5L21 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" fill="none"/>}
              </svg>
            )}
            {chat.unread > 0 && (
              <div style={{
                minWidth: 22, height: 22, padding: '0 7px',
                borderRadius: 11, boxSizing: 'border-box',
                background: chat.muted ? 'var(--sn-text-4)' : 'var(--sn-accent)',
                color: '#fff', fontSize: 12, fontWeight: 700,
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                letterSpacing: -0.1,
              }}>{chat.unread}</div>
            )}
            {chat.mention && (
              <div style={{
                width: 22, height: 22, borderRadius: 11,
                background: 'var(--sn-accent)', color: '#fff',
                fontSize: 13, fontWeight: 700,
                display: 'flex', alignItems: 'center', justifyContent: 'center',
              }}>@</div>
            )}
          </div>
        </div>
      </div>

      {/* no hairline divider — modern dense lists rely on padding rhythm alone */}
    </div>
  );
}

// Bottom tab bar — clean, no E2EE hints
function SnTabBar({ active = 'chats', dark, platform }) {
  const tabs = [
    { id: 'chats', label: 'Chats',
      icon: (
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <path d="M4 6.5C4 5.12 5.12 4 6.5 4h11A2.5 2.5 0 0120 6.5v8a2.5 2.5 0 01-2.5 2.5H10l-4 3.5V17H6.5A2.5 2.5 0 014 14.5v-8z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        </svg>
      ) },
    { id: 'calls', label: 'Calls',
      icon: (
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        </svg>
      ) },
    { id: 'contacts', label: 'Contacts',
      _hidden: true,
      icon: (
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <circle cx="12" cy="8" r="4" stroke="currentColor" strokeWidth="1.8"/>
          <path d="M4 21c0-4 3.6-7 8-7s8 3 8 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
        </svg>
      ) },
    { id: 'settings', label: 'Settings',
      icon: (
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <path d="M4 7h11M4 12h16M9 17h11" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          <circle cx="17" cy="7" r="2.2" stroke="currentColor" strokeWidth="1.8" fill="var(--sn-bg)"/>
          <circle cx="6" cy="12" r="2.2" stroke="currentColor" strokeWidth="1.8" fill="var(--sn-bg)"/>
          <circle cx="14" cy="17" r="2.2" stroke="currentColor" strokeWidth="1.8" fill="var(--sn-bg)"/>
        </svg>
      ) },
  ];
  const bottomPad = platform === 'ios' ? 28 : 16;
  return (
    <div style={{
      position: 'absolute', left: 0, right: 0, bottom: 0,
      paddingTop: 8, paddingBottom: bottomPad,
      paddingLeft: 8, paddingRight: 8,
      background: 'var(--sn-bg)',
      borderTop: '0.5px solid var(--sn-divider-strong)',
      display: 'flex',
      zIndex: 5,
    }}>
      {tabs.filter(t => !t._hidden).map(t => {
        const isActive = t.id === active;
        return (
          <div key={t.id} style={{
            flex: 1, display: 'flex', flexDirection: 'column',
            alignItems: 'center', gap: 4,
            padding: '6px 4px 2px',
            color: isActive ? 'var(--sn-accent)' : 'var(--sn-text-3)',
            position: 'relative',
          }}>
            <div style={{ position: 'relative' }}>
              {t.icon}
              {t.badge && (
                <div style={{
                  position: 'absolute', top: -4, right: -8,
                  minWidth: 16, height: 16, padding: '0 4px',
                  borderRadius: 8, background: 'var(--sn-accent)',
                  color: '#fff', fontSize: 10, fontWeight: 700,
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  border: '2px solid var(--sn-bg)', boxSizing: 'content-box',
                  letterSpacing: -0.1,
                }}>{t.badge}</div>
              )}
            </div>
            <div style={{
              fontSize: 10.5, fontWeight: isActive ? 600 : 500, letterSpacing: -0.05,
            }}>{t.label}</div>
          </div>
        );
      })}
    </div>
  );
}

// Sample data — English, premium-messenger natural copy
const SN_SAMPLE_CHATS = [
  { name: 'Maria Chen', preview: 'Sounds great — see you at 9 tomorrow ☕', time: '12:42', unread: 2, pinned: true, online: true },
  { name: 'Engineering', group: true, sender: 'Alex', preview: 'pushed the new SFrame implementation', time: '12:08', unread: 7, pinned: true },
  { name: 'Henry Park', preview: 'Voice message · 0:42', kind: 'voice', time: '11:31', unread: 1 },
  { name: 'Mom', preview: 'Got it ❤️', time: '10:14', sent: true, read: true },
  { name: 'Design crit', group: true, sender: 'Tasha', preview: 'shared 3 photos', kind: 'photo', time: '09:22', muted: true, unread: 4 },
  { name: 'Jordan Pierce', preview: 'typing…', typing: true, time: 'now', online: true },
  { name: 'Sam Okonkwo', preview: 'thanks, that worked perfectly', time: 'Yesterday', sent: true, read: true },
  { name: 'Dad', preview: 'Missed call', kind: 'call', time: 'Yesterday' },
  { name: 'Coffee crew', group: true, sender: 'Nora', preview: 'see you at 11 ✌️', time: 'Wed', muted: true },
  { name: 'Nora Hayes', preview: 'docs look solid, shipping it', time: 'Tue', sent: true, read: true },
  { name: 'Sinhron updates', group: true, preview: 'v1.0-rc1 just shipped — release notes inside', time: 'Mon', muted: true, unread: 1 },
  { name: 'Robin Vasquez', preview: 'Sent the contract over', time: 'Apr 12', sent: true },
];

function SinhronChatList({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* top safe area handled by the device frame's status bar */}
      <SnHeader/>
      <SnFilters active="All" counts={{ Unread: 4 }}/>

      {/* list — scrolls under the tab bar; bottom padding lets last row breathe */}
      <div className="sn-scroll" style={{
        flex: 1,
        paddingBottom: platform === 'ios' ? 110 : 100,
      }}>
        {SN_SAMPLE_CHATS.map((c, i) => (
          <SnChatRow key={i} chat={c} isLast={i === SN_SAMPLE_CHATS.length - 1}/>
        ))}
      </div>

      <SnTabBar platform={platform} dark={dark}/>

      {/* Compose FAB \u2014 sits above the tab bar, right-aligned */}
      <button style={{
        position: 'absolute', right: 18,
        bottom: (platform === 'ios' ? 110 : 100) - 6,
        width: 54, height: 54, borderRadius: 27,
        border: 'none', cursor: 'pointer',
        background: 'var(--sn-accent)', color: '#fff',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        boxShadow: 'var(--sn-shadow-fab)',
        zIndex: 6,
      }}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <path d="M16.5 3.5l4 4-12 12H4.5v-4l12-12z" stroke="currentColor" strokeWidth="1.9" strokeLinejoin="round"/>
          <path d="M13.5 6.5l4 4" stroke="currentColor" strokeWidth="1.9"/>
        </svg>
      </button>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────
// Spec cards (typography, color, anatomy)
// ─────────────────────────────────────────────────────────────────
function SnSpecCard({ dark = false, children, padding = 24 }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      background: 'var(--sn-bg)', padding,
      boxSizing: 'border-box', overflow: 'auto',
    }}>{children}</div>
  );
}

function SinhronTypeSpec({ dark = false }) {
  const samples = [
    { label: 'Display / 32 / 600', size: 32, weight: 600, text: 'Sinhron', tracking: -0.8 },
    { label: 'Title / 22 / 600', size: 22, weight: 600, text: 'Chats', tracking: -0.4 },
    { label: 'Row name / 16 / 600', size: 16, weight: 600, text: 'Maria Chen', tracking: -0.2 },
    { label: 'Body / 14 / 400', size: 14, weight: 400, text: 'Sounds great — see you tomorrow', tracking: -0.1 },
    { label: 'Meta / 12 / 500', size: 12, weight: 500, text: '12:42', tracking: -0.1 },
    { label: 'Mono / 13 / 500', size: 13, weight: 500, text: 'fp:  9a3e 4d12 8b71 ec22', tracking: 0, mono: true },
  ];
  return (
    <SnSpecCard dark={dark}>
      <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)', letterSpacing: 0.6, textTransform: 'uppercase', marginBottom: 20 }}>Typography · Geist</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
        {samples.map(s => (
          <div key={s.label}>
            <div style={{ fontSize: 10, fontWeight: 500, color: 'var(--sn-text-3)', letterSpacing: 0.4, marginBottom: 4, textTransform: 'uppercase' }}>{s.label}</div>
            <div className={s.mono ? 'sn-mono' : ''} style={{
              fontSize: s.size, fontWeight: s.weight, letterSpacing: s.tracking,
              color: 'var(--sn-text)', lineHeight: 1.15,
            }}>{s.text}</div>
          </div>
        ))}
      </div>
    </SnSpecCard>
  );
}

function SinhronColorSpec({ dark = false }) {
  const groups = [
    { title: 'Surfaces', tokens: [
      { name: '--sn-bg', value: dark ? '#0B1016' : '#FAF9F6' },
      { name: '--sn-surface', value: dark ? '#141B25' : '#FFFFFF' },
      { name: '--sn-elevated', value: dark ? '#1A222D' : '#FFFFFF' },
    ]},
    { title: 'Text', tokens: [
      { name: '--sn-text', value: dark ? '#ECEEF1' : '#0E141B' },
      { name: '--sn-text-2', value: dark ? '#A6AFBD' : '#4A5562' },
      { name: '--sn-text-3', value: dark ? '#6E7889' : '#8A96A4' },
    ]},
    { title: 'Accent', tokens: [
      { name: '--sn-accent', value: dark ? '#4F8AFF' : '#2D6FF7' },
      { name: '--sn-accent-soft', value: dark ? 'rgba(79,138,255,0.16)' : '#E6EFFE' },
      { name: '--sn-success', value: dark ? '#2BC58A' : '#1FAF6E' },
    ]},
  ];
  return (
    <SnSpecCard dark={dark}>
      <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)', letterSpacing: 0.6, textTransform: 'uppercase', marginBottom: 20 }}>Color tokens · {dark ? 'Dark' : 'Light'}</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 22 }}>
        {groups.map(g => (
          <div key={g.title}>
            <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--sn-text-2)', marginBottom: 10 }}>{g.title}</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {g.tokens.map(t => (
                <div key={t.name} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                  <div style={{
                    width: 36, height: 36, borderRadius: 10,
                    background: t.value,
                    boxShadow: 'inset 0 0 0 0.5px var(--sn-divider-strong)',
                  }}/>
                  <div className="sn-mono" style={{ fontSize: 12, color: 'var(--sn-text)', flex: 1 }}>{t.name}</div>
                  <div className="sn-mono" style={{ fontSize: 11, color: 'var(--sn-text-3)' }}>{t.value}</div>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>
    </SnSpecCard>
  );
}

function ChatListAnatomy({ dark = false }) {
  const labelStyle = {
    fontSize: 10, fontWeight: 600, letterSpacing: 0.4, textTransform: 'uppercase',
    color: 'var(--sn-text-3)',
  };
  return (
    <SnSpecCard dark={dark} padding={28}>
      <div style={{ ...labelStyle, marginBottom: 16 }}>Row anatomy</div>

      <div style={{
        background: 'var(--sn-surface)',
        borderRadius: 'var(--sn-radius-card)',
        padding: '10px 16px',
        boxShadow: 'var(--sn-shadow-soft)',
        position: 'relative',
      }}>
        <SnChatRow chat={SN_SAMPLE_CHATS[0]} isLast={true}/>
      </div>

      <div style={{ marginTop: 28, display: 'flex', flexDirection: 'column', gap: 14 }}>
        {[
          ['Avatar', '50 × 50 · gradient · hashed by name'],
          ['Name', 'Geist 16 / 600 · letterSpacing −0.2'],
          ['Time', 'Geist 12 / 500 · accent when unread'],
          ['Preview', 'Geist 14 / 400 · text-2 · sender bolded for groups'],
          ['Badge', 'Pill 22h · accent fill · muted → neutral'],
          ['Read tick', 'Double check · accent when seen'],
          ['Indicators', 'Pinned · Muted · @mention · Typing'],
        ].map(([k, v]) => (
          <div key={k} style={{ display: 'flex', gap: 12, alignItems: 'baseline' }}>
            <div style={{ width: 80, fontSize: 12, fontWeight: 600, color: 'var(--sn-text-2)' }}>{k}</div>
            <div style={{ flex: 1, fontSize: 13, color: 'var(--sn-text-2)' }}>{v}</div>
          </div>
        ))}
      </div>
    </SnSpecCard>
  );
}

Object.assign(window, {
  SinhronChatList, ChatListAnatomy, SinhronTypeSpec, SinhronColorSpec,
  SnAvatar, SnChatRow, SnHeader, SnFilters, SnTabBar,
});
