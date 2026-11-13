// settings.jsx — Sinhron settings screen
// Informed by the Citadel tech spec: linked devices, recovery phrase,
// app lock, last seen / read receipts / typing (opt-in per spec),
// notification preview (off by default per spec), local cache,
// self-hosted server address. E2EE is "always on" so it's not a toggle
// — it lives implicitly inside the Privacy section.
//
// Uses tokens from app/tokens.css. Theme via .sn-theme-light / .sn-theme-dark.
// Exports: SinhronSettings

const ST_AVATAR = 'Vera Kuznetsova';

// ─── Tiny icon set (stroke-currentColor, 20px) ──────────────────────
const Icon = {
  // shapes are deliberately a hair stronger than the chat-list icons to
  // anchor settings rows visually
  user: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <circle cx="12" cy="8" r="4" stroke="currentColor" strokeWidth="1.8"/>
      <path d="M4 21c0-4 3.6-7 8-7s8 3 8 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
    </svg>
  ),
  shield: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6l8-3z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
      <path d="M9 12l2 2 4-4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  ),
  devices: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <rect x="3" y="5" width="13" height="10" rx="1.6" stroke="currentColor" strokeWidth="1.8"/>
      <rect x="14" y="9" width="7" height="11" rx="1.4" stroke="currentColor" strokeWidth="1.8"/>
      <path d="M5 18h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
    </svg>
  ),
  key: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <circle cx="8" cy="14" r="4" stroke="currentColor" strokeWidth="1.8"/>
      <path d="M11 12l9-9M16 5l3 3M14 7l3 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  ),
  lock: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <rect x="4.5" y="11" width="15" height="10" rx="2.2" stroke="currentColor" strokeWidth="1.8"/>
      <path d="M8 11V8a4 4 0 018 0v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
    </svg>
  ),
  bell: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <path d="M5 16h14l-2-3V9a5 5 0 00-10 0v4l-2 3z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
      <path d="M10 19a2 2 0 004 0" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
    </svg>
  ),
  chats: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <path d="M4 6.5C4 5.12 5.12 4 6.5 4h11A2.5 2.5 0 0120 6.5v8a2.5 2.5 0 01-2.5 2.5H10l-4 3.5V17H6.5A2.5 2.5 0 014 14.5v-8z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
    </svg>
  ),
  paint: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
      <circle cx="7" cy="11" r="1.2" fill="currentColor"/>
      <circle cx="10" cy="7" r="1.2" fill="currentColor"/>
      <circle cx="15" cy="7" r="1.2" fill="currentColor"/>
      <circle cx="17.5" cy="11.5" r="1.2" fill="currentColor"/>
      <path d="M12 21c-1.5 0-2-1-1.5-2 .5-1 1.5-1.5 1.5-2.5 0-1.5 1.5-2 3-1.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" fill="none"/>
    </svg>
  ),
  text: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <path d="M4 6h16M9 6v14M15 12h5M17 12v8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
    </svg>
  ),
  storage: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <rect x="3" y="4" width="18" height="6" rx="1.6" stroke="currentColor" strokeWidth="1.8"/>
      <rect x="3" y="14" width="18" height="6" rx="1.6" stroke="currentColor" strokeWidth="1.8"/>
      <circle cx="7" cy="7" r="0.9" fill="currentColor"/>
      <circle cx="7" cy="17" r="0.9" fill="currentColor"/>
    </svg>
  ),
  download: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <path d="M12 4v12m0 0l-5-5m5 5l5-5M5 20h14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  ),
  server: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <rect x="3" y="5" width="18" height="6" rx="1.6" stroke="currentColor" strokeWidth="1.8"/>
      <rect x="3" y="13" width="18" height="6" rx="1.6" stroke="currentColor" strokeWidth="1.8"/>
      <circle cx="7" cy="8" r="0.9" fill="currentColor"/>
      <circle cx="7" cy="16" r="0.9" fill="currentColor"/>
      <path d="M11 8h7M11 16h7" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/>
    </svg>
  ),
  info: (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
      <path d="M12 11v6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
      <circle cx="12" cy="7.5" r="1.1" fill="currentColor"/>
    </svg>
  ),
};

// Soft pastel tints for the icon backplate — colour rhythm in a long list.
// keyed by row id; falls back to neutral.
const ICON_TINTS = {
  profile:  { bg: 'rgba(45,111,247,0.10)',  fg: '#2D6FF7' },  // accent
  privacy:  { bg: 'rgba(31,175,110,0.12)',  fg: '#1FAF6E' },  // green
  devices:  { bg: 'rgba(124,58,237,0.10)',  fg: '#7C3AED' },  // violet
  recovery: { bg: 'rgba(245,158,11,0.14)',  fg: '#D97706' },  // amber
  lock:     { bg: 'rgba(217,107,59,0.12)',  fg: '#E0683B' },  // peach
  notif:    { bg: 'rgba(236,72,153,0.10)',  fg: '#EC4899' },  // pink
  chats:    { bg: 'rgba(37,99,235,0.10)',   fg: '#2563EB' },  // navy
  appear:   { bg: 'rgba(147,51,234,0.10)',  fg: '#9333EA' },  // purple
  text:     { bg: 'rgba(60,70,84,0.10)',    fg: '#4A5562' },  // grey
  storage:  { bg: 'rgba(101,163,13,0.12)',  fg: '#65A30D' },  // olive
  download: { bg: 'rgba(45,111,247,0.10)',  fg: '#2D6FF7' },
  server:   { bg: 'rgba(15,23,32,0.08)',    fg: '#0E141B' },  // ink — neutral
  info:     { bg: 'rgba(15,23,32,0.06)',    fg: '#4A5562' },
};

// ─── Atoms ──────────────────────────────────────────────────────────
function StToggle({ on }) {
  return (
    <div style={{
      width: 44, height: 26, borderRadius: 999,
      background: on ? 'var(--sn-accent)' : 'var(--sn-divider-strong)',
      position: 'relative', flexShrink: 0,
      transition: 'background 0.2s',
      boxShadow: on ? '0 1px 2px rgba(45,111,247,0.30)' : 'inset 0 0 0 0.5px rgba(15,23,32,0.05)',
    }}>
      <div style={{
        position: 'absolute', top: 2, left: on ? 20 : 2,
        width: 22, height: 22, borderRadius: '50%',
        background: '#fff',
        boxShadow: '0 1px 3px rgba(0,0,0,0.18)',
        transition: 'left 0.2s',
      }}/>
    </div>
  );
}

function StRowIcon({ tintKey }) {
  // Not used directly; rendered inside StRow when row.icon is a key string.
  // Kept for symmetry / external use.
  return null;
}

function StRow({ icon, tintKey, label, value, toggle, danger, mono, isLast }) {
  const tint = ICON_TINTS[tintKey] || ICON_TINTS.info;
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '11px 14px',
      position: 'relative',
      minHeight: 52,
    }}>
      {icon && (
        <div style={{
          width: 30, height: 30, borderRadius: 8,
          background: tint.bg, color: tint.fg,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          flexShrink: 0,
        }}>{icon}</div>
      )}
      <div style={{
        flex: 1, minWidth: 0,
        fontSize: 15, fontWeight: 500, letterSpacing: -0.2,
        color: danger ? '#E0683B' : 'var(--sn-text)',
      }}>{label}</div>

      {value != null && (
        <div className={mono ? 'sn-mono' : ''} style={{
          fontSize: mono ? 12 : 14, fontWeight: mono ? 500 : 400,
          color: 'var(--sn-text-3)',
          letterSpacing: mono ? 0 : -0.1,
          maxWidth: 160,
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>{value}</div>
      )}

      {toggle != null && <StToggle on={toggle}/>}

      {value != null && !toggle && (
        <svg width="7" height="12" viewBox="0 0 8 14" style={{ flexShrink: 0, color: 'var(--sn-text-4)' }}>
          <path d="M1 1l6 6-6 6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
        </svg>
      )}
      {value == null && toggle == null && (
        <svg width="7" height="12" viewBox="0 0 8 14" style={{ flexShrink: 0, color: 'var(--sn-text-4)' }}>
          <path d="M1 1l6 6-6 6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
        </svg>
      )}

      {!isLast && (
        <div style={{
          position: 'absolute', left: icon ? 56 : 14, right: 0, bottom: 0,
          height: 0.5, background: 'var(--sn-divider)',
        }}/>
      )}
    </div>
  );
}

function StSection({ title, footer, children }) {
  return (
    <div style={{ marginBottom: 22 }}>
      {title && (
        <div style={{
          fontSize: 11, fontWeight: 600, letterSpacing: 0.5,
          color: 'var(--sn-text-3)', textTransform: 'uppercase',
          padding: '0 28px 8px',
        }}>{title}</div>
      )}
      <div style={{
        background: 'var(--sn-surface)',
        borderRadius: 16,
        margin: '0 14px',
        overflow: 'hidden',
        boxShadow: '0 0 0 0.5px var(--sn-divider-strong), 0 1px 2px rgba(15,23,32,0.04)',
      }}>{children}</div>
      {footer && (
        <div style={{
          fontSize: 12, fontWeight: 400, lineHeight: '17px',
          color: 'var(--sn-text-3)', letterSpacing: -0.05,
          padding: '8px 28px 0',
        }}>{footer}</div>
      )}
    </div>
  );
}

// ─── Profile card ───────────────────────────────────────────────────
function ProfileCard() {
  return (
    <div style={{ padding: '0 14px 22px' }}>
      <div style={{
        background: 'var(--sn-surface)',
        borderRadius: 20,
        padding: '18px 18px',
        display: 'flex', alignItems: 'center', gap: 14,
        boxShadow: '0 0 0 0.5px var(--sn-divider-strong), 0 1px 2px rgba(15,23,32,0.04)',
      }}>
        <SnAvatar name={ST_AVATAR} size={62}/>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{
            fontSize: 19, fontWeight: 600, letterSpacing: -0.3,
            color: 'var(--sn-text)',
            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
          }}>Vera Kuznetsova</div>
          <div style={{
            fontSize: 13, fontWeight: 400, marginTop: 2,
            color: 'var(--sn-text-3)', letterSpacing: -0.05,
          }} className="sn-mono">@vera · keys.sinhron.io</div>
          <div style={{
            display: 'inline-flex', alignItems: 'center', gap: 5,
            marginTop: 8,
            padding: '3px 9px',
            background: 'var(--sn-accent-soft)',
            color: 'var(--sn-accent)',
            borderRadius: 999,
            fontSize: 11, fontWeight: 600, letterSpacing: 0,
          }}>
            <svg width="11" height="11" viewBox="0 0 24 24" fill="none">
              <path d="M20 6L9 17l-5-5" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
            Identity verified
          </div>
        </div>
        <svg width="8" height="14" viewBox="0 0 8 14" style={{ color: 'var(--sn-text-4)' }}>
          <path d="M1 1l6 6-6 6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
        </svg>
      </div>
    </div>
  );
}

// ─── Header ─────────────────────────────────────────────────────────
function SettingsHeader() {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '6px 16px 14px',
    }}>
      <div style={{
        flex: 1, fontSize: 28, fontWeight: 700, letterSpacing: -0.5,
        color: 'var(--sn-text)',
      }}>Settings</div>
      <button style={{
        width: 36, height: 36, borderRadius: 10, border: 'none',
        background: 'transparent', padding: 0, cursor: 'pointer',
        color: 'var(--sn-text-2)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/>
          <path d="M16.5 16.5L21 21" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
        </svg>
      </button>
    </div>
  );
}

// ─── Bottom Tab Bar (same as chat list, "Settings" active) ──────────
function SnSettingsTabBar({ platform }) {
  // Reuse the chat-list pattern but with Settings active.
  // Duplicating the tab bar locally so chat-list.jsx doesn't need props plumbing.
  const tabs = [
    { id: 'chats', label: 'Chats',
      icon: <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M4 6.5C4 5.12 5.12 4 6.5 4h11A2.5 2.5 0 0120 6.5v8a2.5 2.5 0 01-2.5 2.5H10l-4 3.5V17H6.5A2.5 2.5 0 014 14.5v-8z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></svg> },
    { id: 'calls', label: 'Calls',
      icon: <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></svg> },
    { id: 'contacts', label: 'Contacts',
      icon: <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="8" r="4" stroke="currentColor" strokeWidth="1.8"/><path d="M4 21c0-4 3.6-7 8-7s8 3 8 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></svg> },
    { id: 'settings', label: 'Settings', active: true,
      icon: <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><circle cx="12" cy="12" r="3" stroke="currentColor" strokeWidth="1.8"/><path d="M19.4 15a1.7 1.7 0 00.34 1.86l.06.06a2 2 0 11-2.82 2.82l-.06-.06a1.7 1.7 0 00-1.86-.34 1.7 1.7 0 00-1 1.55V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1.06-1.55 1.7 1.7 0 00-1.86.34l-.06.06a2 2 0 11-2.82-2.82l.06-.06a1.7 1.7 0 00.34-1.86 1.7 1.7 0 00-1.55-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.55-1.06 1.7 1.7 0 00-.34-1.86l-.06-.06a2 2 0 112.82-2.82l.06.06a1.7 1.7 0 001.86.34H9a1.7 1.7 0 001-1.55V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.55 1.7 1.7 0 001.86-.34l.06-.06a2 2 0 112.82 2.82l-.06.06a1.7 1.7 0 00-.34 1.86V9a1.7 1.7 0 001.55 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.55 1z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></svg> },
  ];
  const bottomPad = platform === 'ios' ? 28 : 16;
  return (
    <div style={{
      position: 'absolute', left: 0, right: 0, bottom: 0,
      paddingTop: 8, paddingBottom: bottomPad,
      paddingLeft: 8, paddingRight: 8,
      background: 'var(--sn-bg)',
      borderTop: '0.5px solid var(--sn-divider-strong)',
      display: 'flex', zIndex: 5,
    }}>
      {tabs.map(t => (
        <div key={t.id} style={{
          flex: 1, display: 'flex', flexDirection: 'column',
          alignItems: 'center', gap: 4,
          padding: '6px 4px 2px',
          color: t.active ? 'var(--sn-accent)' : 'var(--sn-text-3)',
        }}>
          {t.icon}
          <div style={{
            fontSize: 10.5, fontWeight: t.active ? 600 : 500, letterSpacing: -0.05,
          }}>{t.label}</div>
        </div>
      ))}
    </div>
  );
}

// ─── Screen ─────────────────────────────────────────────────────────
function SinhronSettings({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <SettingsHeader/>

      <div className="sn-scroll" style={{
        flex: 1,
        paddingBottom: platform === 'ios' ? 110 : 100,
      }}>
        <ProfileCard/>

        {/* PRIVACY — this is where the E2EE story finally lives */}
        <StSection
          title="Privacy"
          footer="End-to-end encryption is always on. These options control what your contacts and your server can see about you."
        >
          <StRow icon={Icon.shield} tintKey="privacy" label="Privacy & security" value="Review"/>
          <StRow icon={Icon.devices} tintKey="devices" label="Linked devices" value="3 devices"/>
          <StRow icon={Icon.key} tintKey="recovery" label="Recovery phrase" value="Verified"/>
          <StRow icon={Icon.lock} tintKey="lock" label="App lock" value="Face ID" isLast/>
        </StSection>

        {/* NOTIFICATIONS */}
        <StSection
          title="Notifications"
          footer="Hide preview keeps message contents off the lock screen. Your server cannot send previews — they're built locally after decryption."
        >
          <StRow icon={Icon.bell} tintKey="notif" label="Sounds & vibrations" value="Default"/>
          <StRow label="Message preview" toggle={false}/>
          <StRow label="Show sender name" toggle={true} isLast/>
        </StSection>

        {/* CHATS — read receipts, typing, last seen live here per spec */}
        <StSection
          title="Chats"
          footer={null}
        >
          <StRow icon={Icon.chats} tintKey="chats" label="Read receipts" toggle={true}/>
          <StRow label="Typing indicators" toggle={true}/>
          <StRow label="Last seen" value="Nobody"/>
          <StRow icon={Icon.text} tintKey="text" label="Text size" value="Medium" isLast/>
        </StSection>

        {/* APPEARANCE */}
        <StSection title="Appearance">
          <StRow icon={Icon.paint} tintKey="appear" label="Theme" value={dark ? 'Dark' : 'Light'}/>
          <StRow label="Wallpaper" value="Default" isLast/>
        </StSection>

        {/* STORAGE */}
        <StSection title="Storage">
          <StRow icon={Icon.storage} tintKey="storage" label="Storage" value="184 MB"/>
          <StRow icon={Icon.download} tintKey="download" label="Auto-download media" value="Wi-Fi only" isLast/>
        </StSection>

        {/* SERVER — the self-hosted detail */}
        <StSection
          title="Server"
          footer="You're connected to a Sinhron server. Its operator can see when messages are delivered, never what's inside them."
        >
          <StRow icon={Icon.server} tintKey="server" label="Server" value="keys.sinhron.io" mono/>
          <StRow label="Connection" value="Connected"/>
          <StRow label="Message retention" value="14 days" isLast/>
        </StSection>

        {/* ABOUT */}
        <StSection title="About">
          <StRow icon={Icon.info} tintKey="info" label="Sinhron" value="1.0.0 (build 4218)" mono/>
          <StRow label="Source code" value="github.com" mono/>
          <StRow label="Help & feedback" isLast/>
        </StSection>

        <div style={{ height: 18 }}/>
      </div>

      <SnSettingsTabBar platform={platform}/>
    </div>
  );
}

Object.assign(window, { SinhronSettings });
