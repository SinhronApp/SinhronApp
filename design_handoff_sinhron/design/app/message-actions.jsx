// message-actions.jsx — Long-press context menu, forward sheet, message info
// Exports: SnContextMenu, SnForwardSheet, SnMessageInfo

// ════════════════════════════════════════════════════════════════════
// 1. Long-press context menu — overlay over a chat
// ════════════════════════════════════════════════════════════════════
function SnContextMenu({ dark = false, platform = 'ios' }) {
  const reactions = ['❤️', '👍', '😂', '😮', '😢', '🙏'];
  const actions = [
    { label: 'Reply', icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
        <path d="M9 17l-6-6 6-6M3 11h11a6 6 0 016 6v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
    ) },
    { label: 'Forward', icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
        <path d="M15 7l6 6-6 6M21 13H10a6 6 0 00-6 6v1" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
    ) },
    { label: 'Copy', icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
        <rect x="9" y="3" width="13" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
        <path d="M5 7v12a2 2 0 002 2h11" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
      </svg>
    ) },
    { label: 'Star', icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
        <path d="M12 3.5l2.7 5.5 6 .8-4.4 4.2 1.1 6L12 17.2l-5.4 2.8 1.1-6L3.3 9.8l6-.8L12 3.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
      </svg>
    ) },
    { label: 'Info', icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
        <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
        <path d="M12 11v6M12 7.5v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
      </svg>
    ) },
    { label: 'Delete', icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
        <path d="M3 6h18M8 6V4a1 1 0 011-1h6a1 1 0 011 1v2M6 6l1 14a1 1 0 001 1h8a1 1 0 001-1l1-14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
      </svg>
    ), danger: true },
  ];
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      position: 'relative', overflow: 'hidden',
      background: 'var(--sn-bg)',
    }}>
      {/* Background — faint chat view */}
      <div style={{ position: 'absolute', inset: 0, opacity: 0.55, filter: 'blur(0.3px)' }}>
        <SinhronChatView dark={dark} platform={platform}/>
      </div>

      {/* Heavy blur scrim */}
      <div style={{
        position: 'absolute', inset: 0,
        background: dark
          ? 'rgba(11,16,22,0.55)'
          : 'rgba(15,23,32,0.32)',
        backdropFilter: 'blur(14px)',
        WebkitBackdropFilter: 'blur(14px)',
      }}/>

      {/* Stack: reactions · bubble · actions */}
      <div style={{
        position: 'absolute', left: 12, right: 12, top: '32%',
        display: 'flex', flexDirection: 'column', gap: 10, alignItems: 'flex-start',
      }}>
        {/* Reactions strip */}
        <div style={{
          padding: '7px 8px', borderRadius: 999,
          background: 'var(--sn-elevated)',
          boxShadow: '0 14px 40px rgba(0,0,0,0.35), 0 0 0 0.5px var(--sn-divider-strong)',
          display: 'flex', gap: 4, alignItems: 'center',
          alignSelf: 'flex-start',
        }}>
          {reactions.map(r => (
            <div key={r} style={{
              width: 36, height: 36, borderRadius: '50%',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 22,
            }}>{r}</div>
          ))}
          <div style={{
            width: 36, height: 36, borderRadius: '50%',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            color: 'var(--sn-text-3)',
            background: 'var(--sn-bg-soft)',
            marginLeft: 2,
          }}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
            </svg>
          </div>
        </div>

        {/* The focussed bubble */}
        <div style={{
          maxWidth: '78%',
          background: 'var(--sn-surface)',
          color: 'var(--sn-text)',
          borderRadius: '18px 18px 18px 6px',
          padding: '8px 12px 7px',
          boxShadow: '0 14px 40px rgba(0,0,0,0.35), 0 0 0 0.5px var(--sn-divider-strong)',
          fontSize: 15, fontWeight: 400, letterSpacing: -0.15, lineHeight: '20px',
        }}>
          Actually, let's try here instead. Their pour-over is unreal.
          <div style={{
            display: 'inline-flex', alignItems: 'center', gap: 4,
            float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
            fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)',
          }}>20:18</div>
        </div>

        {/* Actions menu */}
        <div style={{
          width: 220, marginTop: 4,
          background: 'var(--sn-elevated)',
          borderRadius: 14, overflow: 'hidden',
          boxShadow: '0 14px 40px rgba(0,0,0,0.35), 0 0 0 0.5px var(--sn-divider-strong)',
        }}>
          {actions.map((a, i) => (
            <div key={a.label} style={{
              display: 'flex', alignItems: 'center', gap: 14,
              padding: '12px 16px',
              position: 'relative',
            }}>
              <div style={{
                flex: 1, fontSize: 15.5, fontWeight: 500, letterSpacing: -0.15,
                color: a.danger ? '#E04A4A' : 'var(--sn-text)',
              }}>{a.label}</div>
              <div style={{ color: a.danger ? '#E04A4A' : 'var(--sn-text-2)' }}>{a.icon}</div>
              {i < actions.length - 1 && (
                <div style={{ position: 'absolute', left: 16, right: 16, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
              )}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Forward sheet — half-modal: search + multi-pick + comment
// ════════════════════════════════════════════════════════════════════
function SnForwardSheet({ dark = false, platform = 'ios' }) {
  const selected = new Set(['Maria Chen', 'Engineering']);
  const recents = SN_SAMPLE_CHATS.slice(0, 7);
  return (
    <div style={{
      width: '100%', height: '100%',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* Background — chat view, dimmed */}
      <div style={{ position: 'absolute', inset: 0 }}>
        <SinhronChatView dark={dark} platform={platform}/>
      </div>
      <div style={{ position: 'absolute', inset: 0, background: 'rgba(15,23,32,0.45)' }}/>

      {/* Sheet */}
      <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
        position: 'absolute', left: 0, right: 0, bottom: 0,
        height: '78%',
        background: 'var(--sn-bg)',
        borderTopLeftRadius: 22, borderTopRightRadius: 22,
        display: 'flex', flexDirection: 'column',
        boxShadow: '0 -10px 40px rgba(0,0,0,0.30)',
        overflow: 'hidden',
      }}>
        {/* Grabber */}
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0 4px' }}>
          <div style={{ width: 38, height: 5, borderRadius: 3, background: 'var(--sn-text-4)' }}/>
        </div>

        {/* Header */}
        <div style={{
          display: 'flex', alignItems: 'center',
          padding: '8px 16px 10px',
        }}>
          <div style={{ fontSize: 15, fontWeight: 500, color: 'var(--sn-text-2)', minWidth: 60 }}>Cancel</div>
          <div style={{ flex: 1, fontSize: 17, fontWeight: 600, color: 'var(--sn-text)', textAlign: 'center' }}>Forward to…</div>
          <div style={{
            minWidth: 60, textAlign: 'right',
            fontSize: 15, fontWeight: 600, color: 'var(--sn-accent)',
          }}>Send</div>
        </div>

        <SearchField placeholder="Search chats"/>

        {/* Selected chips */}
        {selected.size > 0 && (
          <div style={{
            display: 'flex', gap: 8, padding: '4px 16px 8px',
            overflowX: 'auto', scrollbarWidth: 'none',
          }}>
            {[...selected].map(name => (
              <div key={name} style={{
                display: 'inline-flex', alignItems: 'center', gap: 6,
                background: 'var(--sn-accent-soft)',
                color: 'var(--sn-accent)',
                padding: '6px 10px 6px 6px',
                borderRadius: 999,
                fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1,
                flexShrink: 0,
              }}>
                <SnAvatar name={name} size={22}/>
                {name.split(' ')[0]}
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                  <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round"/>
                </svg>
              </div>
            ))}
          </div>
        )}

        <div className="sn-scroll" style={{ flex: 1, paddingBottom: 80 }}>
          <div style={{
            fontSize: 12, fontWeight: 700, letterSpacing: 0.6,
            color: 'var(--sn-text-3)',
            padding: '10px 24px 6px',
            textTransform: 'uppercase',
          }}>Recent</div>
          {recents.map((c, i) => {
            const isSel = selected.has(c.name);
            return (
              <div key={c.name} style={{
                display: 'flex', alignItems: 'center', gap: 12,
                padding: '8px 16px',
                position: 'relative',
              }}>
                <SnAvatar name={c.name} size={42} group={c.group}/>
                <div style={{ flex: 1, fontSize: 15.5, fontWeight: 500, color: 'var(--sn-text)', letterSpacing: -0.15 }}>{c.name}</div>
                <div style={{
                  width: 22, height: 22, borderRadius: 11,
                  background: isSel ? 'var(--sn-accent)' : 'transparent',
                  boxShadow: isSel ? 'none' : 'inset 0 0 0 1.5px var(--sn-text-4)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                }}>
                  {isSel && (
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                      <path d="M5 12l5 5L20 7" stroke="#fff" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
                    </svg>
                  )}
                </div>
                {i < recents.length - 1 && (
                  <div style={{ position: 'absolute', left: 70, right: 16, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
                )}
              </div>
            );
          })}
        </div>

        {/* Comment composer */}
        <div style={{
          position: 'absolute', left: 0, right: 0, bottom: 0,
          padding: '8px 12px 16px',
          background: 'var(--sn-bg)',
          borderTop: '0.5px solid var(--sn-divider)',
          display: 'flex', alignItems: 'flex-end', gap: 8,
        }}>
          <div style={{
            flex: 1, minHeight: 36, borderRadius: 18,
            background: 'var(--sn-bg-soft)',
            display: 'flex', alignItems: 'center', padding: '0 14px',
            fontSize: 15, color: 'var(--sn-text-3)',
          }}>Add a comment (optional)</div>
          <div style={{
            width: 36, height: 36, borderRadius: '50%',
            background: 'var(--sn-accent)', color: '#fff',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            boxShadow: '0 2px 6px rgba(45,111,247,0.30)',
          }}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <path d="M3 12l18-9-7 18-3-7-8-2z" fill="currentColor"/>
            </svg>
          </div>
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. Message info — delivered / read / played timestamps
// ════════════════════════════════════════════════════════════════════
function SnMessageInfo({ dark = false, platform = 'ios' }) {
  const readBy = [
    { name: 'Maria Chen', when: 'Today · 08:51' },
    { name: 'Henry Park', when: 'Today · 08:48' },
    { name: 'Tasha Lim', when: 'Today · 08:46' },
  ];
  const deliveredTo = [
    { name: 'Alex Park', when: 'Today · 08:46' },
    { name: 'Daria Lim', when: 'Today · 08:46' },
  ];
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DetailHeader title="Message info"/>

      <div className="sn-scroll" style={{ flex: 1 }}>
        {/* The message itself */}
        <div style={{
          padding: '16px 12px 8px',
          display: 'flex', justifyContent: 'flex-end',
        }}>
          <div style={{
            maxWidth: '78%',
            background: 'var(--sn-accent)', color: '#fff',
            borderRadius: '18px 18px 6px 18px',
            padding: '8px 12px 7px',
            boxShadow: '0 1px 1px rgba(45,111,247,0.18)',
            fontSize: 15, fontWeight: 400, letterSpacing: -0.15, lineHeight: '20px',
          }}>
            Sold. See you at 9 ☕
            <div style={{
              display: 'inline-flex', alignItems: 'center', gap: 4,
              float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
              fontSize: 11, fontWeight: 500, color: 'rgba(255,255,255,0.78)',
            }}>08:42</div>
          </div>
        </div>

        {/* Sent timestamp */}
        <div style={{
          padding: '6px 28px 16px',
          fontSize: 12, fontWeight: 500,
          color: 'var(--sn-text-3)', textAlign: 'right',
          letterSpacing: -0.05,
        }}>Sent · Today · 08:42:14</div>

        {/* Read by */}
        <Section label={`Read by · ${readBy.length}`}>
          {readBy.map((r, i) => (
            <div key={r.name} style={{
              display: 'flex', alignItems: 'center', gap: 12,
              padding: '10px 20px', position: 'relative',
            }}>
              <SnAvatar name={r.name} size={36}/>
              <div style={{ flex: 1, fontSize: 15.5, fontWeight: 500, color: 'var(--sn-text)', letterSpacing: -0.15 }}>{r.name}</div>
              <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--sn-text-3)' }}>{r.when}</div>
              {i < readBy.length - 1 && (
                <div style={{ position: 'absolute', left: 70, right: 0, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
              )}
            </div>
          ))}
        </Section>

        {/* Delivered to */}
        <Section label={`Delivered to · ${deliveredTo.length}`}>
          {deliveredTo.map((r, i) => (
            <div key={r.name} style={{
              display: 'flex', alignItems: 'center', gap: 12,
              padding: '10px 20px', position: 'relative',
            }}>
              <SnAvatar name={r.name} size={36}/>
              <div style={{ flex: 1, fontSize: 15.5, fontWeight: 500, color: 'var(--sn-text)', letterSpacing: -0.15 }}>{r.name}</div>
              <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--sn-text-3)' }}>{r.when}</div>
              {i < deliveredTo.length - 1 && (
                <div style={{ position: 'absolute', left: 70, right: 0, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
              )}
            </div>
          ))}
        </Section>

        {/* Reactions */}
        <Section label="Reactions · 1">
          <div style={{
            display: 'flex', alignItems: 'center', gap: 12,
            padding: '10px 20px',
          }}>
            <div style={{
              width: 36, height: 36, borderRadius: 9,
              background: 'var(--sn-bg-soft)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 18,
            }}>❤️</div>
            <div style={{ flex: 1, fontSize: 15.5, fontWeight: 500, color: 'var(--sn-text)' }}>Maria Chen</div>
            <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--sn-text-3)' }}>Today · 08:52</div>
          </div>
        </Section>

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

Object.assign(window, { SnContextMenu, SnForwardSheet, SnMessageInfo });
