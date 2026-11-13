// contact-info.jsx — Sinhron contact profile screen
// Theme via parent class .sn-theme-light / .sn-theme-dark
// Per tech spec: identity = Ed25519 + Basic MLS credential.
// This is the ONE place E2EE becomes visible (safety-number, device list,
// disappearing-messages) — the rest of the app stays quiet about it.
// Exports: SinhronContactInfo

// ─── Tiny header (back + more) ──────────────────────────────────────
function ContactTopBar({ floating = false }) {
  const bg = floating ? 'transparent' : 'var(--sn-bg)';
  return (
    <div style={{
      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      padding: '6px 10px',
      background: bg,
      position: 'relative', zIndex: 4,
    }}>
      <button style={{
        width: 36, height: 36, borderRadius: 10, border: 'none',
        background: 'transparent', padding: 0, cursor: 'pointer',
        color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </button>
      <button style={{
        width: 36, height: 36, borderRadius: 10, border: 'none',
        background: 'transparent', padding: 0, cursor: 'pointer',
        color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <circle cx="5" cy="12" r="1.8" fill="currentColor"/>
          <circle cx="12" cy="12" r="1.8" fill="currentColor"/>
          <circle cx="19" cy="12" r="1.8" fill="currentColor"/>
        </svg>
      </button>
    </div>
  );
}

// ─── Hero (big avatar, name, username, status) ──────────────────────
function ContactHero({ name, username, status, statusKind, dark }) {
  // status kinds: 'online' (success green) / 'away' (neutral) / 'quiet' (text-3)
  const statusColor = statusKind === 'online' ? 'var(--sn-success)' : 'var(--sn-text-3)';
  return (
    <div style={{
      display: 'flex', flexDirection: 'column', alignItems: 'center',
      gap: 12, padding: '20px 24px 24px',
    }}>
      <SnAvatar name={name} size={112}/>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, marginTop: 6 }}>
        <div style={{
          fontSize: 28, fontWeight: 600, letterSpacing: -0.7,
          color: 'var(--sn-text)',
        }}>{name}</div>
        <div style={{
          fontSize: 16, fontWeight: 500, color: 'var(--sn-text-2)',
          letterSpacing: -0.1,
          fontFamily: 'Geist Mono, ui-monospace, SFMono-Regular, monospace',
        }}>{username}</div>
        <div style={{
          fontSize: 14, fontWeight: 500, color: statusColor,
          display: 'flex', alignItems: 'center', gap: 6, marginTop: 3,
        }}>
          {statusKind === 'online' && (
            <span style={{ width: 7, height: 7, borderRadius: 3.5, background: 'var(--sn-success)' }}/>
          )}
          {status}
        </div>
      </div>
    </div>
  );
}

// ─── Action tiles — 3 standalone gap-spaced buttons ─────────────
// Modern pattern (Telegram/WhatsApp 2024): no wrapping card, no hairlines.
// Mute removed — lives in the Notifications row below, no duplication.
function ContactActions() {
  const Action = ({ icon, label }) => (
    <button style={{
      flex: 1, minWidth: 0,
      display: 'flex', flexDirection: 'column', alignItems: 'center',
      justifyContent: 'center', gap: 8,
      padding: '14px 6px 12px',
      background: 'var(--sn-surface)',
      border: 'none',
      borderRadius: 'var(--sn-radius-card)',
      boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
      cursor: 'pointer',
      color: 'var(--sn-text)',
    }}>
      <div style={{
        width: 40, height: 40, borderRadius: 12,
        background: 'var(--sn-accent-soft)',
        color: 'var(--sn-accent)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        flexShrink: 0,
      }}>{icon}</div>
      <div style={{
        fontSize: 13, fontWeight: 600, letterSpacing: -0.1,
        color: 'var(--sn-text)',
      }}>{label}</div>
    </button>
  );
  return (
    <div style={{ padding: '0 14px 24px', display: 'flex', gap: 10 }}>
      <Action label="Message" icon={
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <path d="M4 6.5C4 5.12 5.12 4 6.5 4h11A2.5 2.5 0 0120 6.5v8a2.5 2.5 0 01-2.5 2.5H10l-4 3.5V17H6.5A2.5 2.5 0 014 14.5v-8z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        </svg>
      }/>
      <Action label="Call" icon={
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
          <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        </svg>
      }/>
      <Action label="Video" icon={
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="1.8"/>
          <path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        </svg>
      }/>
    </div>
  );
}

// ─── Section ────────────────────────────────────────────────────────
// ─── Section (grouped card — matches Settings) ────────────────────
function Section({ label, children, first = false }) {
  return (
    <div style={{ marginTop: first ? 4 : 24 }}>
      {label && (
        <div style={{
          fontSize: 12, fontWeight: 600, letterSpacing: 0.6,
          textTransform: 'uppercase',
          color: 'var(--sn-text-3)',
          padding: '0 24px 10px',
        }}>{label}</div>
      )}
      <div style={{
        background: 'var(--sn-surface)',
        margin: '0 14px',
        borderRadius: 'var(--sn-radius-card)',
        overflow: 'hidden',
        boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
      }}>{children}</div>
    </div>
  );
}

function Row({ icon, iconBg, label, value, valueMono, trailing, isLast, accent, danger, subtitle }) {
  const labelColor = danger ? '#E04A4A' : 'var(--sn-text)';
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 16,
      padding: '15px 20px', minHeight: 62,
      position: 'relative',
    }}>
      {icon && (
        <div style={{
          width: 36, height: 36, borderRadius: 10,
          background: iconBg || 'var(--sn-accent-soft)',
          color: accent || 'var(--sn-accent)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          flexShrink: 0,
        }}>{icon}</div>
      )}
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
        <div style={{
          fontSize: 16, fontWeight: 500, letterSpacing: -0.2,
          color: labelColor,
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>{label}</div>
        {subtitle && (
          <div style={{
            fontSize: 13, fontWeight: 500, color: 'var(--sn-text-3)',
            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            letterSpacing: -0.05,
          }}>{subtitle}</div>
        )}
      </div>
      {value && (
        <div className={valueMono ? 'sn-mono' : ''} style={{
          fontSize: valueMono ? 13 : 15, fontWeight: 500,
          color: 'var(--sn-text-3)',
          whiteSpace: 'nowrap',
        }}>{value}</div>
      )}
      {trailing}
      {!isLast && (
        <div style={{
          position: 'absolute', left: icon ? 72 : 20, right: 0, bottom: 0,
          height: 0.5, background: 'var(--sn-divider)',
        }}/>
      )}
    </div>
  );
}

function Chevron() {
  return (
    <svg width="9" height="16" viewBox="0 0 8 14" fill="none" style={{ flexShrink: 0, color: 'var(--sn-text-4)' }}>
      <path d="M1 1l6 6-6 6" stroke="currentColor" strokeWidth="2" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  );
}

function Toggle({ on = true }) {
  return (
    <div style={{
      width: 50, height: 30, borderRadius: 15,
      background: on ? 'var(--sn-accent)' : 'var(--sn-text-4)',
      position: 'relative',
      transition: 'background .15s',
      flexShrink: 0,
    }}>
      <div style={{
        position: 'absolute', top: 2, left: on ? 22 : 2,
        width: 26, height: 26, borderRadius: 13,
        background: '#fff',
        boxShadow: '0 1px 2px rgba(0,0,0,0.2), 0 1px 3px rgba(0,0,0,0.1)',
        transition: 'left .15s',
      }}/>
    </div>
  );
}

// Verified badge — small green check, sits next to "Identity verified" label
function VerifiedBadge() {
  return (
    <div style={{
      display: 'inline-flex', alignItems: 'center', gap: 4,
      padding: '2px 8px 2px 6px', borderRadius: 999,
      background: 'rgba(31, 175, 110, 0.12)',
      color: 'var(--sn-success)',
      fontSize: 11, fontWeight: 700, letterSpacing: 0.1,
    }}>
      <svg width="11" height="11" viewBox="0 0 24 24" fill="none">
        <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
      VERIFIED
    </div>
  );
}

// ─── Identity section ───────────────────────────────────────────────
// Shows just enough crypto to be reassuring without scaring civilians:
// - "Identity verified" badge (after one-time safety-number compare)
// - Short fingerprint preview in mono (first 12 hex chars, ` ` every 4)
// - Linked devices count
function IdentitySection({ verified = true, fingerprint = '9a3e 4d12 8b71', deviceCount = 3 }) {
  return (
    <Section label="Identity">
      <Row
        icon={
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <path d="M12 2l8 4v6c0 5-3.5 9-8 10-4.5-1-8-5-8-10V6l8-4z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
            <path d="M8.5 12l2.5 2.5L16 9.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        }
        iconBg="rgba(31, 175, 110, 0.12)"
        accent="var(--sn-success)"
        label="Identity verified"
        subtitle={`fp · ${fingerprint}…`}
        trailing={<Chevron/>}
      />
      <Row
        icon={
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <rect x="3" y="5" width="13" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
            <rect x="14" y="9" width="7" height="10" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M8 19v1.5M11 19v1.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
        }
        label="Linked devices"
        value={`${deviceCount} active`}
        trailing={<Chevron/>}
        isLast
      />
    </Section>
  );
}

// ─── Media row (WhatsApp-style: thumbnail strip + count) ─────────
// One tappable card that opens the media browser. Top: 4 recent thumbs
// with a "+N" tile if there's more. Below: a row with totals.
function MediaRow() {
  // Stand-ins for recent media; each is a colour-coded gradient placeholder.
  // In a real build these are blurred thumbnails from cached message media.
  const thumbs = [
    { c1: '#FFB089', c2: '#FF6E54' },
    { c1: '#A0C4FF', c2: '#3B82F6' },
    { c1: '#C5A0FF', c2: '#7C3AED' },
    { c1: '#9DE6CB', c2: '#10B981' },
  ];
  const moreCount = 138;
  return (
    <div style={{
      background: 'var(--sn-surface)',
      margin: '0 14px',
      borderRadius: 'var(--sn-radius-card)',
      overflow: 'hidden',
      boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
    }}>
      {/* Thumbnail strip — horizontal scroll affordance, fills row width */}
      <div style={{
        display: 'flex', gap: 6, padding: '12px 12px 0',
      }}>
        {thumbs.map((t, i) => (
          <div key={i} style={{
            flex: 1, aspectRatio: '1 / 1',
            borderRadius: 10,
            background: `linear-gradient(150deg, ${t.c1} 0%, ${t.c2} 100%)`,
            boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.20), inset 0 -1px 0 rgba(0,0,0,0.08)',
            position: 'relative', overflow: 'hidden',
          }}>
            {/* Abstract scene hint so it doesn't look like a flat swatch */}
            <svg width="100%" height="100%" viewBox="0 0 60 60" preserveAspectRatio="xMidYMid slice" style={{ position: 'absolute', inset: 0 }}>
              <circle cx={i % 2 === 0 ? 42 : 18} cy="16" r="7" fill="rgba(255,255,255,0.45)"/>
              <path d={i % 2 === 0 ? "M0 46 Q 20 38 40 44 T 60 40 L 60 60 L 0 60 Z" : "M0 52 Q 25 44 45 50 T 60 46 L 60 60 L 0 60 Z"} fill="rgba(15,23,32,0.25)"/>
            </svg>
          </div>
        ))}
        {/* +N tile */}
        <div style={{
          flex: 1, aspectRatio: '1 / 1',
          borderRadius: 10,
          background: 'var(--sn-bg-soft)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontSize: 13, fontWeight: 700, letterSpacing: -0.1,
          color: 'var(--sn-text-2)',
        }}>+{moreCount}</div>
      </div>
      {/* Row: title + chevron */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        padding: '14px 20px 14px 16px',
      }}>
        <div style={{
          width: 28, height: 28, borderRadius: 8,
          background: 'var(--sn-accent-soft)',
          color: 'var(--sn-accent)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          flexShrink: 0,
        }}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
            <rect x="3" y="5" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
            <circle cx="9" cy="11" r="2" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M3 17l5-4 4 3 3-2 6 5" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
          </svg>
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{
            fontSize: 15, fontWeight: 500, letterSpacing: -0.15,
            color: 'var(--sn-text)',
          }}>Media, links and docs</div>
          <div style={{
            fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)',
            marginTop: 2,
          }}>142 · 23 · 8</div>
        </div>
        <Chevron/>
      </div>
    </div>
  );
}

// ─── Groups in common ───────────────────────────────────────────────
function GroupsInCommon() {
  const groups = [
    { name: 'Engineering', members: 12 },
    { name: 'Design crit', members: 6 },
    { name: 'Coffee crew', members: 4 },
  ];
  return (
    <Section label={`${groups.length} groups in common`}>
      {groups.map((g, i) => (
        <Row key={g.name}
          icon={<SnAvatar name={g.name} size={36} group/>}
          iconBg="transparent"
          label={g.name}
          value={`${g.members} members`}
          trailing={<Chevron/>}
          isLast={i === groups.length - 1}
        />
      ))}
    </Section>
  );
}

// ─── Full screen ────────────────────────────────────────────────────
function SinhronContactInfo({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <ContactTopBar floating/>

      <div className="sn-scroll" style={{ flex: 1, marginTop: -52 }}>
        <ContactHero
          name="Maria Chen"
          username="@maria_chen"
          status="Available"
          statusKind="online"
          dark={dark}
        />

        <ContactActions/>

        {/* About / bio */}
        <Section label="About" first>
          <div style={{ padding: '0 20px 6px' }}>
            <div style={{
              fontSize: 16, lineHeight: '22px', color: 'var(--sn-text)',
              letterSpacing: -0.15,
            }}>Designer at Cabin. Mornings only — text don't call ✌️</div>
          </div>
        </Section>

        {/* Info */}
        <Section label="Info">
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M16 12a4 4 0 11-8 0 4 4 0 018 0z" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M16 12v1.5a2.5 2.5 0 005 0V12a9 9 0 10-3.5 7.1" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }
            label="Username"
            value="@maria_chen"
            valueMono
          />
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            }
            label="Phone"
            value="+1 415 555 0142"
            valueMono
          />
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M12 4a5 5 0 015 5v4l2 3H5l2-3V9a5 5 0 015-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
                <path d="M10 20a2 2 0 004 0" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }
            label="Notifications"
            trailing={<Toggle on/>}
            isLast
          />
        </Section>

        {/* Identity (E2EE surfaces here) */}
        <IdentitySection verified fingerprint="9a3e 4d12 8b71" deviceCount={3}/>

        {/* Media, links, docs — WhatsApp-style row card */}
        <div style={{ marginTop: 24 }}>
          <div style={{
            fontSize: 12, fontWeight: 600, letterSpacing: 0.6,
            textTransform: 'uppercase', color: 'var(--sn-text-3)',
            padding: '0 24px 10px',
          }}>Shared</div>
          <MediaRow/>
        </div>

        {/* In-chat utilities */}
        <Section>
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M12 3.5l2.7 5.5 6 .8-4.4 4.2 1.1 6L12 17.2l-5.4 2.8 1.1-6L3.3 9.8l6-.8L12 3.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            }
            iconBg="rgba(245, 158, 11, 0.12)"
            accent="#D97706"
            label="Starred messages"
            value="14"
            trailing={<Chevron/>}
          />
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M16.5 16.5L21 21" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }
            label="Search in chat"
            trailing={<Chevron/>}
            isLast
          />
        </Section>

        {/* Groups in common */}
        <GroupsInCommon/>

        {/* Privacy controls */}
        <Section label="Privacy">
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M12 7v5l3.5 2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }
            label="Disappearing messages"
            value="Off"
            trailing={<Chevron/>}
          />
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <rect x="5" y="11" width="14" height="9" rx="2" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M8 11V8a4 4 0 018 0v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }
            label="Chat lock"
            value="Off"
            trailing={<Chevron/>}
          />
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M5.5 5.5l13 13" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }
            iconBg="rgba(224, 74, 74, 0.10)"
            accent="#E04A4A"
            label="Block contact"
            danger
          />
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M5 21V5a1 1 0 011-1h11l-2 4 2 4H6" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            }
            iconBg="rgba(224, 74, 74, 0.10)"
            accent="#E04A4A"
            label="Report contact"
            danger
            isLast
          />
        </Section>

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

Object.assign(window, { SinhronContactInfo, VerifiedBadge });
