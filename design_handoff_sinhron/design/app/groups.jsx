// groups.jsx — Group creation + group chat + group info
// Exports: SnNewGroupMembers, SnNewGroupName, SnGroupChat, SnGroupInfo

// Helper: pick a stable sender colour from the avatar palette
function snSenderColor(name, dark) {
  const [c1, c2] = SN_AVATAR_PALETTES[snHashIdx(name, SN_AVATAR_PALETTES.length)];
  return dark ? c1 : c2;
}

// ════════════════════════════════════════════════════════════════════
// 1. New group — pick members
// ════════════════════════════════════════════════════════════════════
function SnNewGroupMembers({ dark = false, platform = 'ios' }) {
  const selected = new Set(['Maria Chen', 'Henry Park', 'Daria Lim']);
  const grouped = groupByLetter(SN_CONTACTS.filter(c => !c.group));
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <ModalHeader
        title="New group"
        leading="Cancel"
        trailing={
          <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--sn-accent)' }}>Next</div>
        }
      />
      {/* Selected count strip */}
      <div style={{
        padding: '8px 20px',
        fontSize: 12, fontWeight: 600, letterSpacing: 0.4,
        textTransform: 'uppercase', color: 'var(--sn-text-3)',
      }}>{selected.size} of 256 selected</div>

      {/* Selected chips */}
      <div style={{
        display: 'flex', gap: 10, padding: '0 16px 12px',
        overflowX: 'auto', scrollbarWidth: 'none',
      }}>
        {[...selected].map(name => (
          <div key={name} style={{
            flexShrink: 0,
            display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6,
            width: 64, position: 'relative',
          }}>
            <div style={{ position: 'relative' }}>
              <SnAvatar name={name} size={52}/>
              <div style={{
                position: 'absolute', top: -4, right: -4,
                width: 22, height: 22, borderRadius: 11,
                background: 'var(--sn-text)', color: 'var(--sn-bg)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                boxShadow: '0 0 0 2.5px var(--sn-bg)',
              }}>
                <svg width="11" height="11" viewBox="0 0 24 24" fill="none">
                  <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="3" strokeLinecap="round"/>
                </svg>
              </div>
            </div>
            <div style={{
              fontSize: 12, fontWeight: 500, color: 'var(--sn-text)',
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
              width: '100%', textAlign: 'center',
            }}>{name.split(' ')[0]}</div>
          </div>
        ))}
      </div>

      <SearchField placeholder="Search contacts"/>

      <div className="sn-scroll" style={{ flex: 1, paddingBottom: 16 }}>
        {grouped.map(([letter, contacts]) => (
          <div key={letter}>
            <LetterHead letter={letter}/>
            {contacts.map((c, i) => {
              const isSel = selected.has(c.name);
              return (
                <ContactRow
                  key={c.name}
                  name={c.name}
                  status={c.status}
                  isLast={i === contacts.length - 1}
                  trailing={
                    <div style={{
                      width: 22, height: 22, borderRadius: 11,
                      background: isSel ? 'var(--sn-accent)' : 'transparent',
                      boxShadow: isSel ? 'none' : 'inset 0 0 0 1.5px var(--sn-text-4)',
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      flexShrink: 0,
                    }}>
                      {isSel && (
                        <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                          <path d="M5 12l5 5L20 7" stroke="#fff" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
                        </svg>
                      )}
                    </div>
                  }
                />
              );
            })}
          </div>
        ))}
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. New group — name + avatar
// ════════════════════════════════════════════════════════════════════
function SnNewGroupName({ dark = false, platform = 'ios' }) {
  const members = ['Maria Chen', 'Henry Park', 'Daria Lim'];
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <ModalHeader
        title="New group"
        leading="Back"
        trailing={
          <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--sn-accent)' }}>Create</div>
        }
      />

      <div className="sn-scroll" style={{ flex: 1 }}>
        {/* Avatar + name */}
        <div style={{
          display: 'flex', flexDirection: 'column', alignItems: 'center',
          padding: '24px 24px 18px', gap: 16,
        }}>
          <div style={{ position: 'relative' }}>
            <div style={{
              width: 96, height: 96, borderRadius: 28,
              background: 'var(--sn-bg-soft)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              color: 'var(--sn-text-3)',
            }}>
              <svg width="40" height="40" viewBox="0 0 24 24" fill="none">
                <rect x="3" y="5" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
                <circle cx="9" cy="11" r="2" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M3 17l5-4 4 3 3-2 6 5" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              </svg>
            </div>
            <div style={{
              position: 'absolute', bottom: -2, right: -2,
              width: 30, height: 30, borderRadius: 15,
              background: 'var(--sn-accent)',
              color: '#fff',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              boxShadow: '0 2px 6px rgba(45,111,247,0.30), 0 0 0 3px var(--sn-bg)',
            }}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                <path d="M16.5 3.5l4 4-12 12H4.5v-4l12-12z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
              </svg>
            </div>
          </div>
        </div>

        <div style={{ padding: '0 20px', display: 'flex', flexDirection: 'column', gap: 14 }}>
          <DsTextField label="Group name" value="Weekend trip" focused/>
          <DsTextField label="Description (optional)" value="" placeholder="What's this group about?"/>
        </div>

        {/* Members preview */}
        <div style={{ padding: '24px 0 8px' }}>
          <div style={{
            fontSize: 12, fontWeight: 600, letterSpacing: 0.6,
            textTransform: 'uppercase', color: 'var(--sn-text-3)',
            padding: '0 24px 10px',
          }}>{members.length} members</div>
          <div style={{
            background: 'var(--sn-surface)',
            margin: '0 14px',
            borderRadius: 'var(--sn-radius-card)',
            overflow: 'hidden',
            boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
          }}>
            {/* Add member row */}
            <div style={{
              display: 'flex', alignItems: 'center', gap: 12,
              padding: '12px 20px', position: 'relative',
            }}>
              <div style={{
                width: 36, height: 36, borderRadius: '50%',
                background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
              }}>
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                  <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
                </svg>
              </div>
              <div style={{ fontSize: 16, fontWeight: 500, color: 'var(--sn-accent)' }}>Add member</div>
              <div style={{ position: 'absolute', left: 70, right: 0, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
            </div>
            {members.map((name, i) => (
              <div key={name} style={{
                display: 'flex', alignItems: 'center', gap: 12,
                padding: '10px 20px', position: 'relative',
              }}>
                <SnAvatar name={name} size={36}/>
                <div style={{ flex: 1, fontSize: 16, fontWeight: 500, color: 'var(--sn-text)' }}>{name}</div>
                {i < members.length - 1 && (
                  <div style={{ position: 'absolute', left: 70, right: 0, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
                )}
              </div>
            ))}
          </div>
        </div>
        <div style={{ height: 20 }}/>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. Group chat view — bubbles with sender name + avatar
// ════════════════════════════════════════════════════════════════════
function SnGroupBubble({ side, sender, text, time, read, reactions, dark, tail = true, lastInGroup = true, firstInGroup = true }) {
  const isOut = side === 'out';
  const bg = isOut ? 'var(--sn-accent)' : 'var(--sn-surface)';
  const fg = isOut ? '#FFFFFF' : 'var(--sn-text)';
  const metaFg = isOut ? 'rgba(255,255,255,0.78)' : 'var(--sn-text-3)';
  const senderColor = sender ? snSenderColor(sender, dark) : null;

  return (
    <div style={{
      display: 'flex', gap: 8, alignItems: 'flex-end',
      padding: '0 10px',
      marginTop: firstInGroup ? 6 : 1,
      flexDirection: isOut ? 'row-reverse' : 'row',
    }}>
      {/* Sender avatar — only on incoming, only on lastInGroup */}
      {!isOut && (
        <div style={{ width: 30, flexShrink: 0 }}>
          {lastInGroup && sender ? <SnAvatar name={sender} size={30}/> : null}
        </div>
      )}
      <div style={{
        maxWidth: '76%',
        background: bg, color: fg,
        borderRadius: isOut
          ? `18px 18px ${tail ? 6 : 18}px 18px`
          : `18px 18px 18px ${tail ? 6 : 18}px`,
        padding: '7px 12px 6px',
        boxShadow: isOut
          ? '0 1px 1px rgba(45,111,247,0.18)'
          : '0 1px 1px rgba(15,23,32,0.05)',
        fontSize: 15, fontWeight: 400, letterSpacing: -0.15,
        lineHeight: '20px',
      }}>
        {!isOut && sender && firstInGroup && (
          <div style={{
            fontSize: 12.5, fontWeight: 600, letterSpacing: -0.1,
            color: senderColor, marginBottom: 2,
          }}>{sender}</div>
        )}
        <div>{text}</div>
        <div style={{
          display: 'inline-flex', alignItems: 'center', gap: 4,
          float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
          fontSize: 11, fontWeight: 500, letterSpacing: -0.05,
          color: metaFg, whiteSpace: 'nowrap',
        }}>
          <span>{time}</span>
          {isOut && (
            <svg width="14" height="10" viewBox="0 0 22 14" fill="none">
              <path d="M1 7l4.5 4.5L13 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
              {read && <path d="M9 7l4.5 4.5L21 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" fill="none"/>}
            </svg>
          )}
        </div>
      </div>
    </div>
  );
}

function SnGroupChat({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* Header — same chrome as 1:1 but subtitle shows member count */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        padding: '8px 14px 10px',
        background: 'var(--sn-bg)',
        borderBottom: '0.5px solid var(--sn-divider)',
        position: 'relative', zIndex: 4,
      }}>
        <button style={{
          width: 32, height: 32, borderRadius: 10, border: 'none',
          background: 'transparent', padding: 0, cursor: 'pointer',
          color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center',
          marginLeft: -6,
        }}>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
            <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </button>
        <SnAvatar name="Engineering" size={36} group/>
        <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 1 }}>
          <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: -0.2, color: 'var(--sn-text)' }}>Engineering</div>
          <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)' }}>12 members · 4 online</div>
        </div>
        <button style={{
          width: 36, height: 36, borderRadius: 10, border: 'none',
          background: 'transparent', padding: 0, cursor: 'pointer',
          color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M16.5 16.5L21 21" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
        </button>
      </div>

      <div className="sn-scroll" style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: '8px 0' }}>
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Today</div>
        </div>

        <SnGroupBubble side="in" sender="Alex Park" text="pushed the new SFrame implementation"
          time="12:08" dark={dark}/>
        <SnGroupBubble side="in" sender="Alex Park" text="ready for review when you have a sec"
          time="12:08" dark={dark} firstInGroup={false}/>

        <SnGroupBubble side="in" sender="Tasha Lim" text="oh nice, looking at it now"
          time="12:14" dark={dark}/>

        <SnGroupBubble side="out" text="Same — I'll pull it down after lunch ☕"
          time="12:31" read dark={dark}/>

        <SnGroupBubble side="in" sender="Henry Park" text="bench numbers look 22% better on Android"
          time="12:42" dark={dark}/>

        <SnGroupBubble side="out" text="🔥 huge"
          time="12:43" read dark={dark}/>
      </div>

      {/* Composer (reuse pattern) */}
      <div style={{
        display: 'flex', alignItems: 'flex-end', gap: 8,
        padding: '8px 10px 10px',
        background: 'var(--sn-bg)',
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
          display: 'flex', alignItems: 'center', padding: '0 14px',
          fontSize: 15, color: 'var(--sn-text-3)',
        }}>Message</div>
        <div style={{
          width: 36, height: 36, borderRadius: '50%',
          background: 'var(--sn-accent)', color: '#fff',
          display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
          boxShadow: '0 2px 6px rgba(45,111,247,0.30)',
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="2" fill="currentColor"/>
            <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
          </svg>
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 4. Group info — hero + members + admin + leave
// ════════════════════════════════════════════════════════════════════
function SnGroupInfo({ dark = false, platform = 'ios' }) {
  const members = [
    { name: 'Vera Kuznetsova', role: 'You', admin: true },
    { name: 'Alex Park', role: 'Admin', admin: true },
    { name: 'Tasha Lim', role: 'last seen 5m ago' },
    { name: 'Henry Park', role: 'online' },
    { name: 'Maria Chen', role: 'last seen 1h ago' },
    { name: 'Daria Lim', role: 'last seen yesterday' },
  ];
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* Top bar */}
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        padding: '6px 10px',
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
        <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--sn-accent)' }}>Edit</div>
      </div>

      <div className="sn-scroll" style={{ flex: 1 }}>
        {/* Hero */}
        <div style={{
          display: 'flex', flexDirection: 'column', alignItems: 'center',
          gap: 10, padding: '12px 24px 24px',
        }}>
          <SnAvatar name="Engineering" size={112} group/>
          <div style={{ fontSize: 26, fontWeight: 600, letterSpacing: -0.6, color: 'var(--sn-text)', marginTop: 6 }}>Engineering</div>
          <div style={{ fontSize: 14, fontWeight: 500, color: 'var(--sn-text-2)' }}>Group · 12 members</div>
        </div>

        {/* Actions */}
        <div style={{ padding: '0 14px 24px', display: 'flex', gap: 10 }}>
          {[
            { label: 'Mute', icon: (
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
                <path d="M12 4a5 5 0 015 5v4l2 3H5l2-3V9a5 5 0 015-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
                <path d="M10 20a2 2 0 004 0" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            ) },
            { label: 'Search', icon: (
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M16.5 16.5L21 21" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            ) },
            { label: 'Invite', icon: (
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
                <circle cx="11" cy="9" r="4" stroke="currentColor" strokeWidth="1.8"/>
                <path d="M3 21c0-4 3.2-7 7-7s7 3 7 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
                <path d="M19 6v6M16 9h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            ) },
          ].map(a => (
            <button key={a.label} style={{
              flex: 1, padding: '14px 6px 12px',
              background: 'var(--sn-surface)', border: 'none',
              borderRadius: 'var(--sn-radius-card)',
              boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8,
              cursor: 'pointer',
            }}>
              <div style={{
                width: 40, height: 40, borderRadius: 12,
                background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
              }}>{a.icon}</div>
              <div style={{ fontSize: 13, fontWeight: 600, color: 'var(--sn-text)', letterSpacing: -0.1 }}>{a.label}</div>
            </button>
          ))}
        </div>

        {/* Description */}
        <Section label="Description" first>
          <div style={{ padding: '0 20px 6px' }}>
            <div style={{
              fontSize: 16, lineHeight: '22px', color: 'var(--sn-text)',
              letterSpacing: -0.15,
            }}>Eng channel — keep design crit out, see #design-crit.</div>
          </div>
        </Section>

        {/* Group invite link (E2EE-aware: link is opaque token, not a URL with secret) */}
        <Section label="Invite">
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M10 14a4 4 0 005.66 0l3-3a4 4 0 10-5.66-5.66L11.5 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
                <path d="M14 10a4 4 0 00-5.66 0l-3 3a4 4 0 105.66 5.66l1.5-1.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              </svg>
            }
            label="Invite via link"
            subtitle="sinhron.app/g/eng-team-7f2a"
            trailing={<Chevron/>}
            isLast
          />
        </Section>

        {/* Members */}
        <div style={{ marginTop: 24 }}>
          <div style={{
            fontSize: 12, fontWeight: 600, letterSpacing: 0.6,
            textTransform: 'uppercase', color: 'var(--sn-text-3)',
            padding: '0 24px 10px',
          }}>{members.length + 6} members</div>
          <div style={{
            background: 'var(--sn-surface)',
            margin: '0 14px',
            borderRadius: 'var(--sn-radius-card)',
            overflow: 'hidden',
            boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
          }}>
            {/* Add member row */}
            <div style={{
              display: 'flex', alignItems: 'center', gap: 12,
              padding: '12px 20px', position: 'relative',
            }}>
              <div style={{
                width: 36, height: 36, borderRadius: '50%',
                background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
              }}>
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                  <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
                </svg>
              </div>
              <div style={{ flex: 1, fontSize: 16, fontWeight: 500, color: 'var(--sn-accent)' }}>Add member</div>
              <div style={{ position: 'absolute', left: 70, right: 0, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
            </div>
            {members.map((m, i) => (
              <div key={m.name} style={{
                display: 'flex', alignItems: 'center', gap: 12,
                padding: '10px 20px', position: 'relative',
              }}>
                <SnAvatar name={m.name} size={36}/>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{
                    fontSize: 16, fontWeight: 500, color: 'var(--sn-text)',
                    display: 'flex', alignItems: 'center', gap: 8,
                  }}>
                    {m.name}
                    {m.admin && (
                      <div style={{
                        fontSize: 10, fontWeight: 700, letterSpacing: 0.4,
                        padding: '2px 6px', borderRadius: 4,
                        background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
                        textTransform: 'uppercase',
                      }}>{m.role.toLowerCase().includes('you') ? 'YOU' : 'ADMIN'}</div>
                    )}
                  </div>
                  {!m.admin && (
                    <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--sn-text-3)' }}>{m.role}</div>
                  )}
                </div>
                {i < members.length - 1 && (
                  <div style={{ position: 'absolute', left: 70, right: 0, bottom: 0, height: 0.5, background: 'var(--sn-divider)' }}/>
                )}
              </div>
            ))}
          </div>
        </div>

        {/* Danger zone */}
        <Section label={null}>
          <Row
            icon={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path d="M15 17l5-5-5-5M20 12H8M12 3H6a2 2 0 00-2 2v14a2 2 0 002 2h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            }
            iconBg="rgba(224, 74, 74, 0.10)"
            accent="#E04A4A"
            label="Leave group"
            danger
            isLast
          />
        </Section>

        <div style={{ height: 24 }}/>
      </div>
    </div>
  );
}

Object.assign(window, { SnNewGroupMembers, SnNewGroupName, SnGroupChat, SnGroupInfo });
