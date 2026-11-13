// search.jsx — Global search (across everything) + In-chat search
// Exports: SnGlobalSearch, SnSearchInChat

// ─── Highlighted text span ──────────────────────────────────────────
function Hi({ children }) {
  return <mark style={{
    background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
    fontWeight: 600, padding: '0 1px', borderRadius: 3,
  }}>{children}</mark>;
}

// ════════════════════════════════════════════════════════════════════
// 1. Global search — typed query with grouped results
// ════════════════════════════════════════════════════════════════════
function SnGlobalSearch({ dark = false, platform = 'ios' }) {
  const query = 'pour';
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* Header — active search field */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '8px 14px 12px',
      }}>
        <div style={{ fontSize: 15, fontWeight: 500, color: 'var(--sn-text-2)', flexShrink: 0, minWidth: 0 }}>Cancel</div>
        <div style={{
          flex: 1, display: 'flex', alignItems: 'center', gap: 8,
          background: 'var(--sn-bg-soft)',
          borderRadius: 11, height: 38, padding: '0 12px',
          boxShadow: '0 0 0 2px var(--sn-accent-soft), 0 0 0 0.5px var(--sn-accent)',
        }}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-text-3)', flexShrink: 0 }}>
            <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M16.5 16.5L21 21" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
          <div style={{
            flex: 1, fontSize: 15, fontWeight: 500,
            color: 'var(--sn-text)', letterSpacing: -0.1,
            display: 'flex', alignItems: 'center',
          }}>
            {query}
            <span style={{ width: 1.5, height: 16, background: 'var(--sn-accent)', marginLeft: 2, animation: 'sn-blink 1s steps(2) infinite' }}/>
          </div>
          <div style={{
            width: 18, height: 18, borderRadius: 9,
            background: 'var(--sn-text-4)', color: 'var(--sn-bg)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            flexShrink: 0,
          }}>
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none">
              <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="3" strokeLinecap="round"/>
            </svg>
          </div>
        </div>
      </div>

      {/* Filter pills */}
      <div style={{
        display: 'flex', gap: 8, padding: '0 14px 10px',
        overflowX: 'auto', scrollbarWidth: 'none',
      }}>
        {[
          { id: 'all', label: 'All', count: 8 },
          { id: 'chats', label: 'Chats', count: 2 },
          { id: 'messages', label: 'Messages', count: 5 },
          { id: 'media', label: 'Media', count: 1 },
        ].map(f => {
          const active = f.id === 'all';
          return (
            <div key={f.id} style={{
              display: 'inline-flex', alignItems: 'center', gap: 6,
              padding: '7px 14px',
              borderRadius: 999,
              background: active ? 'var(--sn-accent-soft)' : 'transparent',
              color: active ? 'var(--sn-accent)' : 'var(--sn-text-2)',
              fontSize: 13, fontWeight: 600, letterSpacing: -0.1,
              flexShrink: 0,
            }}>
              {f.label}
              <span style={{
                fontSize: 11, fontWeight: 700,
                background: active ? 'var(--sn-accent)' : 'var(--sn-bg-soft)',
                color: active ? '#fff' : 'var(--sn-text-3)',
                padding: '1px 6px', borderRadius: 999,
              }}>{f.count}</span>
            </div>
          );
        })}
      </div>

      <div className="sn-scroll" style={{ flex: 1 }}>
        {/* CHATS */}
        <div style={{
          fontSize: 12, fontWeight: 700, letterSpacing: 0.6,
          color: 'var(--sn-text-3)', textTransform: 'uppercase',
          padding: '8px 24px 6px',
        }}>Chats</div>
        {[
          { name: 'Pourover Lovers', group: true, members: '4 members' },
          { name: 'Maria Chen', status: 'online' },
        ].map((c, i, arr) => (
          <div key={c.name} style={{
            display: 'flex', alignItems: 'center', gap: 12,
            padding: '8px 16px', position: 'relative',
          }}>
            <SnAvatar name={c.name} size={42} group={c.group} online={c.status === 'online'}/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 16, fontWeight: 500, color: 'var(--sn-text)', letterSpacing: -0.15 }}>
                {c.name.split(new RegExp(`(${query})`, 'i')).map((p, j) =>
                  p.toLowerCase() === query ? <Hi key={j}>{p}</Hi> : p
                )}
              </div>
              <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--sn-text-3)' }}>{c.members || c.status}</div>
            </div>
            {i < arr.length - 1 && (
              <div style={{ position: 'absolute', left: 70, right: 16, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
            )}
          </div>
        ))}

        {/* MESSAGES */}
        <div style={{
          fontSize: 12, fontWeight: 700, letterSpacing: 0.6,
          color: 'var(--sn-text-3)', textTransform: 'uppercase',
          padding: '20px 24px 6px',
        }}>Messages</div>
        {[
          { who: 'Maria Chen', when: 'Today · 08:42', text: 'Their pour-over is unreal.' },
          { who: 'Engineering', when: 'Yesterday', text: 'best pour-over rig I\'ve ever owned', sender: 'Henry Park', group: true },
          { who: 'Mom', when: '3 days ago', text: 'try the pour-over there' },
        ].map((m, i, arr) => (
          <div key={i} style={{
            display: 'flex', alignItems: 'flex-start', gap: 12,
            padding: '10px 16px', position: 'relative',
          }}>
            <SnAvatar name={m.who} size={42} group={m.group}/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 2 }}>
                <div style={{
                  flex: 1, fontSize: 15, fontWeight: 600, color: 'var(--sn-text)', letterSpacing: -0.15,
                  whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                }}>{m.who}</div>
                <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)', whiteSpace: 'nowrap' }}>{m.when}</div>
              </div>
              <div style={{
                fontSize: 14, fontWeight: 400, color: 'var(--sn-text-2)',
                lineHeight: '19px', letterSpacing: -0.05,
              }}>
                {m.sender && <span style={{ color: 'var(--sn-text)', fontWeight: 500 }}>{m.sender}: </span>}
                {m.text.split(new RegExp(`(${query})`, 'i')).map((p, j) =>
                  p.toLowerCase() === query ? <Hi key={j}>{p}</Hi> : p
                )}
              </div>
            </div>
            {i < arr.length - 1 && (
              <div style={{ position: 'absolute', left: 70, right: 16, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
            )}
          </div>
        ))}

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Search in chat — strip overlaid on existing conversation
// ════════════════════════════════════════════════════════════════════
function SnSearchInChat({ dark = false, platform = 'ios' }) {
  const query = 'coffee';
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* Search bar replaces header */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '8px 14px 10px',
        background: 'var(--sn-bg)',
        borderBottom: '0.5px solid var(--sn-divider)',
        position: 'relative', zIndex: 4,
      }}>
        <button style={{
          width: 32, height: 32, borderRadius: 10, border: 'none',
          background: 'transparent', padding: 0, cursor: 'pointer',
          color: 'var(--sn-text)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          marginLeft: -6, flexShrink: 0,
        }}>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
            <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </button>
        <div style={{
          flex: 1, display: 'flex', alignItems: 'center', gap: 8,
          background: 'var(--sn-bg-soft)',
          borderRadius: 11, height: 36, padding: '0 12px',
        }}>
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-text-3)', flexShrink: 0 }}>
            <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M16.5 16.5L21 21" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
          <div style={{ flex: 1, fontSize: 14, fontWeight: 500, color: 'var(--sn-text)', letterSpacing: -0.1 }}>{query}</div>
          <div className="sn-mono" style={{ fontSize: 12, fontWeight: 600, color: 'var(--sn-text-3)' }}>1 / 3</div>
        </div>
      </div>

      <div style={{
        display: 'flex', alignItems: 'center',
        padding: '6px 16px 0',
      }}>
        <div style={{
          fontSize: 12, fontWeight: 600, color: 'var(--sn-text-3)',
          letterSpacing: 0.4, textTransform: 'uppercase',
        }}>3 matches</div>
        <div style={{ flex: 1 }}/>
        <div style={{ display: 'flex', gap: 6 }}>
          <div style={{
            width: 30, height: 30, borderRadius: 8,
            background: 'var(--sn-bg-soft)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            color: 'var(--sn-text-3)',
          }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <path d="M6 9l6 6 6-6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </div>
          <div style={{
            width: 30, height: 30, borderRadius: 8,
            background: 'var(--sn-accent-soft)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            color: 'var(--sn-accent)',
          }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <path d="M6 15l6-6 6 6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </div>
        </div>
      </div>

      {/* Date jumper + matched bubbles */}
      <div className="sn-scroll" style={{ flex: 1, padding: '8px 0' }}>
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Yesterday</div>
        </div>

        {/* Active match — accent ring */}
        <div style={{
          display: 'flex', justifyContent: 'flex-start',
          padding: '4px 12px',
        }}>
          <div style={{
            maxWidth: '78%', background: 'var(--sn-surface)',
            color: 'var(--sn-text)',
            borderRadius: '18px 18px 18px 6px',
            padding: '8px 12px',
            boxShadow: '0 0 0 2px var(--sn-accent-soft), 0 1px 1px rgba(15,23,32,0.05)',
            fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
          }}>
            Are we still on for <Hi>coffee</Hi> tomorrow?
            <div style={{
              display: 'inline-flex', alignItems: 'center', gap: 4,
              float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
              fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)',
            }}>20:14</div>
          </div>
        </div>

        <div style={{ display: 'flex', justifyContent: 'flex-end', padding: '4px 12px' }}>
          <div style={{
            maxWidth: '78%', background: 'var(--sn-accent)', color: '#fff',
            borderRadius: '18px 18px 6px 18px',
            padding: '8px 12px',
            fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
          }}>
            Of course — same place at 9? <Hi>coffee</Hi> ☕
            <div style={{
              display: 'inline-flex', alignItems: 'center', gap: 4,
              float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
              fontSize: 11, fontWeight: 500, color: 'rgba(255,255,255,0.78)',
            }}>20:16</div>
          </div>
        </div>

        <div style={{ display: 'flex', justifyContent: 'flex-start', padding: '4px 12px' }}>
          <div style={{
            maxWidth: '78%', background: 'var(--sn-surface)',
            color: 'var(--sn-text)',
            borderRadius: '18px 18px 18px 6px',
            padding: '8px 12px',
            boxShadow: '0 1px 1px rgba(15,23,32,0.05)',
            fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
          }}>
            Wait — new <Hi>coffee</Hi> spot on 18th. Try it?
            <div style={{
              display: 'inline-flex', alignItems: 'center', gap: 4,
              float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
              fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)',
            }}>20:17</div>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SnGlobalSearch, SnSearchInChat });
