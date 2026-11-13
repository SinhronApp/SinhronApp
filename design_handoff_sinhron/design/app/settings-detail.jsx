// settings-detail.jsx — All Settings sub-screens
// Exports: SnLinkedDevices, SnRecoveryReveal, SnAppLockSetup,
// SnPrivacySecurity, SnProfileEdit, SnDisappearingPicker, SnNotificationsDetail

// ─── Detail page chrome — back button + title ──────────────────────
function DetailHeader({ title }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center',
      padding: '8px 14px 10px',
      borderBottom: '0.5px solid var(--sn-divider)',
      background: 'var(--sn-bg)',
      position: 'relative', zIndex: 4,
    }}>
      <button style={{
        width: 32, height: 32, borderRadius: 10, border: 'none',
        background: 'transparent', padding: 0, cursor: 'pointer',
        color: 'var(--sn-text)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        marginLeft: -6,
      }}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
          <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </button>
      <div style={{
        flex: 1, fontSize: 17, fontWeight: 600, letterSpacing: -0.3,
        color: 'var(--sn-text)', textAlign: 'center',
        marginRight: 26,
      }}>{title}</div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. Linked devices — list with last-seen + Remove
// ════════════════════════════════════════════════════════════════════
function SnLinkedDevices({ dark = false, platform = 'ios' }) {
  const devices = [
    { name: 'iPhone 15 Pro', tag: 'This device', lastSeen: 'Active now', icon: 'phone', current: true },
    { name: 'MacBook Pro · 16"', tag: 'Desktop', lastSeen: 'Active 2m ago', icon: 'desktop' },
    { name: 'iPad mini', tag: 'Tablet', lastSeen: 'Last seen 4h ago', icon: 'tablet' },
  ];
  const ICONS = {
    phone: <rect x="7" y="3" width="10" height="18" rx="2" stroke="currentColor" strokeWidth="1.8"/>,
    desktop: <><rect x="3" y="4" width="18" height="12" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><path d="M8 20h8M12 16v4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>,
    tablet: <rect x="5" y="3" width="14" height="18" rx="2" stroke="currentColor" strokeWidth="1.8"/>,
  };
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DetailHeader title="Linked devices"/>

      <div className="sn-scroll" style={{ flex: 1 }}>
        <div style={{
          fontSize: 13, fontWeight: 500, color: 'var(--sn-text-2)',
          padding: '16px 24px 6px', lineHeight: '19px', letterSpacing: -0.05,
        }}>Sinhron syncs your messages across every device you link. Each device has its own keys — removing one revokes its access immediately.</div>

        <Section label="Active" first>
          {devices.map((d, i) => (
            <Row
              key={d.name}
              icon={
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none">{ICONS[d.icon]}</svg>
              }
              iconBg={d.current ? 'rgba(31,175,110,0.12)' : 'var(--sn-accent-soft)'}
              accent={d.current ? 'var(--sn-success)' : 'var(--sn-accent)'}
              label={d.name}
              subtitle={`${d.tag} · ${d.lastSeen}`}
              trailing={!d.current && <Chevron/>}
              isLast={i === devices.length - 1}
            />
          ))}
        </Section>

        <Section>
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
              </svg>
            }
            label="Link a new device"
            trailing={<Chevron/>}
            isLast
          />
        </Section>

        <Section label={null}>
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M3 6h18M8 6V4a1 1 0 011-1h6a1 1 0 011 1v2M6 6l1 14a1 1 0 001 1h8a1 1 0 001-1l1-14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }
            iconBg="rgba(224,74,74,0.10)"
            accent="#E04A4A"
            label="Remove all other devices"
            danger
            isLast
          />
        </Section>

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Recovery phrase reveal — blur overlay until tapped
// ════════════════════════════════════════════════════════════════════
function SnRecoveryReveal({ dark = false, platform = 'ios', revealed = false }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DetailHeader title="Recovery phrase"/>

      <div className="sn-scroll" style={{ flex: 1, padding: '16px 20px 0' }}>
        <div style={{
          fontSize: 13, fontWeight: 500, color: 'var(--sn-text-2)',
          padding: '0 4px 16px', lineHeight: '19px', letterSpacing: -0.05,
        }}>This is the only way to recover your account if you lose every device. Don't screenshot it. Don't share it. Write it down on paper.</div>

        <DsMnemonicGrid revealed={revealed}/>

        <div style={{ height: 14 }}/>
        {/* Anti-screenshot warning */}
        <div style={{
          display: 'flex', alignItems: 'flex-start', gap: 10,
          padding: '12px 14px',
          background: 'rgba(224, 74, 74, 0.08)',
          borderRadius: 12,
        }}>
          <div style={{ color: '#E04A4A', flexShrink: 0, marginTop: 1 }}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <path d="M12 3l10 17H2L12 3z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              <path d="M12 10v4M12 17v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
            </svg>
          </div>
          <div style={{
            fontSize: 13, fontWeight: 500, color: 'var(--sn-text-2)',
            lineHeight: '18px', letterSpacing: -0.05,
          }}>Screenshots of this screen are blocked. If someone reads your phrase they can read every conversation on every device.</div>
        </div>

        <div style={{ height: 16 }}/>
      </div>

      <div style={{ padding: '0 20px 18px', display: 'flex', flexDirection: 'column', gap: 10 }}>
        <DsButton variant="secondary" leading={
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <rect x="9" y="3" width="13" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M5 7v12a2 2 0 002 2h11" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
        }>Copy to clipboard</DsButton>
        <DsButton variant="ghost">Verify I've saved it</DsButton>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. App lock / PIN setup
// ════════════════════════════════════════════════════════════════════
function SnAppLockSetup({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DetailHeader title="App lock"/>

      <div className="sn-scroll" style={{ flex: 1 }}>
        <div style={{
          fontSize: 13, fontWeight: 500, color: 'var(--sn-text-2)',
          padding: '16px 24px 6px', lineHeight: '19px', letterSpacing: -0.05,
        }}>Require a check before Sinhron opens. Your messages stay decrypted only while the app is in front.</div>

        <Section label="Method" first>
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M4 8V6a2 2 0 012-2h2M16 4h2a2 2 0 012 2v2M20 16v2a2 2 0 01-2 2h-2M8 20H6a2 2 0 01-2-2v-2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
                <circle cx="9" cy="11" r="0.8" fill="currentColor"/>
                <circle cx="15" cy="11" r="0.8" fill="currentColor"/>
                <path d="M10 16c.5.5 1.2.8 2 .8s1.5-.3 2-.8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" fill="none"/>
              </svg>
            }
            label="Face ID"
            trailing={<Toggle on/>}
          />
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <rect x="5" y="11" width="14" height="9" rx="2" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M8 11V8a4 4 0 018 0v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }
            label="6-digit PIN"
            value="Set"
            trailing={<Chevron/>}
            isLast
          />
        </Section>

        <Section label="Auto-lock"
          footer="After the timeout, the next open requires Face ID or your PIN.">
          {['Immediately', 'After 1 minute', 'After 5 minutes', 'After 1 hour', 'Off'].map((opt, i, arr) => (
            <Row
              key={opt}
              label={opt}
              trailing={i === 1 ? (
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-accent)' }}>
                  <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              ) : null}
              isLast={i === arr.length - 1}
            />
          ))}
        </Section>

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 4. Privacy & security — granular toggles
// ════════════════════════════════════════════════════════════════════
function SnPrivacySecurity({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DetailHeader title="Privacy & security"/>

      <div className="sn-scroll" style={{ flex: 1 }}>
        <Section label="Who can see" first>
          <Row label="Last seen" value="Everyone" trailing={<Chevron/>}/>
          <Row label="Profile photo" value="Contacts" trailing={<Chevron/>}/>
          <Row label="About" value="Everyone" trailing={<Chevron/>}/>
          <Row label="Read receipts" trailing={<Toggle on/>}/>
          <Row label="Typing indicators" trailing={<Toggle on/>} isLast/>
        </Section>

        <Section label="Messages">
          <Row label="Disappearing messages" value="Off" trailing={<Chevron/>}/>
          <Row label="Default chat lock" trailing={<Toggle on={false}/>} isLast/>
        </Section>

        <Section label="Screen"
          footer="When on, Sinhron hides chat content in the app switcher and blocks screenshots.">
          <Row label="Privacy screen" trailing={<Toggle on/>}/>
          <Row label="Block screenshots" trailing={<Toggle on/>} isLast/>
        </Section>

        <Section label="Calls"
          footer="When off, your calls connect peer-to-peer with no relay. Some networks may block this.">
          <Row label="Relay calls through server" trailing={<Toggle on={false}/>} isLast/>
        </Section>

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 5. Profile edit
// ════════════════════════════════════════════════════════════════════
function SnProfileEdit({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <div style={{
        display: 'flex', alignItems: 'center',
        padding: '10px 16px', minHeight: 48,
        borderBottom: '0.5px solid var(--sn-divider)',
      }}>
        <div style={{ fontSize: 15, fontWeight: 500, color: 'var(--sn-text-2)', minWidth: 60 }}>Cancel</div>
        <div style={{ flex: 1, fontSize: 17, fontWeight: 600, color: 'var(--sn-text)', textAlign: 'center' }}>Edit profile</div>
        <div style={{ minWidth: 60, textAlign: 'right', fontSize: 15, fontWeight: 600, color: 'var(--sn-accent)' }}>Save</div>
      </div>

      <div className="sn-scroll" style={{ flex: 1 }}>
        {/* Avatar with edit */}
        <div style={{
          display: 'flex', flexDirection: 'column', alignItems: 'center',
          padding: '24px 24px 18px',
        }}>
          <div style={{ position: 'relative' }}>
            <SnAvatar name="Vera Kuznetsova" size={96}/>
            <div style={{
              position: 'absolute', bottom: -2, right: -2,
              width: 30, height: 30, borderRadius: 15,
              background: 'var(--sn-accent)',
              color: '#fff',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              boxShadow: '0 2px 6px rgba(45,111,247,0.30), 0 0 0 3px var(--sn-bg)',
            }}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                <path d="M3 19h18M6 16l9-9 3 3-9 9H6v-3z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
              </svg>
            </div>
          </div>
          <div style={{
            fontSize: 13, fontWeight: 500, color: 'var(--sn-accent)',
            marginTop: 10, letterSpacing: -0.05,
          }}>Change photo</div>
        </div>

        <div style={{ padding: '0 20px', display: 'flex', flexDirection: 'column', gap: 14 }}>
          <DsTextField label="Name" value="Vera Kuznetsova" focused/>
          <DsTextField label="Username" prefix="@" value="vera_k" mono/>
          <DsTextField label="About" value="Mornings only — text don't call ✌️"/>
        </div>

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 6. Disappearing messages picker
// ════════════════════════════════════════════════════════════════════
function SnDisappearingPicker({ dark = false, platform = 'ios' }) {
  const options = [
    { id: '24h', label: '24 hours' },
    { id: '7d', label: '7 days' },
    { id: '30d', label: '30 days' },
    { id: '90d', label: '90 days' },
    { id: 'off', label: 'Off' },
  ];
  const active = '7d';
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DetailHeader title="Disappearing messages"/>

      <div className="sn-scroll" style={{ flex: 1 }}>
        {/* Hero illustration */}
        <div style={{
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          padding: '24px 24px 16px',
        }}>
          <div style={{
            width: 88, height: 88, borderRadius: 24,
            background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <svg width="44" height="44" viewBox="0 0 24 24" fill="none">
              <path d="M5 4h14l-2 6 2 6H5l2-6-2-6z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              <path d="M3 20h18" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          </div>
        </div>

        <div style={{
          fontSize: 13, fontWeight: 500, color: 'var(--sn-text-2)',
          padding: '0 28px 8px', lineHeight: '19px', letterSpacing: -0.05,
          textAlign: 'center',
        }}>New messages will disappear after the time you choose. Already-sent messages aren't affected.</div>

        <Section label="Timer">
          {options.map((opt, i) => {
            const isActive = opt.id === active;
            return (
              <Row
                key={opt.id}
                label={opt.label}
                trailing={isActive ? (
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-accent)' }}>
                    <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                ) : null}
                isLast={i === options.length - 1}
              />
            );
          })}
        </Section>

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 7. Notifications detail
// ════════════════════════════════════════════════════════════════════
function SnNotificationsDetail({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DetailHeader title="Notifications"/>

      <div className="sn-scroll" style={{ flex: 1 }}>
        <Section label="Messages" first>
          <Row label="Show notifications" trailing={<Toggle on/>}/>
          <Row label="Sound" value="Chime" trailing={<Chevron/>}/>
          <Row label="Vibrate" trailing={<Toggle on/>} isLast/>
        </Section>

        <Section label="Preview"
          footer="Hide preview keeps message contents off the lock screen. Sinhron builds previews locally after decryption — your server can't see them.">
          <Row label="Show sender name" trailing={<Toggle on/>}/>
          <Row label="Show message text" trailing={<Toggle on={false}/>} isLast/>
        </Section>

        <Section label="Calls">
          <Row label="Show notifications" trailing={<Toggle on/>}/>
          <Row label="Ringtone" value="Sinhron" trailing={<Chevron/>}/>
          <Row label="Vibrate" trailing={<Toggle on/>} isLast/>
        </Section>

        <Section label="Other"
          footer="Reactions and system messages (like 'X joined the group') won't generate a separate notification when off.">
          <Row label="Reactions" trailing={<Toggle on/>}/>
          <Row label="System messages" trailing={<Toggle on={false}/>} isLast/>
        </Section>

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

Object.assign(window, {
  SnLinkedDevices, SnRecoveryReveal, SnAppLockSetup,
  SnPrivacySecurity, SnProfileEdit, SnDisappearingPicker, SnNotificationsDetail,
});
