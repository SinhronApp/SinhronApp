// schedule-send.jsx — Scheduled messages
//   1. Schedule picker — half-sheet over the chat. Presets + custom date/time.
//   2. Chat with one scheduled bubble + a "Scheduled (3)" banner above composer.
//   3. Scheduled drawer — full list of pending messages, edit/cancel/send-now.
//
// Exports: SnSchedulePicker, SnChatScheduled, SnScheduledDrawer

// ─── Static reference time so screens stay deterministic ────────────
const NOW = { d: 'Mon', date: 14, h: 13, m: 24 };

// ════════════════════════════════════════════════════════════════════
// 1. Schedule picker — half-sheet over a chat (typed message visible)
// ════════════════════════════════════════════════════════════════════
function SnSchedulePicker({ dark = false, platform = 'ios' }) {
  const presets = [
    { primary: 'Tonight',         secondary: '18:00',  hint: 'in 4h 36m' },
    { primary: 'Tomorrow',        secondary: '09:00',  hint: 'Tue, Apr 15' },
    { primary: 'Monday morning',  secondary: 'Apr 21 · 09:00' },
  ];

  return (
    <div style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden' }}>
      {/* Behind: chat with a pending composer message */}
      <SnChatSchedulingBase dark={dark} platform={platform} composerText="Here's the deck — let me know if you want any swaps before tomorrow."/>

      <div style={{
        position: 'absolute', inset: 0,
        background: dark ? 'rgba(0,0,0,0.50)' : 'rgba(15,23,32,0.38)',
      }}/>

      {/* Sheet */}
      <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
        position: 'absolute', left: 0, right: 0, bottom: 0,
        background: 'var(--sn-bg)',
        borderTopLeftRadius: 22, borderTopRightRadius: 22,
        boxShadow: '0 -10px 40px rgba(0,0,0,0.30)',
        padding: '14px 0 20px',
        display: 'flex', flexDirection: 'column', maxHeight: '78%',
      }}>
        {/* Grabber */}
        <div style={{ display: 'flex', justifyContent: 'center', paddingBottom: 6 }}>
          <div style={{ width: 38, height: 5, borderRadius: 3, background: 'var(--sn-text-4)' }}/>
        </div>

        {/* Title */}
        <div style={{ padding: '6px 22px 14px', display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{
            width: 32, height: 32, borderRadius: 9,
            background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <circle cx="12" cy="13" r="8" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M12 9v4l3 2M8 3l-2 3M16 3l2 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          </div>
          <div>
            <div style={{ fontSize: 18, fontWeight: 600, letterSpacing: -0.3, color: 'var(--sn-text)' }}>Send later</div>
            <div style={{ fontSize: 12.5, fontWeight: 500, color: 'var(--sn-text-3)' }}>Mon · Apr 14 · 13:24 now</div>
          </div>
        </div>

        {/* Preset rows */}
        <div style={{
          margin: '0 14px 14px',
          background: 'var(--sn-surface)',
          borderRadius: 'var(--sn-radius-card)',
          boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
          overflow: 'hidden',
        }}>
          {presets.map((p, i) => (
            <div key={i} style={{
              display: 'flex', alignItems: 'center', gap: 12,
              padding: '14px 18px', minHeight: 56,
              borderTop: i === 0 ? 'none' : '0.5px solid var(--sn-divider)',
              background: i === 0 ? 'var(--sn-accent-soft)' : 'transparent',
            }}>
              <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
                <div style={{
                  fontSize: 15, fontWeight: 600, letterSpacing: -0.15,
                  color: i === 0 ? 'var(--sn-accent)' : 'var(--sn-text)',
                }}>{p.primary}</div>
                <div style={{ fontSize: 12.5, fontWeight: 500, color: 'var(--sn-text-3)' }}>
                  {p.secondary}{p.hint && <span style={{ marginLeft: 8 }}>· {p.hint}</span>}
                </div>
              </div>
              {i === 0 && (
                <div style={{
                  width: 22, height: 22, borderRadius: 11,
                  background: 'var(--sn-accent)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                }}>
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
                    <path d="M5 12l5 5L20 7" stroke="#fff" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                </div>
              )}
            </div>
          ))}
        </div>

        {/* Custom picker — date pills + time wheel snippet */}
        <div style={{
          margin: '0 14px 16px',
          background: 'var(--sn-surface)',
          borderRadius: 'var(--sn-radius-card)',
          boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
          padding: '14px 16px',
        }}>
          <div style={{
            fontSize: 11, fontWeight: 700, letterSpacing: 0.6,
            color: 'var(--sn-text-3)', textTransform: 'uppercase',
            marginBottom: 10,
          }}>Pick a time</div>

          {/* Day chips */}
          <div style={{ display: 'flex', gap: 6, overflowX: 'hidden', marginBottom: 14 }}>
            {[
              { d: 'Mon', n: 14, t: 'Today' },
              { d: 'Tue', n: 15, t: 'Tomorrow' },
              { d: 'Wed', n: 16 },
              { d: 'Thu', n: 17 },
              { d: 'Fri', n: 18 },
              { d: 'Sat', n: 19 },
            ].map((c, i) => {
              const isActive = i === 1;
              return (
                <div key={i} style={{
                  flex: '0 0 auto', minWidth: 50, padding: '8px 10px',
                  borderRadius: 12, textAlign: 'center',
                  background: isActive ? 'var(--sn-accent)' : 'var(--sn-bg-soft)',
                  color: isActive ? '#fff' : 'var(--sn-text)',
                }}>
                  <div style={{
                    fontSize: 10, fontWeight: 600,
                    color: isActive ? 'rgba(255,255,255,0.85)' : 'var(--sn-text-3)',
                    textTransform: 'uppercase', letterSpacing: 0.4,
                  }}>{c.d}</div>
                  <div style={{ fontSize: 17, fontWeight: 600, letterSpacing: -0.3 }}>{c.n}</div>
                </div>
              );
            })}
          </div>

          {/* Time wheel — three columns, centered selection emphasised */}
          <div className="sn-mono" style={{
            position: 'relative', height: 96, display: 'flex',
            background: 'var(--sn-bg-soft)', borderRadius: 12,
            alignItems: 'center', justifyContent: 'center', gap: 14,
            overflow: 'hidden',
          }}>
            {/* center band */}
            <div style={{
              position: 'absolute', left: 12, right: 12, top: 32, height: 32,
              borderRadius: 8, background: 'var(--sn-accent-soft)',
            }}/>
            {/* H */}
            <Wheel values={['07','08','09']} center="09"/>
            <div style={{ fontSize: 24, fontWeight: 600, color: 'var(--sn-text-3)', zIndex: 1 }}>:</div>
            <Wheel values={['00','15','30']} center="00"/>
          </div>
        </div>

        {/* Footer CTAs */}
        <div style={{ padding: '0 16px', display: 'flex', gap: 10 }}>
          <DsButton variant="ghost">Cancel</DsButton>
          <DsButton variant="primary" leading={
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <circle cx="12" cy="13" r="8" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M12 9v4l3 2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          }>Schedule for 18:00</DsButton>
        </div>
      </div>
    </div>
  );
}

// Tiny vertical wheel — 3 visible values, middle is selected
function Wheel({ values, center }) {
  return (
    <div style={{ position: 'relative', width: 60, height: 96, zIndex: 1 }}>
      {values.map((v, i) => (
        <div key={v} style={{
          position: 'absolute', left: 0, right: 0, top: i * 32, height: 32,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontSize: v === center ? 22 : 17,
          fontWeight: v === center ? 600 : 500,
          letterSpacing: -0.3,
          color: v === center ? 'var(--sn-accent)' : 'var(--sn-text-3)',
          fontVariantNumeric: 'tabular-nums',
        }}>{v}</div>
      ))}
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// Base — chat with the user about to schedule (composer carries text)
// Used as the backdrop for the picker AND as the scheduled-chat screen.
// ════════════════════════════════════════════════════════════════════
function SnChatSchedulingBase({ dark = false, platform = 'ios', composerText, scheduled }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* header — reuse the same chrome as the 1:1 chat */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        padding: '8px 14px 10px',
        borderBottom: '0.5px solid var(--sn-divider)',
      }}>
        <div style={{
          width: 32, height: 32, color: 'var(--sn-text)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', marginLeft: -6,
        }}>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
            <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
        <SnAvatar name="Maria Chen" size={36} online/>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: -0.2, color: 'var(--sn-text)' }}>Maria Chen</div>
          <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-success)' }}>online</div>
        </div>
        <div style={{ width: 36, height: 36, color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
            <rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
          </svg>
        </div>
        <div style={{ width: 36, height: 36, color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
          </svg>
        </div>
      </div>

      <div className="sn-scroll" style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
        <div style={{ display: 'flex', justifyContent: 'center', padding: '12px 0 6px' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Today</div>
        </div>

        {/* Earlier bubble for context */}
        <div style={{ display: 'flex', justifyContent: 'flex-start', padding: '4px 12px' }}>
          <div style={{
            maxWidth: '78%', background: 'var(--sn-surface)', color: 'var(--sn-text)',
            borderRadius: '18px 18px 18px 6px', padding: '8px 12px 7px',
            fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
            boxShadow: '0 1px 1px rgba(15,23,32,0.05)',
          }}>
            Can you send me the deck for tomorrow's call?
            <div style={{ display: 'inline-flex', float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2, fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)' }}>13:18</div>
          </div>
        </div>

        {/* Scheduled bubble — only when scheduled */}
        {scheduled && (
          <div style={{ display: 'flex', justifyContent: 'flex-end', padding: '6px 12px' }}>
            <div style={{
              maxWidth: '78%',
              background: 'var(--sn-accent)', color: '#fff',
              borderRadius: '18px 18px 6px 18px',
              padding: '8px 12px 7px',
              fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
              boxShadow: '0 1px 1px rgba(45,111,247,0.18)',
              position: 'relative',
              opacity: 0.92,
              // dashed outline distinguishes pending from sent
              outline: '1.5px dashed rgba(255,255,255,0.55)',
              outlineOffset: -3,
            }}>
              Here's the deck — let me know if you want any swaps before tomorrow.
              <div style={{
                display: 'inline-flex', alignItems: 'center', gap: 4,
                float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
                fontSize: 11, fontWeight: 600,
                color: 'rgba(255,255,255,0.92)', letterSpacing: -0.05,
              }}>
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                  <circle cx="12" cy="13" r="8" stroke="currentColor" strokeWidth="2"/>
                  <path d="M12 9v4l3 2" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
                </svg>
                Scheduled · 18:00
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Optional banner above composer */}
      {scheduled && (
        <div style={{
          margin: '0 10px 6px',
          background: 'var(--sn-accent-soft)',
          borderRadius: 12,
          padding: '8px 12px',
          display: 'flex', alignItems: 'center', gap: 10,
        }}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-accent)' }}>
            <circle cx="12" cy="13" r="8" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M12 9v4l3 2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
          <div style={{ flex: 1, fontSize: 13, fontWeight: 600, color: 'var(--sn-accent)', letterSpacing: -0.05 }}>
            1 message scheduled for today
          </div>
          <div style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--sn-accent)' }}>View all</div>
        </div>
      )}

      {/* composer — either typed or fresh */}
      <div style={{
        display: 'flex', alignItems: 'flex-end', gap: 8,
        padding: '8px 10px 10px',
        borderTop: '0.5px solid var(--sn-divider)',
      }}>
        <div style={{
          width: 36, height: 36, borderRadius: '50%',
          background: 'var(--sn-bg-soft)', color: 'var(--sn-text-2)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
          </svg>
        </div>
        <div style={{
          flex: 1, minHeight: 36, borderRadius: 18,
          background: 'var(--sn-bg-soft)',
          padding: '8px 14px',
          display: 'flex', alignItems: 'center',
          fontSize: 15, color: composerText ? 'var(--sn-text)' : 'var(--sn-text-3)',
          letterSpacing: -0.15,
        }}>{composerText || 'Message'}</div>
        {/* Send — split button: tap sends, long-press schedules. Indicator visible. */}
        <div style={{
          display: 'flex', alignItems: 'stretch',
          borderRadius: 18, overflow: 'hidden',
          boxShadow: '0 2px 6px rgba(45,111,247,0.30)',
        }}>
          <div style={{
            width: 36, height: 36,
            background: 'var(--sn-accent)', color: '#fff',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <path d="M3 12l18-9-7 18-3-7-8-2z" fill="currentColor"/>
            </svg>
          </div>
          {composerText && (
            <div style={{
              width: 26, height: 36,
              background: 'var(--sn-accent)', color: 'rgba(255,255,255,0.85)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              boxShadow: 'inset 1px 0 0 rgba(255,255,255,0.20)',
            }}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                <circle cx="12" cy="13" r="7" stroke="currentColor" strokeWidth="2"/>
                <path d="M12 10v3l2 1.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
              </svg>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. Chat with the scheduled bubble + banner
// ════════════════════════════════════════════════════════════════════
function SnChatScheduled(props) {
  return <SnChatSchedulingBase {...props} scheduled/>;
}

// ════════════════════════════════════════════════════════════════════
// 4. Scheduled drawer — full list across all chats
// ════════════════════════════════════════════════════════════════════
function SnScheduledDrawer({ dark = false, platform = 'ios' }) {
  const items = [
    { to: 'Maria Chen', text: "Here's the deck — let me know if you want any swaps.", when: 'Today · 18:00', soon: true },
    { to: 'Engineering', group: true, text: 'Reminder: postmortem at 14:00, doc linked in the calendar invite.', when: 'Tomorrow · 13:55' },
    { to: 'Mom', text: 'Happy birthday ❤️ — call you in the evening.', when: 'Sun · 09:00' },
    { to: 'Nora Hayes', text: 'Following up on the contract draft — any blockers on your side?', when: 'Apr 18 · 10:30' },
  ];
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* header */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        padding: '8px 14px 10px',
        borderBottom: '0.5px solid var(--sn-divider)',
      }}>
        <div style={{ width: 32, height: 32, color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center', marginLeft: -6 }}>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
            <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
        <div style={{
          flex: 1, fontSize: 17, fontWeight: 600, letterSpacing: -0.3,
          color: 'var(--sn-text)',
        }}>Scheduled</div>
        <div style={{
          padding: '4px 10px', borderRadius: 999,
          background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
          fontSize: 12, fontWeight: 700, letterSpacing: -0.05,
        }}>{items.length}</div>
      </div>

      <div className="sn-scroll" style={{ flex: 1, padding: '14px 14px 24px' }}>
        <div style={{
          fontSize: 11, fontWeight: 700, letterSpacing: 0.6,
          color: 'var(--sn-text-3)', textTransform: 'uppercase',
          padding: '0 4px 8px',
        }}>Pending · {items.length}</div>

        <div style={{
          background: 'var(--sn-surface)',
          borderRadius: 'var(--sn-radius-card)',
          boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
          overflow: 'hidden',
        }}>
          {items.map((it, i) => (
            <div key={i} style={{
              padding: '14px 16px',
              borderTop: i === 0 ? 'none' : '0.5px solid var(--sn-divider)',
              display: 'flex', gap: 12, alignItems: 'flex-start',
            }}>
              <SnAvatar name={it.to} size={40} group={it.group}/>
              <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 4 }}>
                <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
                  <div style={{ flex: 1, fontSize: 14.5, fontWeight: 600, letterSpacing: -0.15, color: 'var(--sn-text)' }}>{it.to}</div>
                  <div style={{
                    display: 'inline-flex', alignItems: 'center', gap: 4,
                    fontSize: 12, fontWeight: 600,
                    color: it.soon ? 'var(--sn-accent)' : 'var(--sn-text-3)',
                    letterSpacing: -0.05,
                  }}>
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                      <circle cx="12" cy="13" r="8" stroke="currentColor" strokeWidth="1.8"/>
                      <path d="M12 9v4l3 2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
                    </svg>
                    {it.when}
                  </div>
                </div>
                <div style={{
                  fontSize: 13.5, lineHeight: '19px', color: 'var(--sn-text-2)',
                  letterSpacing: -0.05,
                  display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden',
                }}>{it.text}</div>
                <div style={{
                  display: 'flex', gap: 14, marginTop: 4,
                  fontSize: 12.5, fontWeight: 600, letterSpacing: -0.05,
                }}>
                  <span style={{ color: 'var(--sn-accent)' }}>Send now</span>
                  <span style={{ color: 'var(--sn-text-2)' }}>Edit</span>
                  <span style={{ color: 'var(--sn-text-3)' }}>Cancel</span>
                </div>
              </div>
            </div>
          ))}
        </div>

        <div style={{
          fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)',
          padding: '14px 4px 0', lineHeight: '17px', letterSpacing: -0.05,
        }}>
          Scheduled messages live on your device. If you're offline at the send time, Sinhron will deliver as soon as you reconnect.
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SnSchedulePicker, SnChatScheduled, SnScheduledDrawer });
