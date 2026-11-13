// chat-completion.jsx — Selection mode, pinned messages, error/sending states
// Exports: SnSelectionMode, SnPinnedBanner, SnPinnedList, SnErrorStates

// ════════════════════════════════════════════════════════════════════
// 1. Selection mode — multi-select bubbles + bottom action bar
// ════════════════════════════════════════════════════════════════════
function SelectBubble({ side = 'in', text, time, selected, sender }) {
  const isOut = side === 'out';
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '4px 12px',
      background: selected ? 'var(--sn-accent-soft)' : 'transparent',
      transition: 'background 0.15s',
    }}>
      {/* Selection circle */}
      <div style={{
        width: 22, height: 22, borderRadius: 11,
        background: selected ? 'var(--sn-accent)' : 'transparent',
        boxShadow: selected ? 'none' : 'inset 0 0 0 1.5px var(--sn-text-4)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        flexShrink: 0,
      }}>
        {selected && (
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
            <path d="M5 12l5 5L20 7" stroke="#fff" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        )}
      </div>

      {/* Bubble */}
      <div style={{
        flex: 1, display: 'flex',
        justifyContent: isOut ? 'flex-end' : 'flex-start',
      }}>
        <div style={{
          maxWidth: '78%',
          background: isOut ? 'var(--sn-accent)' : 'var(--sn-surface)',
          color: isOut ? '#fff' : 'var(--sn-text)',
          borderRadius: isOut ? '18px 18px 6px 18px' : '18px 18px 18px 6px',
          padding: '8px 12px 7px',
          boxShadow: isOut ? '0 1px 1px rgba(45,111,247,0.18)' : '0 1px 1px rgba(15,23,32,0.05)',
          fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
        }}>
          {sender && (
            <div style={{ fontSize: 12.5, fontWeight: 600, color: '#7C3AED', marginBottom: 2 }}>{sender}</div>
          )}
          {text}
          <div style={{
            display: 'inline-flex', alignItems: 'center', gap: 4,
            float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
            fontSize: 11, fontWeight: 500,
            color: isOut ? 'rgba(255,255,255,0.78)' : 'var(--sn-text-3)',
          }}>{time}</div>
        </div>
      </div>
    </div>
  );
}

function SnSelectionMode({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* Selection header */}
      <div style={{
        display: 'flex', alignItems: 'center',
        padding: '10px 14px',
        borderBottom: '0.5px solid var(--sn-divider)',
      }}>
        <div style={{
          fontSize: 15, fontWeight: 500, color: 'var(--sn-accent)', minWidth: 60,
          letterSpacing: -0.1,
        }}>Cancel</div>
        <div style={{
          flex: 1, textAlign: 'center',
          fontSize: 17, fontWeight: 600, letterSpacing: -0.3,
          color: 'var(--sn-text)',
        }}>3 selected</div>
        <div style={{
          fontSize: 15, fontWeight: 600, color: 'var(--sn-accent)',
          minWidth: 60, textAlign: 'right',
        }}>All</div>
      </div>

      <div className="sn-scroll" style={{ flex: 1, padding: '8px 0' }}>
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Yesterday</div>
        </div>

        <SelectBubble side="in" text="Hey! Are we still on for coffee tomorrow?" time="20:14"/>
        <SelectBubble side="out" text="Of course — same place at 9?" time="20:16" selected/>
        <SelectBubble side="in" text="Actually, let's try here instead. Their pour-over is unreal." time="20:18" selected/>

        <div style={{ display: 'flex', justifyContent: 'center', padding: '12px 0 6px' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Today</div>
        </div>

        <SelectBubble side="out" text="Sold. See you at 9 ☕" time="08:42" selected/>
        <SelectBubble side="in" text="Sounds great — see you at 9 tomorrow ☕" time="08:51"/>
      </div>

      {/* Bottom action bar */}
      <div style={{
        background: 'var(--sn-elevated)',
        borderTop: '0.5px solid var(--sn-divider)',
        padding: '10px 8px 24px',
        boxShadow: '0 -2px 12px rgba(15,23,32,0.06)',
      }}>
        <div style={{ display: 'flex', justifyContent: 'space-around', alignItems: 'center' }}>
          {[
            { label: 'Reply', icon: (
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
                <path d="M9 17l-6-6 6-6M3 11h11a6 6 0 016 6v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            ) },
            { label: 'Forward', icon: (
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
                <path d="M15 7l6 6-6 6M21 13H10a6 6 0 00-6 6v1" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            ), badge: 3 },
            { label: 'Star', icon: (
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
                <path d="M12 3.5l2.7 5.5 6 .8-4.4 4.2 1.1 6L12 17.2l-5.4 2.8 1.1-6L3.3 9.8l6-.8L12 3.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            ) },
            { label: 'Copy', icon: (
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
                <rect x="9" y="3" width="13" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M5 7v12a2 2 0 002 2h11" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            ) },
            { label: 'Delete', danger: true, icon: (
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
                <path d="M3 6h18M8 6V4a1 1 0 011-1h6a1 1 0 011 1v2M6 6l1 14a1 1 0 001 1h8a1 1 0 001-1l1-14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            ) },
          ].map(a => (
            <button key={a.label} style={{
              display: 'flex', flexDirection: 'column', alignItems: 'center',
              gap: 4, padding: '6px 10px', border: 'none',
              background: 'transparent', cursor: 'pointer',
              color: a.danger ? '#E04A4A' : 'var(--sn-text)',
              position: 'relative',
            }}>
              <div style={{ position: 'relative' }}>
                {a.icon}
                {a.badge && (
                  <span style={{
                    position: 'absolute', top: -4, right: -8,
                    minWidth: 16, height: 16, padding: '0 4px',
                    borderRadius: 8, background: 'var(--sn-accent)',
                    color: '#fff', fontSize: 10, fontWeight: 700,
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    border: '2px solid var(--sn-elevated)',
                    letterSpacing: -0.1,
                  }}>{a.badge}</span>
                )}
              </div>
              <div style={{ fontSize: 11, fontWeight: 600, letterSpacing: -0.05 }}>{a.label}</div>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Pinned banner — slim card at top of chat
// ════════════════════════════════════════════════════════════════════
function SnPinnedBanner({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <ChatHeaderMini name="Engineering" subtitle="12 members · 4 online"/>

      {/* Pinned banner */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        padding: '10px 14px',
        background: 'var(--sn-bg-soft)',
        borderBottom: '0.5px solid var(--sn-divider)',
        cursor: 'pointer',
      }}>
        {/* Pin glyph + step indicator (vertical lines, current one accent) */}
        <div style={{
          width: 22, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3,
        }}>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-accent)' }}>
            <path d="M12 2l4 4-1.5 1.5L17 10l-4 4-2.5-2.5L4 18v2h2l6.5-6.5L15 16l4-4-2.5-2.5L18 8l-4-4z" fill="currentColor"/>
          </svg>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            <div style={{ width: 2, height: 8, borderRadius: 1, background: 'var(--sn-accent)' }}/>
            <div style={{ width: 2, height: 8, borderRadius: 1, background: 'var(--sn-text-4)' }}/>
            <div style={{ width: 2, height: 8, borderRadius: 1, background: 'var(--sn-text-4)' }}/>
          </div>
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{
            fontSize: 12, fontWeight: 600, letterSpacing: -0.05,
            color: 'var(--sn-accent)',
          }}>Pinned message · 1 of 3</div>
          <div style={{
            fontSize: 14, fontWeight: 500, color: 'var(--sn-text)',
            letterSpacing: -0.05, marginTop: 1,
            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
          }}>
            <span style={{ color: 'var(--sn-text-2)' }}>Alex Park: </span>
            Standup moved to 10:30 starting Monday. Bring laptops, we're going over the SFrame migration.
          </div>
        </div>
        <div style={{ color: 'var(--sn-text-3)' }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <path d="M6 9l6 6 6-6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
      </div>

      <div className="sn-scroll" style={{ flex: 1, padding: '8px 0' }}>
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Today</div>
        </div>

        <div style={{ display: 'flex', gap: 8, alignItems: 'flex-end', padding: '0 10px', marginTop: 6 }}>
          <div style={{ width: 30, flexShrink: 0 }}>
            <SnAvatar name="Henry Park" size={30}/>
          </div>
          <div style={{
            maxWidth: '76%', background: 'var(--sn-surface)', color: 'var(--sn-text)',
            borderRadius: '18px 18px 18px 6px', padding: '7px 12px 6px',
            boxShadow: '0 1px 1px rgba(15,23,32,0.05)',
            fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
          }}>
            <div style={{ fontSize: 12.5, fontWeight: 600, color: '#3B82F6', marginBottom: 2 }}>Henry Park</div>
            bench numbers look 22% better on Android
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4, float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2, fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)' }}>12:42</div>
          </div>
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. Pinned list — full gallery of pinned messages
// ════════════════════════════════════════════════════════════════════
function SnPinnedList({ dark = false, platform = 'ios' }) {
  const pinned = [
    { sender: 'Alex Park', when: 'Today · 09:14', text: 'Standup moved to 10:30 starting Monday. Bring laptops, we\'re going over the SFrame migration.' },
    { sender: 'Vera Kuznetsova', when: 'Apr 18 · 17:22', text: 'Server keys rotated. New fingerprint posted in #ops.' },
    { sender: 'Tasha Lim', when: 'Apr 12 · 11:08', text: 'Design review every Friday at 14:00. Bring 3 things, not 30.' },
  ];
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DetailHeader title="Pinned messages"/>

      <div className="sn-scroll" style={{ flex: 1, padding: '16px 14px 24px' }}>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {pinned.map((p, i) => (
            <div key={i} style={{
              background: 'var(--sn-surface)',
              borderRadius: 'var(--sn-radius-card)',
              padding: '12px 14px',
              boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
              display: 'flex', gap: 10, alignItems: 'flex-start',
            }}>
              <SnAvatar name={p.sender} size={36}/>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{
                  display: 'flex', alignItems: 'baseline', gap: 8,
                  marginBottom: 2,
                }}>
                  <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--sn-text)', letterSpacing: -0.1 }}>{p.sender}</div>
                  <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)' }}>{p.when}</div>
                </div>
                <div style={{
                  fontSize: 14.5, fontWeight: 400, lineHeight: '20px',
                  color: 'var(--sn-text)', letterSpacing: -0.1,
                }}>{p.text}</div>
                <div style={{
                  display: 'flex', alignItems: 'center', gap: 12, marginTop: 8,
                }}>
                  <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--sn-accent)' }}>Jump to</div>
                  <div style={{ flex: 1 }}/>
                  <div style={{
                    fontSize: 13, fontWeight: 500, color: 'var(--sn-text-3)',
                    display: 'flex', alignItems: 'center', gap: 4,
                  }}>
                    <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
                      <path d="M12 2l4 4-1.5 1.5L17 10l-4 4-2.5-2.5L4 18v2h2l6.5-6.5L15 16l4-4-2.5-2.5L18 8l-4-4z" fill="currentColor"/>
                    </svg>
                    Unpin
                  </div>
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 4. Error states — sending, failed, decrypt error in one chat
// ════════════════════════════════════════════════════════════════════
function SnErrorStates({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <ChatHeaderMini name="Maria Chen" subtitle="last seen 4h ago"/>

      <div className="sn-scroll" style={{ flex: 1, padding: '8px 0' }}>
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Today</div>
        </div>

        {/* Section label */}
        <div style={{
          padding: '14px 16px 4px',
          fontSize: 10, fontWeight: 700, letterSpacing: 0.6,
          color: 'var(--sn-text-3)', textTransform: 'uppercase',
        }}>Sending</div>
        <div style={{ display: 'flex', justifyContent: 'flex-end', padding: '4px 12px' }}>
          <div style={{
            maxWidth: '78%', background: 'var(--sn-accent)', color: '#fff',
            borderRadius: '18px 18px 6px 18px', padding: '8px 12px 7px',
            fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
            opacity: 0.7,
          }}>
            On my way ☕
            <div style={{
              display: 'inline-flex', alignItems: 'center', gap: 4,
              float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
              fontSize: 11, fontWeight: 500, color: 'rgba(255,255,255,0.8)',
            }}>
              09:02
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none">
                <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="2"/>
                <path d="M12 7v5l3.5 2" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
              </svg>
            </div>
          </div>
        </div>

        {/* Failed */}
        <div style={{
          padding: '14px 16px 4px',
          fontSize: 10, fontWeight: 700, letterSpacing: 0.6,
          color: 'var(--sn-text-3)', textTransform: 'uppercase',
        }}>Failed to send</div>
        <div style={{ padding: '4px 12px' }}>
          <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
            <div style={{
              maxWidth: '78%', background: 'var(--sn-accent)', color: '#fff',
              borderRadius: '18px 18px 6px 18px', padding: '8px 12px 7px',
              fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
              opacity: 0.85,
            }}>
              Are you still around? 👀
              <div style={{
                display: 'inline-flex', alignItems: 'center', gap: 4,
                float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
                fontSize: 11, fontWeight: 500, color: 'rgba(255,255,255,0.85)',
              }}>09:04</div>
            </div>
          </div>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 6,
            justifyContent: 'flex-end', marginTop: 4,
            fontSize: 12.5, fontWeight: 600, color: '#E04A4A',
            letterSpacing: -0.05,
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
              <path d="M12 3l10 17H2L12 3z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
              <path d="M12 10v4M12 17v.5" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"/>
            </svg>
            Not delivered · Tap to retry
          </div>
        </div>

        {/* Decrypt error */}
        <div style={{
          padding: '14px 16px 4px',
          fontSize: 10, fontWeight: 700, letterSpacing: 0.6,
          color: 'var(--sn-text-3)', textTransform: 'uppercase',
        }}>Decrypt failure</div>
        <div style={{ display: 'flex', justifyContent: 'flex-start', padding: '4px 12px' }}>
          <div style={{
            maxWidth: '78%', background: 'var(--sn-surface)',
            borderRadius: '18px 18px 18px 6px', padding: '10px 14px',
            boxShadow: '0 1px 1px rgba(15,23,32,0.05), 0 0 0 0.5px rgba(224,74,74,0.30)',
            display: 'flex', alignItems: 'flex-start', gap: 10,
          }}>
            <div style={{ color: '#E04A4A', flexShrink: 0, marginTop: 1 }}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M12 8v4M12 16v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
              </svg>
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--sn-text)', letterSpacing: -0.05 }}>Message can't be opened</div>
              <div style={{ fontSize: 12.5, fontWeight: 500, color: 'var(--sn-text-2)', marginTop: 2, lineHeight: '17px' }}>This may happen after a new device — ask Maria to send it again.</div>
            </div>
          </div>
        </div>

        {/* Reverted / message deleted by sender */}
        <div style={{
          padding: '14px 16px 4px',
          fontSize: 10, fontWeight: 700, letterSpacing: 0.6,
          color: 'var(--sn-text-3)', textTransform: 'uppercase',
        }}>Deleted by sender</div>
        <div style={{ display: 'flex', justifyContent: 'flex-start', padding: '4px 12px 16px' }}>
          <div style={{
            maxWidth: '78%', background: 'transparent',
            borderRadius: '18px 18px 18px 6px', padding: '8px 12px 7px',
            boxShadow: '0 0 0 1px var(--sn-divider-strong)',
            fontSize: 14, lineHeight: '20px', letterSpacing: -0.1,
            color: 'var(--sn-text-3)', fontStyle: 'italic',
            display: 'inline-flex', alignItems: 'center', gap: 6,
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
              <path d="M3 6h18M8 6V4a1 1 0 011-1h6a1 1 0 011 1v2M6 6l1 14a1 1 0 001 1h8a1 1 0 001-1l1-14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
            This message was deleted
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SnSelectionMode, SnPinnedBanner, SnPinnedList, SnErrorStates });
