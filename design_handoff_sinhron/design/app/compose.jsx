// compose.jsx — New chat (contact picker) + Add contact (username/QR)
// Uses tokens + DsButton, DsTextField, SnAvatar from earlier files.
// Exports: SnCompose, SnAddContact

// ─── Modal header (Cancel · title · spacer) ────────────────────────
function ModalHeader({ title, leading = 'Cancel', trailing }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center',
      padding: '10px 16px',
      minHeight: 48,
      borderBottom: '0.5px solid var(--sn-divider)',
      background: 'var(--sn-bg)',
    }}>
      <div style={{
        fontSize: 15, fontWeight: 500, color: 'var(--sn-text-2)',
        letterSpacing: -0.1,
        flexShrink: 0, minWidth: 60,
      }}>{leading}</div>
      <div style={{
        flex: 1, textAlign: 'center',
        fontSize: 17, fontWeight: 600, letterSpacing: -0.3,
        color: 'var(--sn-text)',
      }}>{title}</div>
      <div style={{ flexShrink: 0, minWidth: 60, textAlign: 'right' }}>
        {trailing}
      </div>
    </div>
  );
}

// ─── Inline search input ────────────────────────────────────────────
function SearchField({ placeholder = 'Search' }) {
  return (
    <div style={{ padding: '8px 14px' }}>
      <div style={{
        display: 'flex', alignItems: 'center', gap: 8,
        background: 'var(--sn-bg-soft)',
        borderRadius: 12, height: 38, padding: '0 12px',
      }}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-text-3)', flexShrink: 0 }}>
          <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/>
          <path d="M16.5 16.5L21 21" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
        </svg>
        <div style={{
          flex: 1, fontSize: 15, fontWeight: 500,
          color: 'var(--sn-text-3)', letterSpacing: -0.1,
        }}>{placeholder}</div>
      </div>
    </div>
  );
}

// ─── Section letter header for alphabetised list ────────────────────
function LetterHead({ letter }) {
  return (
    <div style={{
      fontSize: 12, fontWeight: 700, letterSpacing: 0.6,
      color: 'var(--sn-text-3)',
      padding: '14px 24px 6px',
      textTransform: 'uppercase',
    }}>{letter}</div>
  );
}

// ─── Contact row ────────────────────────────────────────────────────
function ContactRow({ name, status, isLast, trailing }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 12,
      padding: '8px 16px',
      position: 'relative',
    }}>
      <SnAvatar name={name} size={42}/>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{
          fontSize: 16, fontWeight: 500, letterSpacing: -0.2,
          color: 'var(--sn-text)',
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>{name}</div>
        {status && (
          <div style={{
            fontSize: 13, fontWeight: 500, color: 'var(--sn-text-3)',
            letterSpacing: -0.05,
            whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
          }}>{status}</div>
        )}
      </div>
      {trailing}
      {!isLast && (
        <div style={{
          position: 'absolute', left: 70, right: 16, bottom: 0,
          height: 0.5, background: 'var(--sn-divider)',
        }}/>
      )}
    </div>
  );
}

const SN_CONTACTS = [
  { name: 'Alex Park', status: 'last seen 2m ago' },
  { name: 'Amber Vasquez', status: 'on Sinhron' },
  { name: 'Bilal Reyes', status: 'last seen yesterday' },
  { name: 'Coffee crew', status: '4 members', group: true },
  { name: 'Dad', status: 'online' },
  { name: 'Daria Lim', status: 'last seen Mon' },
  { name: 'Engineering', status: '12 members', group: true },
  { name: 'Henry Park', status: 'online' },
  { name: 'Jordan Pierce', status: 'last seen 1h ago' },
  { name: 'Kira Sato', status: 'on Sinhron' },
  { name: 'Maria Chen', status: 'online' },
];

// Group rows by first letter
function groupByLetter(contacts) {
  const groups = {};
  contacts.forEach(c => {
    const letter = c.name[0].toUpperCase();
    (groups[letter] = groups[letter] || []).push(c);
  });
  return Object.entries(groups).sort(([a], [b]) => a.localeCompare(b));
}

// ════════════════════════════════════════════════════════════════════
// 1. Compose · contact picker
// ════════════════════════════════════════════════════════════════════
function SnCompose({ dark = false, platform = 'ios' }) {
  const recents = SN_CONTACTS.slice(0, 7);
  const grouped = groupByLetter(SN_CONTACTS);
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <ModalHeader title="New chat"/>
      <SearchField placeholder="Name or @username"/>

      {/* Quick actions */}
      <div style={{ padding: '4px 0' }}>
        <ContactRow
          name="New group"
          status="Create a private group"
          trailing={null}
        />
        {/* override the avatar slot for these "ghost" actions by composing manually */}
      </div>

      <div className="sn-scroll" style={{ flex: 1, paddingBottom: 16 }}>
        {/* Ghost action: Add contact */}
        <div style={{
          display: 'flex', alignItems: 'center', gap: 12,
          padding: '10px 16px', cursor: 'pointer',
        }}>
          <div style={{
            width: 42, height: 42, borderRadius: '50%',
            background: 'var(--sn-accent-soft)',
            color: 'var(--sn-accent)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            flexShrink: 0,
          }}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
              <circle cx="11" cy="9" r="4" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M3 21c0-4 3.2-7 7-7s7 3 7 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              <path d="M19 6v6M16 9h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          </div>
          <div style={{ fontSize: 16, fontWeight: 500, color: 'var(--sn-accent)' }}>Add new contact</div>
        </div>

        {/* Recents — horizontal scroll */}
        <div style={{
          fontSize: 12, fontWeight: 700, letterSpacing: 0.6,
          color: 'var(--sn-text-3)',
          padding: '14px 24px 8px',
          textTransform: 'uppercase',
        }}>Recent</div>
        <div style={{
          display: 'flex', gap: 12, padding: '0 16px 8px',
          overflowX: 'auto', scrollbarWidth: 'none',
        }}>
          {recents.map(c => (
            <div key={c.name} style={{
              flexShrink: 0,
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6,
              width: 64,
            }}>
              <SnAvatar name={c.name} size={56} group={c.group}/>
              <div style={{
                fontSize: 12, fontWeight: 500, color: 'var(--sn-text-2)',
                whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                width: '100%', textAlign: 'center',
                letterSpacing: -0.05,
              }}>{c.name.split(' ')[0]}</div>
            </div>
          ))}
        </div>

        {/* Alphabetised list */}
        {grouped.map(([letter, contacts]) => (
          <div key={letter}>
            <LetterHead letter={letter}/>
            {contacts.map((c, i) => (
              <ContactRow key={c.name} name={c.name} status={c.status}
                isLast={i === contacts.length - 1}/>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Add contact — tabbed (Username / QR)
// ════════════════════════════════════════════════════════════════════
function SnAddContact({ dark = false, platform = 'ios', mode = 'username' }) {
  const isQR = mode === 'qr';
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <ModalHeader title="Add contact"/>

      {/* Segmented control */}
      <div style={{ padding: '14px 14px 4px' }}>
        <div style={{
          display: 'flex', gap: 2, padding: 3,
          background: 'var(--sn-bg-soft)', borderRadius: 11,
        }}>
          {[
            { id: 'username', label: 'By username' },
            { id: 'qr', label: 'By QR' },
          ].map(t => {
            const active = t.id === mode;
            return (
              <div key={t.id} style={{
                flex: 1, padding: '7px 12px', borderRadius: 9,
                background: active ? 'var(--sn-surface)' : 'transparent',
                boxShadow: active ? '0 1px 2px rgba(15,23,32,0.06), 0 0 0 0.5px var(--sn-divider-strong)' : 'none',
                textAlign: 'center',
                fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1,
                color: active ? 'var(--sn-text)' : 'var(--sn-text-3)',
              }}>{t.label}</div>
            );
          })}
        </div>
      </div>

      {!isQR ? (
        // Username flow
        <div style={{ padding: '24px 20px 0', display: 'flex', flexDirection: 'column', gap: 14 }}>
          <DsTextField
            label="Username"
            prefix="@"
            value="maria_chen"
            mono
            focused
            suffix={
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-success)' }}>
                <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            }
          />
          <div style={{
            background: 'var(--sn-surface)',
            borderRadius: 14, padding: '12px 14px',
            boxShadow: '0 0 0 0.5px var(--sn-divider-strong)',
            display: 'flex', alignItems: 'center', gap: 12,
          }}>
            <SnAvatar name="Maria Chen" size={40}/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: -0.2, color: 'var(--sn-text)' }}>Maria Chen</div>
              <div className="sn-mono" style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)' }}>@maria_chen · cabin.sinhron.app</div>
            </div>
          </div>
          <div style={{ height: 8 }}/>
          <DsButton variant="primary">Add contact</DsButton>
        </div>
      ) : (
        // QR flow — show your own
        <div style={{ flex: 1, padding: '20px 20px 16px', display: 'flex', flexDirection: 'column' }}>
          <div style={{
            fontSize: 14, fontWeight: 500, color: 'var(--sn-text-2)',
            textAlign: 'center', padding: '0 20px 18px',
            lineHeight: '20px', letterSpacing: -0.1,
          }}>Show this code to a friend, or scan theirs.</div>
          <div style={{
            display: 'flex', justifyContent: 'center',
          }}>
            <div style={{
              width: 232, height: 232, padding: 18,
              background: 'var(--sn-surface)',
              borderRadius: 22,
              boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 12px 28px rgba(15,23,32,0.08), 0 0 0 0.5px var(--sn-divider-strong)',
              position: 'relative',
            }}>
              <QrPlaceholder/>
              <div style={{
                position: 'absolute', top: '50%', left: '50%',
                transform: 'translate(-50%, -50%)',
                width: 44, height: 44, borderRadius: 12,
                background: 'var(--sn-bg)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                boxShadow: '0 0 0 3px var(--sn-bg)',
              }}>
                <SinhronMark size={28}/>
              </div>
            </div>
          </div>
          {/* Identity card */}
          <div style={{
            margin: '20px 0 0',
            display: 'flex', alignItems: 'center', gap: 12,
            padding: '14px 18px',
            background: 'var(--sn-surface)',
            borderRadius: 14,
            boxShadow: '0 0 0 0.5px var(--sn-divider-strong)',
          }}>
            <SnAvatar name="Vera Kuznetsova" size={40}/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--sn-text)' }}>Vera Kuznetsova</div>
              <div className="sn-mono" style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)' }}>@vera_k</div>
            </div>
          </div>
          <div style={{ flex: 1 }}/>
          <DsButton variant="secondary" leading={
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <rect x="3" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
              <rect x="14" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
              <rect x="3" y="14" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M14 14h3v3h-3zM17 17h4v4h-4z" stroke="currentColor" strokeWidth="1.8"/>
            </svg>
          }>Scan a code</DsButton>
        </div>
      )}
    </div>
  );
}

Object.assign(window, { SnCompose, SnAddContact });
