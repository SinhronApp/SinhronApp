// composer-pack.jsx — Reply, @mention, sticker panel, drafts in chat-list
// Exports: SnChatReply, SnChatMention, SnChatStickers, SnChatListDrafts

// ────────────────────────────────────────────────────────────────────
// Shared composer pieces — kept thin so each screen can vary the slot
// ────────────────────────────────────────────────────────────────────
function ComposerShell({ topSlot, inputContent, dark }) {
  return (
    <div style={{
      background: 'var(--sn-bg)',
      borderTop: '0.5px solid var(--sn-divider)',
    }}>
      {topSlot}
      <div style={{
        display: 'flex', alignItems: 'flex-end', gap: 8,
        padding: '8px 10px 10px',
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
          display: 'flex', alignItems: 'center', padding: '8px 12px 8px 14px',
          gap: 8,
        }}>
          {inputContent}
        </div>
        <div style={{
          width: 36, height: 36, borderRadius: '50%',
          background: 'var(--sn-accent)', color: '#fff',
          display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
          boxShadow: '0 2px 6px rgba(45,111,247,0.30)',
        }}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
            <path d="M3 12l18-9-7 18-3-7-8-2z" fill="currentColor"/>
          </svg>
        </div>
      </div>
    </div>
  );
}

function ChatShell({ dark, header, children, composer }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {header}
      <div className="sn-scroll" style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: '8px 0' }}>
        {children}
      </div>
      {composer}
    </div>
  );
}

// Reusable chat header (same chrome as 1:1)
function ChatHeaderMini({ name = 'Maria Chen', subtitle = 'online', subtitleColor }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '8px 14px 10px',
      borderBottom: '0.5px solid var(--sn-divider)',
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
      <SnAvatar name={name} size={36} online={subtitle === 'online'} group={subtitle.includes('member')}/>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: -0.2, color: 'var(--sn-text)' }}>{name}</div>
        <div style={{ fontSize: 12, fontWeight: 500, color: subtitleColor || 'var(--sn-text-3)' }}>{subtitle}</div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. Chat with reply-in-composer
// ════════════════════════════════════════════════════════════════════
function SnChatReply({ dark = false, platform = 'ios' }) {
  return (
    <ChatShell
      dark={dark}
      header={<ChatHeaderMini name="Maria Chen" subtitle="online" subtitleColor="var(--sn-success)"/>}
      composer={
        <ComposerShell
          dark={dark}
          topSlot={
            <div style={{
              display: 'flex', alignItems: 'center', gap: 10,
              padding: '8px 12px 6px',
              borderBottom: '0.5px solid var(--sn-divider)',
            }}>
              <div style={{
                width: 3, height: 32, borderRadius: 2, background: 'var(--sn-accent)', flexShrink: 0,
              }}/>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{
                  fontSize: 12, fontWeight: 600, color: 'var(--sn-accent)',
                  letterSpacing: -0.05,
                }}>Replying to Maria Chen</div>
                <div style={{
                  fontSize: 13, fontWeight: 400, color: 'var(--sn-text-2)',
                  whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                  marginTop: 1,
                }}>Their pour-over is unreal.</div>
              </div>
              <button style={{
                width: 22, height: 22, borderRadius: 11, border: 'none',
                background: 'var(--sn-bg-soft)', color: 'var(--sn-text-3)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                cursor: 'pointer', padding: 0, flexShrink: 0,
              }}>
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                  <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round"/>
                </svg>
              </button>
            </div>
          }
          inputContent={
            <>
              <div style={{
                flex: 1, fontSize: 15, fontWeight: 500,
                color: 'var(--sn-text)', letterSpacing: -0.1,
              }}>
                Sold. See you at 9
                <span style={{ width: 1.5, height: 16, background: 'var(--sn-accent)', display: 'inline-block', marginLeft: 2, animation: 'sn-blink 1s steps(2) infinite' }}/>
              </div>
            </>
          }
        />
      }
    >
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
          maxWidth: '78%', background: 'var(--sn-surface)', color: 'var(--sn-text)',
          borderRadius: '18px 18px 18px 6px', padding: '8px 12px 7px',
          boxShadow: '0 1px 1px rgba(15,23,32,0.05)',
          fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
        }}>
          Actually, let's try here instead. Their pour-over is unreal.
          <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4, float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2, fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)' }}>20:18</div>
        </div>
      </div>
    </ChatShell>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Group chat with @mention typeahead
// ════════════════════════════════════════════════════════════════════
function SnChatMention({ dark = false, platform = 'ios' }) {
  const matches = [
    { name: 'Tasha Lim', handle: '@tasha', online: true },
    { name: 'Tom Becker', handle: '@tom_b' },
    { name: 'Tarik Hussain', handle: '@tarik', online: true },
  ];
  return (
    <ChatShell
      dark={dark}
      header={<ChatHeaderMini name="Engineering" subtitle="12 members · 4 online"/>}
      composer={
        <ComposerShell
          dark={dark}
          topSlot={
            <div style={{
              borderBottom: '0.5px solid var(--sn-divider)',
              maxHeight: 200, overflow: 'hidden',
            }}>
              {matches.map((m, i) => {
                const active = i === 0;
                return (
                  <div key={m.handle} style={{
                    display: 'flex', alignItems: 'center', gap: 12,
                    padding: '8px 14px',
                    background: active ? 'var(--sn-accent-soft)' : 'transparent',
                  }}>
                    <SnAvatar name={m.name} size={32} online={m.online}/>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{
                        fontSize: 14, fontWeight: 600, letterSpacing: -0.1,
                        color: active ? 'var(--sn-accent)' : 'var(--sn-text)',
                      }}>{m.name}</div>
                      <div className="sn-mono" style={{
                        fontSize: 12, fontWeight: 500,
                        color: 'var(--sn-text-3)',
                      }}>{m.handle}</div>
                    </div>
                  </div>
                );
              })}
            </div>
          }
          inputContent={
            <div style={{
              flex: 1, fontSize: 15, fontWeight: 500,
              color: 'var(--sn-text)', letterSpacing: -0.1,
              display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 2,
            }}>
              <span style={{
                color: 'var(--sn-accent)', fontWeight: 600,
                background: 'var(--sn-accent-soft)',
                padding: '0 4px', borderRadius: 4,
              }}>@t</span>
              <span style={{ width: 1.5, height: 16, background: 'var(--sn-accent)', display: 'inline-block', marginLeft: 1, animation: 'sn-blink 1s steps(2) infinite' }}/>
            </div>
          }
        />
      }
    >
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
          <SnAvatar name="Alex Park" size={30}/>
        </div>
        <div style={{
          maxWidth: '76%', background: 'var(--sn-surface)', color: 'var(--sn-text)',
          borderRadius: '18px 18px 18px 6px', padding: '7px 12px 6px',
          boxShadow: '0 1px 1px rgba(15,23,32,0.05)',
          fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
        }}>
          <div style={{ fontSize: 12.5, fontWeight: 600, color: '#7C3AED', marginBottom: 2 }}>Alex Park</div>
          pushed the new SFrame implementation
          <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4, float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2, fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)' }}>12:08</div>
        </div>
      </div>
    </ChatShell>
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. Sticker / emoji panel
// ════════════════════════════════════════════════════════════════════
function SnChatStickers({ dark = false, platform = 'ios' }) {
  // 7×5 emoji grid sample
  const EMOJI = [
    '😀','😂','🥰','😘','🤩','😎','🤔',
    '😢','😭','😡','🤯','😴','🤤','🥱',
    '❤️','🧡','💛','💚','💙','💜','🖤',
    '🔥','✨','💯','🙌','👏','🫶','🤝',
    '☕','🍵','🍷','🍺','🥐','🍰','🍕',
  ];
  return (
    <ChatShell
      dark={dark}
      header={<ChatHeaderMini name="Maria Chen" subtitle="online" subtitleColor="var(--sn-success)"/>}
      composer={
        <ComposerShell
          dark={dark}
          topSlot={
            <div style={{
              padding: '0',
              borderBottom: '0.5px solid var(--sn-divider)',
              background: 'var(--sn-bg)',
            }}>
              {/* Category tabs */}
              <div style={{
                display: 'flex', alignItems: 'center', gap: 4,
                padding: '8px 8px 6px',
                overflowX: 'auto', scrollbarWidth: 'none',
              }}>
                {[
                  { id: 'recent', icon: (
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
                      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
                      <path d="M12 7v5l3.5 2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
                    </svg>
                  ), active: true },
                  { id: 'smileys', label: '😀' },
                  { id: 'animals', label: '🐶' },
                  { id: 'food', label: '🍔' },
                  { id: 'travel', label: '✈️' },
                  { id: 'objects', label: '💡' },
                  { id: 'symbols', label: '❤️' },
                  { id: 'stickers', icon: (
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
                      <path d="M14 3H6a2 2 0 00-2 2v14a2 2 0 002 2h10l5-5V5a2 2 0 00-2-2h-3z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
                      <path d="M21 14h-5a2 2 0 00-2 2v5" stroke="currentColor" strokeWidth="1.8"/>
                    </svg>
                  ) },
                ].map(t => (
                  <div key={t.id} style={{
                    width: 36, height: 36, borderRadius: 10,
                    background: t.active ? 'var(--sn-accent-soft)' : 'transparent',
                    color: t.active ? 'var(--sn-accent)' : 'var(--sn-text-2)',
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    fontSize: 20, flexShrink: 0,
                  }}>{t.icon || t.label}</div>
                ))}
              </div>

              {/* Recently used header */}
              <div style={{
                fontSize: 11, fontWeight: 700, letterSpacing: 0.6,
                color: 'var(--sn-text-3)', textTransform: 'uppercase',
                padding: '4px 16px 6px',
              }}>Recently used</div>

              {/* Emoji grid */}
              <div style={{
                display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)',
                gap: 2, padding: '0 10px 10px',
                maxHeight: 220, overflowY: 'auto', scrollbarWidth: 'none',
              }}>
                {EMOJI.map((e, i) => (
                  <div key={i} style={{
                    aspectRatio: '1', display: 'flex',
                    alignItems: 'center', justifyContent: 'center',
                    fontSize: 26, borderRadius: 8,
                  }}>{e}</div>
                ))}
              </div>
            </div>
          }
          inputContent={
            <div style={{
              flex: 1, fontSize: 15, fontWeight: 500,
              color: 'var(--sn-text-3)', letterSpacing: -0.1,
            }}>Message</div>
          }
        />
      }
    >
      <div style={{ flex: 1 }}/>
      <div style={{ display: 'flex', justifyContent: 'flex-end', padding: '4px 12px' }}>
        <div style={{
          maxWidth: '78%', background: 'var(--sn-accent)', color: '#fff',
          borderRadius: '18px 18px 6px 18px', padding: '8px 12px',
          fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
        }}>
          On my way ☕
          <div style={{ display: 'inline-flex', alignItems: 'center', gap: 4, float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2, fontSize: 11, fontWeight: 500, color: 'rgba(255,255,255,0.78)' }}>09:02</div>
        </div>
      </div>
    </ChatShell>
  );
}

// ════════════════════════════════════════════════════════════════════
// 4. Chat list with drafts — variant of the main list
// ════════════════════════════════════════════════════════════════════
const SN_DRAFT_CHATS = [
  { name: 'Maria Chen', preview: 'Sounds great — see you at 9 tomorrow ☕', time: '12:42', unread: 2, pinned: true, online: true },
  { name: 'Engineering', group: true, draft: 'should we ship after lunch or wait until tom', time: '12:34' },
  { name: 'Henry Park', preview: 'Voice message · 0:42', kind: 'voice', time: '11:31', unread: 1 },
  { name: 'Mom', preview: 'Got it ❤️', time: '10:14', sent: true, read: true },
  { name: 'Design crit', group: true, draft: '@tasha — could you take a look at', time: '09:55' },
  { name: 'Jordan Pierce', preview: 'typing…', typing: true, time: 'now', online: true },
  { name: 'Dad', preview: 'Missed call', kind: 'call', time: 'Yesterday' },
];

// Render a row with optional draft preview
function DraftRow({ chat, isLast }) {
  if (!chat.draft) {
    return <SnChatRow chat={chat} isLast={isLast}/>;
  }
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '10px 16px',
      position: 'relative',
    }}>
      <SnAvatar name={chat.name} size={50} group={chat.group}/>
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 3 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
          <div style={{ flex: 1, fontSize: 16, fontWeight: 600, color: 'var(--sn-text)', letterSpacing: -0.2 }}>{chat.name}</div>
          <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)' }}>{chat.time}</div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <span style={{
            color: '#E04A4A', fontWeight: 600, fontSize: 13,
            letterSpacing: -0.05,
          }}>Draft</span>
          <div style={{
            flex: 1, fontSize: 14, color: 'var(--sn-text-2)',
            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            letterSpacing: -0.05,
          }}>{chat.draft}</div>
        </div>
      </div>
    </div>
  );
}

function SnChatListDrafts({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      position: 'relative', overflow: 'hidden',
    }}>
      <SnHeader/>
      <SnFilters active="All" counts={{ Unread: 4 }}/>
      <div className="sn-scroll" style={{
        flex: 1,
        paddingBottom: platform === 'ios' ? 110 : 100,
      }}>
        {SN_DRAFT_CHATS.map((c, i) => (
          <DraftRow key={i} chat={c} isLast={i === SN_DRAFT_CHATS.length - 1}/>
        ))}
      </div>
      <SnTabBar platform={platform} dark={dark}/>
    </div>
  );
}

Object.assign(window, { SnChatReply, SnChatMention, SnChatStickers, SnChatListDrafts });
