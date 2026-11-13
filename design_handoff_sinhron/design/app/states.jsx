// states.jsx — Archived chats, Blocked list, Empty inbox, Connection error toast, Update available
// Exports: SnArchived, SnBlocked, SnFreshInbox, SnReconnecting, SnUpdateAvailable

// ════════════════════════════════════════════════════════════════════
// 1. Archived chats — like chat list but with a quieter top + sample rows
// ════════════════════════════════════════════════════════════════════
function SnArchived({ dark = false, platform = 'ios' }) {
  const archived = [
    { name: 'Old project Q3', group: true, preview: 'wrapping up, archiving channel', time: 'Mar 8', muted: true },
    { name: 'Robin Vasquez', preview: 'Sent the contract over', time: 'Mar 4', sent: true, read: true },
    { name: 'Apartment search', group: true, preview: 'Found one — moved in last week', time: 'Feb 22', muted: true },
    { name: 'Coffee crew · 2023', group: true, preview: 'see you guys next year ✌️', time: 'Dec 30, 2023', muted: true },
  ];
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DetailHeader title="Archived"/>

      <div className="sn-scroll" style={{ flex: 1 }}>
        <div style={{
          fontSize: 13, fontWeight: 500, color: 'var(--sn-text-2)',
          padding: '14px 24px 4px', lineHeight: '19px', letterSpacing: -0.05,
        }}>Archived chats stay quiet — no notifications, no badge. Swipe to bring one back.</div>

        <div style={{ marginTop: 12 }}>
          {archived.map((c, i) => (
            <SnChatRow key={i} chat={c} isLast={i === archived.length - 1}/>
          ))}
        </div>

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Blocked list
// ════════════════════════════════════════════════════════════════════
function SnBlocked({ dark = false, platform = 'ios' }) {
  const blocked = [
    { name: 'Unknown · @sn-x4hf', when: 'Apr 18' },
    { name: 'spammer__99', when: 'Mar 27' },
    { name: 'Phantom Lee', when: 'Feb 4' },
  ];
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DetailHeader title="Blocked"/>

      <div className="sn-scroll" style={{ flex: 1 }}>
        <div style={{
          fontSize: 13, fontWeight: 500, color: 'var(--sn-text-2)',
          padding: '14px 24px 14px', lineHeight: '19px', letterSpacing: -0.05,
        }}>Blocked people can't message you, call you, or see your profile. They don't get told they were blocked.</div>

        {blocked.length === 0 ? (
          <div style={{
            display: 'flex', flexDirection: 'column', alignItems: 'center',
            padding: '60px 32px', textAlign: 'center', gap: 14,
          }}>
            <div style={{
              width: 64, height: 64, borderRadius: 18,
              background: 'var(--sn-bg-soft)', color: 'var(--sn-text-3)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
              <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
                <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M5.5 5.5l13 13" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            </div>
            <div style={{ fontSize: 16, fontWeight: 600, color: 'var(--sn-text)' }}>No one blocked</div>
          </div>
        ) : (
          <Section first>
            {blocked.map((b, i) => (
              <div key={b.name} style={{
                display: 'flex', alignItems: 'center', gap: 12,
                padding: '10px 20px', position: 'relative',
              }}>
                <SnAvatar name={b.name} size={36}/>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{
                    fontSize: 15.5, fontWeight: 500, color: 'var(--sn-text)',
                    whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                  }}>{b.name}</div>
                  <div style={{ fontSize: 12.5, fontWeight: 500, color: 'var(--sn-text-3)' }}>Blocked {b.when}</div>
                </div>
                <div style={{
                  fontSize: 14, fontWeight: 600,
                  color: 'var(--sn-accent)', letterSpacing: -0.1,
                }}>Unblock</div>
                {i < blocked.length - 1 && (
                  <div style={{ position: 'absolute', left: 70, right: 0, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
                )}
              </div>
            ))}
          </Section>
        )}

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. Fresh inbox — brand-new account, never had a chat
// ════════════════════════════════════════════════════════════════════
function SnFreshInbox({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      position: 'relative', overflow: 'hidden',
    }}>
      <SnHeader/>

      <div style={{ flex: 1, padding: '12px 28px', display: 'flex', flexDirection: 'column' }}>
        <div style={{
          flex: 1, display: 'flex', flexDirection: 'column',
          alignItems: 'center', justifyContent: 'center',
          textAlign: 'center', gap: 16,
        }}>
          <SinhronMark size={56}/>
          <div style={{
            fontSize: 22, fontWeight: 600, letterSpacing: -0.5,
            color: 'var(--sn-text)',
          }}>Welcome to Sinhron</div>
          <div style={{
            fontSize: 15, fontWeight: 500, lineHeight: '22px',
            color: 'var(--sn-text-2)', maxWidth: 300, letterSpacing: -0.1,
          }}>Your chats will appear here. Start by adding a contact or creating a group.</div>
        </div>

        {/* Two-button stack */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10, paddingBottom: 24 }}>
          <DsButton variant="primary" leading={
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <circle cx="11" cy="9" r="4" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M3 21c0-4 3.2-7 7-7s7 3 7 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              <path d="M19 6v6M16 9h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          }>Add a contact</DsButton>
          <DsButton variant="secondary" leading={
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <circle cx="9" cy="9" r="3" stroke="currentColor" strokeWidth="1.8"/>
              <circle cx="17" cy="10" r="2.5" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M3 19c0-3 2.5-5 6-5s6 2 6 5M14 19c.4-2 2-3.5 4-3.5s3.5 1.5 3.5 3.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          }>Start a group</DsButton>
        </div>
      </div>

      <SnTabBar platform={platform} dark={dark}/>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 4. Reconnecting toast — over chat list
// ════════════════════════════════════════════════════════════════════
function SnReconnecting({ dark = false, platform = 'ios' }) {
  return (
    <div style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden' }}>
      <SinhronChatList dark={dark} platform={platform}/>

      {/* Inline status banner — under the header, slim, accent-soft */}
      <div style={{
        position: 'absolute', left: 14, right: 14, top: 96,
        background: 'var(--sn-accent-soft)',
        borderRadius: 12,
        padding: '12px 14px',
        display: 'flex', alignItems: 'center', gap: 12,
        boxShadow: '0 8px 24px rgba(15,23,32,0.10), 0 0 0 0.5px var(--sn-accent)',
      }} className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`}>
        {/* Spinning ring */}
        <div style={{
          width: 22, height: 22, borderRadius: 11,
          border: '2px solid var(--sn-accent-soft)',
          borderTopColor: 'var(--sn-accent)',
          flexShrink: 0,
          animation: 'sn-spin 0.9s linear infinite',
        }}/>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--sn-accent)', letterSpacing: -0.1 }}>Reconnecting…</div>
          <div style={{ fontSize: 12.5, fontWeight: 500, color: 'var(--sn-text-2)' }}>cabin.sinhron.app · attempt 2</div>
        </div>
        <div style={{
          fontSize: 13, fontWeight: 600,
          color: 'var(--sn-accent)', padding: '6px 4px',
        }}>Retry</div>
      </div>

      {/* spin keyframes */}
      <style dangerouslySetInnerHTML={{ __html: '@keyframes sn-spin{to{transform:rotate(360deg)}}' }}/>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 5. Update available — half-modal
// ════════════════════════════════════════════════════════════════════
function SnUpdateAvailable({ dark = false, platform = 'ios' }) {
  const notes = [
    'Group calls up to 8 people',
    'Faster startup on linked devices',
    'Voice messages now save to your library',
    'Fixes for a rare race when receiving 3+ photos at once',
  ];
  return (
    <div style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden' }}>
      <SinhronChatList dark={dark} platform={platform}/>
      <div style={{ position: 'absolute', inset: 0, background: 'rgba(15,23,32,0.50)' }}/>

      {/* Sheet */}
      <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
        position: 'absolute', left: 0, right: 0, bottom: 0,
        background: 'var(--sn-bg)',
        borderTopLeftRadius: 22, borderTopRightRadius: 22,
        display: 'flex', flexDirection: 'column',
        boxShadow: '0 -10px 40px rgba(0,0,0,0.30)',
        padding: '14px 0 22px',
      }}>
        {/* Grabber */}
        <div style={{ display: 'flex', justifyContent: 'center', paddingBottom: 8 }}>
          <div style={{ width: 38, height: 5, borderRadius: 3, background: 'var(--sn-text-4)' }}/>
        </div>

        {/* Mark + version */}
        <div style={{
          display: 'flex', alignItems: 'center', gap: 14,
          padding: '8px 22px 18px',
        }}>
          <SinhronMark size={48}/>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 20, fontWeight: 600, letterSpacing: -0.4, color: 'var(--sn-text)' }}>Sinhron 1.6</div>
            <div className="sn-mono" style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)' }}>was 1.5.2 · 24 MB</div>
          </div>
        </div>

        {/* What's new */}
        <div style={{
          margin: '0 14px 18px',
          padding: '14px 18px',
          background: 'var(--sn-surface)',
          borderRadius: 'var(--sn-radius-card)',
          boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
        }}>
          <div style={{
            fontSize: 11, fontWeight: 700, letterSpacing: 0.6,
            color: 'var(--sn-text-3)', textTransform: 'uppercase',
            marginBottom: 12,
          }}>What's new</div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {notes.map((n, i) => (
              <div key={i} style={{ display: 'flex', gap: 10, alignItems: 'flex-start' }}>
                <div style={{
                  width: 16, height: 16, borderRadius: 8, marginTop: 3,
                  background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  flexShrink: 0,
                }}>
                  <svg width="10" height="10" viewBox="0 0 24 24" fill="none">
                    <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                </div>
                <div style={{
                  flex: 1, fontSize: 14, fontWeight: 500,
                  color: 'var(--sn-text)', letterSpacing: -0.1, lineHeight: '20px',
                }}>{n}</div>
              </div>
            ))}
          </div>
        </div>

        {/* CTAs */}
        <div style={{ padding: '0 20px', display: 'flex', flexDirection: 'column', gap: 10 }}>
          <DsButton variant="primary">Update now</DsButton>
          <DsButton variant="ghost">Later</DsButton>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SnArchived, SnBlocked, SnFreshInbox, SnReconnecting, SnUpdateAvailable });
