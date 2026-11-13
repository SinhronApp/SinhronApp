// trust-polish.jsx — Identity changed warning + permission prompts
// Exports: SnIdentityChanged, SnPermNotifications, SnPermCamera, SnPermMic, SnPermContacts

// ════════════════════════════════════════════════════════════════════
// 1. Identity changed warning — banner inside a chat
// ════════════════════════════════════════════════════════════════════
function SnIdentityChanged({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <ChatHeaderMini name="Maria Chen" subtitle="last seen 2m ago"/>

      <div className="sn-scroll" style={{ flex: 1, padding: '8px 0' }}>
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Yesterday</div>
        </div>

        <div style={{ display: 'flex', justifyContent: 'flex-start', padding: '4px 12px' }}>
          <div style={{
            maxWidth: '78%', background: 'var(--sn-surface)',
            borderRadius: '18px 18px 18px 6px', padding: '8px 12px 7px',
            boxShadow: '0 1px 1px rgba(15,23,32,0.05)',
            fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
          }}>
            Their pour-over is unreal.
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4, float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2, fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)' }}>20:18</div>
          </div>
        </div>

        {/* System banner — between two timestamps */}
        <div style={{ padding: '14px 14px' }}>
          <div style={{
            background: 'var(--sn-bg-soft)',
            borderRadius: 14,
            padding: '14px 14px',
            display: 'flex', gap: 12, alignItems: 'flex-start',
            boxShadow: '0 0 0 0.5px var(--sn-divider-strong)',
          }}>
            <div style={{
              width: 32, height: 32, borderRadius: 9,
              background: 'rgba(217, 119, 6, 0.14)', color: '#C2410C',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              flexShrink: 0,
            }}>
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M12 2l8 4v6c0 5-3.5 9-8 10-4.5-1-8-5-8-10V6l8-4z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
                <path d="M12 8v5M12 16v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
              </svg>
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{
                fontSize: 14, fontWeight: 600, color: 'var(--sn-text)',
                letterSpacing: -0.1,
              }}>Maria's safety number changed</div>
              <div style={{
                fontSize: 13, fontWeight: 500, color: 'var(--sn-text-2)',
                marginTop: 3, lineHeight: '18px', letterSpacing: -0.05,
              }}>This usually means Maria set up a new device. If you've shared sensitive things, verify the new number before continuing.</div>
              <div style={{
                display: 'flex', gap: 14, marginTop: 10,
                fontSize: 13.5, fontWeight: 600, letterSpacing: -0.05,
              }}>
                <div style={{ color: 'var(--sn-accent)' }}>Verify now</div>
                <div style={{ color: 'var(--sn-text-3)' }}>Dismiss</div>
              </div>
            </div>
          </div>
        </div>

        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Today</div>
        </div>

        <div style={{ display: 'flex', justifyContent: 'flex-start', padding: '4px 12px' }}>
          <div style={{
            maxWidth: '78%', background: 'var(--sn-surface)',
            borderRadius: '18px 18px 18px 6px', padding: '8px 12px 7px',
            boxShadow: '0 1px 1px rgba(15,23,32,0.05)',
            fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
          }}>
            Hey — just got a new phone. Same me 🙂
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4, float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2, fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)' }}>08:42</div>
          </div>
        </div>
      </div>
    </div>
  );
}

// ─── Generic permission prompt shell ───────────────────────────────
// Renders a Sinhron-styled bottom-sheet sized prompt over a faint
// background, with icon, title, copy, and 2 actions.
function PermPrompt({ dark, platform, bg, icon, iconColor, iconBg, title, copy, allow = 'Allow', deny = 'Not now' }) {
  return (
    <div style={{
      width: '100%', height: '100%', position: 'relative', overflow: 'hidden',
    }}>
      {/* Background — faded chat-list */}
      <div style={{ position: 'absolute', inset: 0 }}>{bg}</div>
      <div style={{
        position: 'absolute', inset: 0,
        background: dark ? 'rgba(0,0,0,0.45)' : 'rgba(15,23,32,0.34)',
      }}/>

      {/* Card */}
      <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
        position: 'absolute', left: 20, right: 20, bottom: 36,
        background: 'var(--sn-elevated)',
        borderRadius: 22,
        padding: '24px 22px 18px',
        boxShadow: '0 24px 60px rgba(0,0,0,0.40), 0 2px 6px rgba(0,0,0,0.20)',
        display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14,
      }}>
        <div style={{
          width: 64, height: 64, borderRadius: 18,
          background: iconBg, color: iconColor,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>{icon}</div>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6, textAlign: 'center' }}>
          <div style={{ fontSize: 19, fontWeight: 600, letterSpacing: -0.3, color: 'var(--sn-text)' }}>{title}</div>
          <div style={{
            fontSize: 14, fontWeight: 500, color: 'var(--sn-text-2)',
            lineHeight: '20px', letterSpacing: -0.05,
            maxWidth: 280,
          }}>{copy}</div>
        </div>
        <div style={{ width: '100%', display: 'flex', flexDirection: 'column', gap: 8, marginTop: 6 }}>
          <DsButton variant="primary">{allow}</DsButton>
          <DsButton variant="ghost">{deny}</DsButton>
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Permission · Notifications — over fresh inbox
// ════════════════════════════════════════════════════════════════════
function SnPermNotifications({ dark = false, platform = 'ios' }) {
  return (
    <PermPrompt
      dark={dark} platform={platform}
      bg={<SnFreshInbox dark={dark} platform={platform}/>}
      iconBg="var(--sn-accent-soft)" iconColor="var(--sn-accent)"
      icon={
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none">
          <path d="M12 4a5 5 0 015 5v4l2 3H5l2-3V9a5 5 0 015-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
          <path d="M10 20a2 2 0 004 0" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
        </svg>
      }
      title="Turn on notifications"
      copy="Get a heads-up when someone messages or calls. Sinhron builds previews on your device — your server can't see them."
      allow="Turn on"
    />
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. Permission · Camera — over composer / camera-send
// ════════════════════════════════════════════════════════════════════
function SnPermCamera({ dark = false, platform = 'ios' }) {
  return (
    <PermPrompt
      dark={dark} platform={platform}
      bg={<SinhronChatView dark={dark} platform={platform}/>}
      iconBg="var(--sn-accent-soft)" iconColor="var(--sn-accent)"
      icon={
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none">
          <rect x="3" y="6" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
          <circle cx="12" cy="13" r="4" stroke="currentColor" strokeWidth="1.8"/>
          <path d="M8 6l1.5-2.5h5L16 6" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        </svg>
      }
      title="Use the camera"
      copy="To take photos and videos in chat. Captured media stays encrypted to whoever you send it to."
    />
  );
}

// ════════════════════════════════════════════════════════════════════
// 4. Permission · Microphone — over chat with voice button
// ════════════════════════════════════════════════════════════════════
function SnPermMic({ dark = false, platform = 'ios' }) {
  return (
    <PermPrompt
      dark={dark} platform={platform}
      bg={<SinhronChatView dark={dark} platform={platform}/>}
      iconBg="var(--sn-accent-soft)" iconColor="var(--sn-accent)"
      icon={
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none">
          <rect x="9" y="3" width="6" height="13" rx="3" stroke="currentColor" strokeWidth="1.8"/>
          <path d="M5 12a7 7 0 0014 0M12 19v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
        </svg>
      }
      title="Use the microphone"
      copy="To send voice messages and join calls. Audio is encrypted end-to-end and never recorded by Sinhron."
    />
  );
}

// ════════════════════════════════════════════════════════════════════
// 5. Permission · Contacts — over compose / picker
// ════════════════════════════════════════════════════════════════════
function SnPermContacts({ dark = false, platform = 'ios' }) {
  return (
    <PermPrompt
      dark={dark} platform={platform}
      bg={<SnCompose dark={dark} platform={platform}/>}
      iconBg="var(--sn-accent-soft)" iconColor="var(--sn-accent)"
      icon={
        <svg width="32" height="32" viewBox="0 0 24 24" fill="none">
          <rect x="4" y="3" width="16" height="18" rx="2" stroke="currentColor" strokeWidth="1.8"/>
          <circle cx="12" cy="10" r="3" stroke="currentColor" strokeWidth="1.8"/>
          <path d="M7 18c.6-2.4 2.7-4 5-4s4.4 1.6 5 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
        </svg>
      }
      title="Find contacts on Sinhron"
      copy="We compare your address book to Sinhron usernames locally. We never send your contacts to any server."
      allow="Find contacts"
    />
  );
}

Object.assign(window, {
  SnIdentityChanged, SnPermNotifications, SnPermCamera, SnPermMic, SnPermContacts,
});
