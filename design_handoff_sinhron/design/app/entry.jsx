// entry.jsx — Sinhron onboarding & return flow
// E2EE invisible by design: no locks, no "encrypted", no email/phone/social.
// Spec: §3.4. Identity is BIP-39 phrase + linked devices.
// Exports: ALL screens (Welcome, ServerInvite, Profile, RecoveryPhrase,
// LinkDeviceShow, LinkDeviceScan, SettingUp, Restore, EmptyChats,
// BiometricPrompt, PinFallback) + primitives (DsButton, DsTextField).

// ════════════════════════════════════════════════════════════════════
// Primitives
// ════════════════════════════════════════════════════════════════════

// Wordmark + mark. "Two-arcs-in-sync" glyph in accent.
function SinhronMark({ size = 56 }) {
  const w = size, s = w * 0.42;
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <svg width={w} height={w} viewBox="0 0 56 56" fill="none">
        <circle cx="22" cy="28" r="14" stroke="var(--sn-accent)" strokeWidth="3" fill="none"/>
        <circle cx="34" cy="28" r="14" fill="var(--sn-accent)"/>
        <circle cx="34" cy="28" r="14" stroke="var(--sn-accent)" strokeWidth="3"/>
        <path d="M22 14a14 14 0 010 28" stroke="var(--sn-bg)" strokeWidth="3" fill="none" strokeLinecap="round"/>
      </svg>
    </div>
  );
}

function SinhronWordmark({ size = 36 }) {
  return (
    <div style={{
      fontSize: size, fontWeight: 600, letterSpacing: -1.0,
      color: 'var(--sn-text)',
      fontFamily: "'Geist', sans-serif",
    }}>Sinhron</div>
  );
}

// Pill button — 48pt tall, 14pt radius, primary/secondary/text variants
function DsButton({ children, variant = 'primary', onClick, leading, trailing, full = true }) {
  const palette = {
    primary: {
      bg: 'var(--sn-accent)', fg: '#fff',
      shadow: '0 1px 2px rgba(45,111,247,0.20), 0 6px 16px rgba(45,111,247,0.18)',
      border: 'none',
    },
    secondary: {
      bg: 'var(--sn-surface)', fg: 'var(--sn-text)',
      shadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider-strong)',
      border: 'none',
    },
    ghost: {
      bg: 'transparent', fg: 'var(--sn-accent)',
      shadow: 'none', border: 'none',
    },
  }[variant];
  return (
    <button onClick={onClick} style={{
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 8,
      width: full ? '100%' : 'auto',
      height: 50, padding: '0 18px',
      borderRadius: 14,
      background: palette.bg, color: palette.fg,
      border: palette.border, boxShadow: palette.shadow,
      fontFamily: "'Geist', sans-serif",
      fontSize: 16, fontWeight: 600, letterSpacing: -0.15,
      cursor: 'pointer',
    }}>
      {leading}
      {children}
      {trailing}
    </button>
  );
}

// Soft-surface text field — no Material outlined, no underline. Just a calm fill.
function DsTextField({ label, value, placeholder, prefix, suffix, mono, focused }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
      {label && (
        <div style={{
          fontSize: 12, fontWeight: 600, letterSpacing: 0.6, textTransform: 'uppercase',
          color: 'var(--sn-text-3)',
          paddingLeft: 4,
        }}>{label}</div>
      )}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 8,
        background: 'var(--sn-surface)',
        boxShadow: focused
          ? '0 0 0 2px var(--sn-accent-soft), 0 0 0 0.5px var(--sn-accent)'
          : '0 0 0 0.5px var(--sn-divider-strong)',
        borderRadius: 14, height: 50, padding: '0 16px',
      }}>
        {prefix && (
          <div style={{ color: 'var(--sn-text-3)', fontSize: 15, fontWeight: 500 }}>{prefix}</div>
        )}
        <div className={mono ? 'sn-mono' : ''} style={{
          flex: 1, minWidth: 0,
          fontSize: mono ? 14 : 16, fontWeight: 500, letterSpacing: -0.1,
          color: value ? 'var(--sn-text)' : 'var(--sn-text-3)',
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>{value || placeholder}</div>
        {focused && (
          <div style={{
            width: 1.5, height: 18, background: 'var(--sn-accent)',
            animation: 'sn-blink 1s steps(2) infinite',
          }}/>
        )}
        {suffix}
      </div>
    </div>
  );
}

// Soft checkbox row
function DsCheck({ checked, label }) {
  return (
    <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12, padding: '4px 4px' }}>
      <div style={{
        width: 22, height: 22, borderRadius: 7,
        background: checked ? 'var(--sn-accent)' : 'transparent',
        boxShadow: checked ? 'none' : '0 0 0 1.5px var(--sn-text-4) inset',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        flexShrink: 0, marginTop: 1,
      }}>
        {checked && (
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
            <path d="M5 12l5 5L20 7" stroke="#fff" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        )}
      </div>
      <div style={{
        flex: 1, fontSize: 14.5, fontWeight: 500, lineHeight: '20px',
        color: 'var(--sn-text-2)', letterSpacing: -0.1,
      }}>{label}</div>
    </div>
  );
}

// 24-word BIP-39 grid — 4×6. Numbered cells, monospace, blur-until-tap.
const SAMPLE_PHRASE = [
  'archer', 'maple', 'crisp', 'orbit', 'lentil', 'voyage',
  'fabric', 'quartz', 'mellow', 'thorn', 'cradle', 'rhythm',
  'silver', 'breeze', 'paddle', 'ember', 'glacier', 'plume',
  'echo', 'forest', 'beacon', 'tide', 'kindle', 'aurora',
];

function DsMnemonicGrid({ words = SAMPLE_PHRASE, revealed = true }) {
  return (
    <div style={{
      display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)',
      gap: 8, position: 'relative',
    }}>
      {words.map((w, i) => (
        <div key={i} style={{
          display: 'flex', alignItems: 'center', gap: 10,
          background: 'var(--sn-surface)',
          boxShadow: '0 0 0 0.5px var(--sn-divider-strong)',
          borderRadius: 10, padding: '10px 12px',
          filter: revealed ? 'none' : 'blur(6px)',
          transition: 'filter .25s',
        }}>
          <div className="sn-mono" style={{
            fontSize: 11, fontWeight: 600,
            color: 'var(--sn-text-4)', minWidth: 18,
            textAlign: 'right',
          }}>{String(i + 1).padStart(2, '0')}</div>
          <div className="sn-mono" style={{
            fontSize: 14, fontWeight: 500, letterSpacing: 0.1,
            color: 'var(--sn-text)',
          }}>{w}</div>
        </div>
      ))}
      {!revealed && (
        <div style={{
          position: 'absolute', inset: 0,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          pointerEvents: 'none',
        }}>
          <div style={{
            display: 'inline-flex', alignItems: 'center', gap: 8,
            padding: '8px 14px', borderRadius: 999,
            background: 'rgba(15,23,32,0.72)', color: '#fff',
            fontSize: 12.5, fontWeight: 600, letterSpacing: -0.1,
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
              <path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7-10-7-10-7z" stroke="currentColor" strokeWidth="2"/>
              <circle cx="12" cy="12" r="3" stroke="currentColor" strokeWidth="2"/>
            </svg>
            Tap to reveal
          </div>
        </div>
      )}
    </div>
  );
}

// 24-word input grid (for restore). Numbered slots, partially filled.
function DsMnemonicInput({ filled = 7 }) {
  const cells = Array.from({ length: 24 });
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
      {cells.map((_, i) => {
        const isFilled = i < filled;
        const isCurrent = i === filled;
        return (
          <div key={i} style={{
            display: 'flex', alignItems: 'center', gap: 10,
            background: isCurrent ? 'var(--sn-surface)' : 'var(--sn-bg-soft)',
            boxShadow: isCurrent
              ? '0 0 0 2px var(--sn-accent-soft), 0 0 0 0.5px var(--sn-accent)'
              : (isFilled ? '0 0 0 0.5px var(--sn-divider-strong)' : 'none'),
            borderRadius: 10, padding: '10px 12px',
          }}>
            <div className="sn-mono" style={{
              fontSize: 11, fontWeight: 600,
              color: 'var(--sn-text-4)', minWidth: 18,
              textAlign: 'right',
            }}>{String(i + 1).padStart(2, '0')}</div>
            <div className="sn-mono" style={{
              flex: 1,
              fontSize: 14, fontWeight: 500, letterSpacing: 0.1,
              color: isFilled ? 'var(--sn-text)' : 'transparent',
            }}>{isFilled ? SAMPLE_PHRASE[i] : 'word'}</div>
            {isCurrent && (
              <div style={{
                width: 1.5, height: 16, background: 'var(--sn-accent)',
                animation: 'sn-blink 1s steps(2) infinite',
              }}/>
            )}
          </div>
        );
      })}
    </div>
  );
}

// Screen header with optional back chevron + step counter
function DsHeader({ back = true, step }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center',
      padding: '6px 10px', minHeight: 44,
    }}>
      {back && (
        <button style={{
          width: 36, height: 36, borderRadius: 10, border: 'none',
          background: 'transparent', padding: 0, cursor: 'pointer',
          color: 'var(--sn-text)', display: 'flex',
          alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
            <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </button>
      )}
      <div style={{ flex: 1 }}/>
      {step && (
        <div className="sn-mono" style={{
          fontSize: 12, fontWeight: 600,
          color: 'var(--sn-text-3)', letterSpacing: 0.3,
          paddingRight: 14,
        }}>{step}</div>
      )}
    </div>
  );
}

function DsScreen({ dark, children, dim }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: dim ? 'rgba(11,16,22,0.6)' : 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>{children}</div>
  );
}

// blink keyframes (single insert)
if (typeof document !== 'undefined' && !document.getElementById('sn-entry-kf')) {
  const s = document.createElement('style');
  s.id = 'sn-entry-kf';
  s.textContent = '@keyframes sn-blink { 0% {opacity:1} 50% {opacity:0} }';
  document.head.appendChild(s);
}

// ════════════════════════════════════════════════════════════════════
// Screens
// ════════════════════════════════════════════════════════════════════

// 1. Welcome
function SnWelcome({ dark = false }) {
  return (
    <DsScreen dark={dark}>
      <div style={{ flex: 1 }}/>
      {/* Mark + wordmark */}
      <div style={{
        display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 22,
        padding: '0 32px',
      }}>
        <SinhronMark size={72}/>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10 }}>
          <SinhronWordmark size={40}/>
          <div style={{
            fontSize: 17, fontWeight: 500, letterSpacing: -0.2,
            color: 'var(--sn-text-2)', textAlign: 'center',
            maxWidth: 280, lineHeight: '24px',
          }}>Messages that stay between you.</div>
        </div>
      </div>
      <div style={{ flex: 1.4 }}/>
      {/* Actions */}
      <div style={{
        padding: '0 24px 18px',
        display: 'flex', flexDirection: 'column', gap: 12,
      }}>
        <DsButton variant="primary">Get started</DsButton>
        <DsButton variant="secondary">Link a device</DsButton>
        <div style={{
          textAlign: 'center', paddingTop: 12, paddingBottom: 12,
          fontSize: 14, fontWeight: 600, letterSpacing: -0.1,
          color: 'var(--sn-accent)',
        }}>Restore from phrase →</div>
      </div>
    </DsScreen>
  );
}

// 2. Server / invite (flow A, step 1)
function SnServerInvite({ dark = false }) {
  return (
    <DsScreen dark={dark}>
      <DsHeader back step="1 / 3"/>
      <div style={{ padding: '8px 24px 0' }}>
        <div style={{
          fontSize: 32, fontWeight: 600, letterSpacing: -0.9,
          color: 'var(--sn-text)', lineHeight: '38px',
        }}>Pick a server</div>
        <div style={{
          fontSize: 15, fontWeight: 500, lineHeight: '22px',
          color: 'var(--sn-text-2)', marginTop: 8,
          letterSpacing: -0.1,
        }}>Sinhron works with any server you trust — your team's, a friend's, or your own. The server never sees what you send.</div>
      </div>
      <div style={{ padding: '28px 24px 0', display: 'flex', flexDirection: 'column', gap: 18 }}>
        <DsTextField
          label="Server"
          value="cabin.sinhron.app"
          mono
          focused
        />
        <DsTextField
          label="Invite token"
          value="b8f2 · 41cd · 9a07 · 2e5b"
          mono
          suffix={
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-success)' }}>
              <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          }
        />
        <div style={{
          fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)',
          padding: '0 4px', lineHeight: '17px',
        }}>Filled in automatically from your invite link.</div>
      </div>
      <div style={{ flex: 1 }}/>
      <div style={{ padding: '0 24px 18px' }}>
        <DsButton variant="primary">Continue</DsButton>
      </div>
    </DsScreen>
  );
}

// 3. Profile (flow A, step 2)
function SnProfile({ dark = false }) {
  return (
    <DsScreen dark={dark}>
      <DsHeader back step="2 / 3"/>
      <div style={{ padding: '8px 24px 0' }}>
        <div style={{
          fontSize: 32, fontWeight: 600, letterSpacing: -0.9,
          color: 'var(--sn-text)', lineHeight: '38px',
        }}>Your profile</div>
        <div style={{
          fontSize: 15, fontWeight: 500, lineHeight: '22px',
          color: 'var(--sn-text-2)', marginTop: 8,
        }}>Name your contacts will see. You can change this any time.</div>
      </div>
      <div style={{
        padding: '28px 24px 0',
        display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 18,
      }}>
        {/* Avatar with edit affordance */}
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
              <path d="M16.5 3.5l4 4-12 12H4.5v-4l12-12z" stroke="currentColor" strokeWidth="2" strokeLinejoin="round"/>
            </svg>
          </div>
        </div>
      </div>
      <div style={{ padding: '24px 24px 0' }}>
        <DsTextField
          label="Name"
          value="Vera Kuznetsova"
          focused
        />
      </div>
      <div style={{ flex: 1 }}/>
      <div style={{ padding: '0 24px 18px' }}>
        <DsButton variant="primary">Continue</DsButton>
      </div>
    </DsScreen>
  );
}

// 4. Recovery phrase (flow A, step 3)
function SnRecoveryPhrase({ dark = false, revealed = true }) {
  return (
    <DsScreen dark={dark}>
      <DsHeader back step="3 / 3"/>
      <div style={{ padding: '8px 24px 0' }}>
        <div style={{
          fontSize: 28, fontWeight: 600, letterSpacing: -0.8,
          color: 'var(--sn-text)', lineHeight: '34px',
        }}>Save your recovery phrase</div>
        <div style={{
          fontSize: 14, fontWeight: 500, lineHeight: '20px',
          color: 'var(--sn-text-2)', marginTop: 6,
        }}>24 words. Write them down somewhere safe — this is the only way back if you lose every device.</div>
      </div>
      <div className="sn-scroll" style={{ flex: 1, padding: '18px 20px 0', minHeight: 0 }}>
        <DsMnemonicGrid revealed={revealed}/>
        <div style={{ height: 16 }}/>
        <DsCheck checked label="I've written my phrase down somewhere safe"/>
        <DsCheck checked={false} label="I understand this is the only way to recover my account"/>
        <div style={{ height: 16 }}/>
      </div>
      <div style={{ padding: '8px 24px 18px', display: 'flex', flexDirection: 'column', gap: 10 }}>
        <DsButton variant="primary">I've saved it</DsButton>
      </div>
    </DsScreen>
  );
}

// 5a. Link device — showing QR (on existing authorized device)
function SnLinkDeviceShow({ dark = false }) {
  return (
    <DsScreen dark={dark}>
      <DsHeader back/>
      <div style={{ padding: '8px 24px 0' }}>
        <div style={{
          fontSize: 28, fontWeight: 600, letterSpacing: -0.8,
          color: 'var(--sn-text)', lineHeight: '34px',
        }}>Link a new device</div>
        <div style={{
          fontSize: 14, fontWeight: 500, lineHeight: '20px',
          color: 'var(--sn-text-2)', marginTop: 6,
        }}>On the new device, open Sinhron and tap "Link a device", then scan this code.</div>
      </div>
      <div style={{
        flex: 1,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: '24px',
      }}>
        <div style={{
          width: 232, height: 232, padding: 18,
          background: 'var(--sn-surface)',
          borderRadius: 22,
          boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 12px 28px rgba(15,23,32,0.08), 0 0 0 0.5px var(--sn-divider-strong)',
          position: 'relative',
        }}>
          <QrPlaceholder/>
          {/* Centre mark */}
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
      <div style={{
        padding: '0 24px 18px', display: 'flex', flexDirection: 'column', gap: 10,
      }}>
        <div style={{ textAlign: 'center', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, color: 'var(--sn-text-3)', fontSize: 13, fontWeight: 500 }}>
          <span style={{ width: 6, height: 6, borderRadius: 3, background: 'var(--sn-success)' }}/>
          Code refreshes in 0:53
        </div>
      </div>
    </DsScreen>
  );
}

// QR pattern — abstract dot grid that reads as QR without being one
function QrPlaceholder() {
  const cells = 21;
  // deterministic pseudo-random fill
  const fill = (x, y) => {
    const h = (x * 31 + y * 17 + x * y) % 7;
    return h < 3;
  };
  return (
    <svg width="100%" height="100%" viewBox={`0 0 ${cells} ${cells}`} style={{ display: 'block' }}>
      <rect width={cells} height={cells} fill="transparent"/>
      {Array.from({ length: cells }).flatMap((_, y) =>
        Array.from({ length: cells }).map((_, x) => {
          // 3 finder squares at corners
          const inFinder = (
            (x < 7 && y < 7) ||
            (x >= cells - 7 && y < 7) ||
            (x < 7 && y >= cells - 7)
          );
          if (inFinder) return null;
          if (!fill(x, y)) return null;
          return <rect key={`${x}-${y}`} x={x} y={y} width="1" height="1" fill="var(--sn-text)" rx="0.2"/>;
        })
      )}
      {/* Finder squares */}
      {[[0,0],[cells-7,0],[0,cells-7]].map(([fx, fy], i) => (
        <g key={i}>
          <rect x={fx} y={fy} width="7" height="7" fill="var(--sn-text)" rx="1.2"/>
          <rect x={fx + 1} y={fy + 1} width="5" height="5" fill="var(--sn-surface)" rx="0.8"/>
          <rect x={fx + 2} y={fy + 2} width="3" height="3" fill="var(--sn-text)" rx="0.4"/>
        </g>
      ))}
    </svg>
  );
}

// 5b. Link device — scanning (on new device, camera viewfinder)
function SnLinkDeviceScan({ dark = false }) {
  return (
    <div className={`sn-app sn-theme-dark`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: '#000',
      position: 'relative', overflow: 'hidden',
      color: '#fff',
    }}>
      <DsHeader back/>
      {/* Camera viewfinder */}
      <div style={{
        flex: 1, position: 'relative',
        background: 'radial-gradient(80% 60% at 50% 40%, #1a2330 0%, #060a10 70%)',
        overflow: 'hidden',
      }}>
        {/* Faint scene mock */}
        <svg width="100%" height="100%" preserveAspectRatio="xMidYMid slice" viewBox="0 0 400 600" style={{ position: 'absolute', inset: 0, opacity: 0.55 }}>
          <rect x="0" y="0" width="400" height="600" fill="#0a141e"/>
          <rect x="60" y="120" width="280" height="380" rx="22" fill="#1f2e3f"/>
          <rect x="120" y="200" width="160" height="160" rx="6" fill="#fff" opacity="0.92"/>
          {/* QR finders */}
          {[[130,210],[260,210],[130,340]].map(([x,y],i) => (
            <g key={i}>
              <rect x={x} y={y} width="32" height="32" fill="#0e141b"/>
              <rect x={x+6} y={y+6} width="20" height="20" fill="#fff"/>
              <rect x={x+11} y={y+11} width="10" height="10" fill="#0e141b"/>
            </g>
          ))}
          {/* scattered modules */}
          {Array.from({length: 90}).map((_,i) => {
            const x = 175 + (i * 13) % 95;
            const y = 248 + Math.floor((i * 7) % 95);
            return <rect key={i} x={x} y={y} width="5" height="5" fill="#0e141b"/>;
          })}
        </svg>

        {/* Viewfinder bracket */}
        <div style={{
          position: 'absolute', top: '50%', left: '50%',
          transform: 'translate(-50%, -50%)',
          width: 220, height: 220,
        }}>
          {[['tl', '0', '0', 'auto', 'auto'], ['tr', '0', 'auto', '0', 'auto'], ['bl', 'auto', '0', 'auto', '0'], ['br', 'auto', 'auto', '0', '0']].map(([k, t, l, r, b], i) => (
            <div key={k} style={{
              position: 'absolute', top: t, left: l, right: r, bottom: b,
              width: 36, height: 36,
              borderTop: t === '0' ? '3px solid #fff' : 'none',
              borderBottom: b === '0' ? '3px solid #fff' : 'none',
              borderLeft: l === '0' ? '3px solid #fff' : 'none',
              borderRight: r === '0' ? '3px solid #fff' : 'none',
              borderTopLeftRadius: k === 'tl' ? 10 : 0,
              borderTopRightRadius: k === 'tr' ? 10 : 0,
              borderBottomLeftRadius: k === 'bl' ? 10 : 0,
              borderBottomRightRadius: k === 'br' ? 10 : 0,
            }}/>
          ))}
          {/* scan line */}
          <div style={{
            position: 'absolute', left: 8, right: 8, top: '50%', height: 2,
            background: 'var(--sn-accent)',
            boxShadow: '0 0 16px var(--sn-accent), 0 0 6px var(--sn-accent)',
            borderRadius: 2,
          }}/>
        </div>
      </div>
      <div style={{ padding: '0 24px 28px', textAlign: 'center' }}>
        <div style={{ fontSize: 15, fontWeight: 500, color: 'rgba(255,255,255,0.85)', letterSpacing: -0.1 }}>
          Point at the code shown on your other device
        </div>
      </div>
    </div>
  );
}

// 6. Setting up… (post-link, MLS welcome loading)
function SnSettingUp({ dark = false }) {
  const steps = [
    { label: 'Connecting to cabin.sinhron.app', state: 'done' },
    { label: 'Verifying device identity', state: 'done' },
    { label: 'Joining your groups', state: 'active' },
    { label: 'Syncing contacts', state: 'pending' },
  ];
  return (
    <DsScreen dark={dark}>
      <div style={{ flex: 1 }}/>
      <div style={{
        display: 'flex', flexDirection: 'column', alignItems: 'center',
        gap: 32, padding: '0 32px',
      }}>
        {/* Animated dual-arc mark — represented statically */}
        <div style={{ position: 'relative', width: 64, height: 64 }}>
          <SinhronMark size={64}/>
          <svg width="64" height="64" viewBox="0 0 64 64" style={{ position: 'absolute', inset: 0 }}>
            <circle cx="32" cy="32" r="30" stroke="var(--sn-accent)" strokeWidth="2.5"
              fill="none" strokeDasharray="40 200" strokeLinecap="round" opacity="0.5"/>
          </svg>
        </div>
        <div style={{
          fontSize: 24, fontWeight: 600, letterSpacing: -0.5,
          color: 'var(--sn-text)',
        }}>Setting up your device</div>
        <div style={{
          display: 'flex', flexDirection: 'column', gap: 12,
          alignSelf: 'stretch',
        }}>
          {steps.map((s, i) => (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              {s.state === 'done' && (
                <div style={{
                  width: 22, height: 22, borderRadius: 11,
                  background: 'var(--sn-success)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                }}>
                  <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
                    <path d="M5 12l5 5L20 7" stroke="#fff" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                </div>
              )}
              {s.state === 'active' && (
                <div style={{
                  width: 22, height: 22, borderRadius: 11,
                  boxShadow: 'inset 0 0 0 2.5px var(--sn-accent)',
                  position: 'relative',
                }}>
                  <div style={{
                    position: 'absolute', inset: 4, borderRadius: '50%',
                    background: 'var(--sn-accent)',
                  }}/>
                </div>
              )}
              {s.state === 'pending' && (
                <div style={{
                  width: 22, height: 22, borderRadius: 11,
                  boxShadow: 'inset 0 0 0 1.5px var(--sn-text-4)',
                }}/>
              )}
              <div style={{
                fontSize: 15, fontWeight: 500, letterSpacing: -0.1,
                color: s.state === 'pending' ? 'var(--sn-text-3)' : 'var(--sn-text)',
              }}>{s.label}</div>
            </div>
          ))}
        </div>
      </div>
      <div style={{ flex: 1.5 }}/>
    </DsScreen>
  );
}

// 7. Restore from phrase (flow C)
function SnRestore({ dark = false }) {
  return (
    <DsScreen dark={dark}>
      <DsHeader back/>
      <div style={{ padding: '8px 24px 0' }}>
        <div style={{
          fontSize: 28, fontWeight: 600, letterSpacing: -0.8,
          color: 'var(--sn-text)', lineHeight: '34px',
        }}>Enter your phrase</div>
        <div style={{
          fontSize: 14, fontWeight: 500, lineHeight: '20px',
          color: 'var(--sn-text-2)', marginTop: 6,
        }}>Type the 24 words you saved when you first signed up.</div>
      </div>
      <div className="sn-scroll" style={{ flex: 1, padding: '18px 20px 0', minHeight: 0 }}>
        <DsMnemonicInput filled={7}/>
        <div style={{ height: 12 }}/>
        {/* Suggestion strip — for the word currently being typed */}
        <div style={{
          display: 'flex', gap: 6, padding: '8px 0',
        }}>
          {['fab', 'fabric', 'fable'].map(w => (
            <div key={w} className="sn-mono" style={{
              padding: '6px 12px', borderRadius: 999,
              background: w === 'fabric' ? 'var(--sn-accent-soft)' : 'var(--sn-surface)',
              color: w === 'fabric' ? 'var(--sn-accent)' : 'var(--sn-text-2)',
              fontSize: 13, fontWeight: 600,
              boxShadow: w === 'fabric' ? 'none' : '0 0 0 0.5px var(--sn-divider-strong)',
            }}>{w}</div>
          ))}
        </div>
        <div style={{ height: 16 }}/>
        <DsCheck checked={false} label="I have a backup of message history (optional)"/>
        <div style={{ height: 16 }}/>
      </div>
      <div style={{ padding: '8px 24px 18px' }}>
        <DsButton variant="primary">Restore</DsButton>
      </div>
    </DsScreen>
  );
}

// 8. Empty chat list (post-restore) — uses SinhronChatList chrome but empty
function SnEmptyChats({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      position: 'relative', overflow: 'hidden',
    }}>
      <SnHeader/>
      <div style={{ flex: 1, padding: '24px 28px', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', textAlign: 'center', gap: 14 }}>
        <div style={{
          width: 64, height: 64, borderRadius: 18,
          background: 'var(--sn-bg-soft)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: 'var(--sn-text-3)',
        }}>
          <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
            <path d="M4 6.5C4 5.12 5.12 4 6.5 4h11A2.5 2.5 0 0120 6.5v8a2.5 2.5 0 01-2.5 2.5H10l-4 3.5V17H6.5A2.5 2.5 0 014 14.5v-8z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
          </svg>
        </div>
        <div style={{ fontSize: 20, fontWeight: 600, letterSpacing: -0.4, color: 'var(--sn-text)' }}>
          No conversations yet
        </div>
        <div style={{
          fontSize: 14.5, fontWeight: 500, lineHeight: '21px',
          color: 'var(--sn-text-2)', maxWidth: 280,
        }}>Your account is back. Ask your contacts to invite you into your groups — message history lives only on your devices.</div>
        <div style={{ height: 8 }}/>
        <DsButton variant="secondary" full={false}>Start a new chat</DsButton>
      </div>
      <SnTabBar platform={platform} dark={dark}/>
    </div>
  );
}

// 9. Biometric prompt (overlay over chat list)
function SnBiometricPrompt({ dark = false, platform = 'ios' }) {
  return (
    <div style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden' }}>
      {/* Background: chat list, blurred */}
      <div style={{
        position: 'absolute', inset: 0,
        filter: 'blur(8px) saturate(0.9)', transform: 'scale(1.04)',
      }}>
        <SinhronChatList dark={dark} platform={platform}/>
      </div>
      {/* Scrim */}
      <div style={{
        position: 'absolute', inset: 0,
        background: dark ? 'rgba(0,0,0,0.55)' : 'rgba(15,23,32,0.32)',
      }}/>
      {/* Card */}
      <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
        position: 'absolute', left: 20, right: 20, bottom: 40,
        background: 'var(--sn-elevated)',
        borderRadius: 22,
        padding: '24px 22px 18px',
        boxShadow: '0 24px 60px rgba(0,0,0,0.40), 0 2px 6px rgba(0,0,0,0.20)',
        display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14,
      }}>
        {/* Face ID glyph */}
        <div style={{
          width: 56, height: 56, borderRadius: 16,
          background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="30" height="30" viewBox="0 0 24 24" fill="none">
            <path d="M4 8V6a2 2 0 012-2h2M16 4h2a2 2 0 012 2v2M20 16v2a2 2 0 01-2 2h-2M8 20H6a2 2 0 01-2-2v-2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            <circle cx="9" cy="11" r="0.8" fill="currentColor"/>
            <circle cx="15" cy="11" r="0.8" fill="currentColor"/>
            <path d="M12 10v3M10 16c.5.5 1.2.8 2 .8s1.5-.3 2-.8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" fill="none"/>
          </svg>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4 }}>
          <div style={{ fontSize: 18, fontWeight: 600, letterSpacing: -0.3, color: 'var(--sn-text)' }}>Unlock Sinhron</div>
          <div style={{ fontSize: 14, fontWeight: 500, color: 'var(--sn-text-2)' }}>Look at the camera to continue</div>
        </div>
        <div style={{ height: 4 }}/>
        <DsButton variant="ghost">Use PIN instead</DsButton>
      </div>
    </div>
  );
}

// 10. PIN fallback
function SnPinFallback({ dark = false }) {
  const filled = 3;
  const keys = [['1','2','3'],['4','5','6'],['7','8','9'],['','0','⌫']];
  return (
    <DsScreen dark={dark}>
      <DsHeader back/>
      <div style={{ padding: '8px 24px 0', textAlign: 'center' }}>
        <div style={{ fontSize: 24, fontWeight: 600, letterSpacing: -0.5, color: 'var(--sn-text)' }}>Enter your PIN</div>
        <div style={{ fontSize: 14, fontWeight: 500, color: 'var(--sn-text-2)', marginTop: 4 }}>6 digits</div>
      </div>
      {/* dots */}
      <div style={{
        display: 'flex', justifyContent: 'center', gap: 16,
        padding: '36px 0 24px',
      }}>
        {Array.from({ length: 6 }).map((_, i) => (
          <div key={i} style={{
            width: 14, height: 14, borderRadius: 7,
            background: i < filled ? 'var(--sn-text)' : 'transparent',
            boxShadow: i < filled ? 'none' : 'inset 0 0 0 1.5px var(--sn-text-4)',
          }}/>
        ))}
      </div>
      <div style={{ flex: 1 }}/>
      {/* keypad */}
      <div style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(3, 1fr)', gap: 10,
        padding: '0 24px 24px',
      }}>
        {keys.flat().map((k, i) => (
          <div key={i} style={{
            height: 56, borderRadius: 16,
            background: k ? 'var(--sn-surface)' : 'transparent',
            boxShadow: k && k !== '⌫' ? '0 0 0 0.5px var(--sn-divider-strong), 0 1px 2px rgba(15,23,32,0.04)' : 'none',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontSize: 22, fontWeight: 500, letterSpacing: -0.3,
            color: k === '⌫' ? 'var(--sn-text-2)' : 'var(--sn-text)',
            fontFamily: "'Geist', sans-serif",
          }}>{k}</div>
        ))}
      </div>
    </DsScreen>
  );
}

Object.assign(window, {
  SnWelcome, SnServerInvite, SnProfile, SnRecoveryPhrase,
  SnLinkDeviceShow, SnLinkDeviceScan, SnSettingUp,
  SnRestore, SnEmptyChats, SnBiometricPrompt, SnPinFallback,
  SinhronMark, SinhronWordmark, DsButton, DsTextField,
});
