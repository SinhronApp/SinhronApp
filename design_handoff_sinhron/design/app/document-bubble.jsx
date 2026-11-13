// document-bubble.jsx — Chat populated with file / document attachments
// Spec §6.9: media-key + sha256 + mime + size + filename. The chat surface
// renders a richer bubble for documents: typed icon (PDF/ZIP/XLSX/etc.),
// filename, size, optional sub-line (page count, sender), tap-to-download
// affordance, and inline download progress for one bubble.
//
// Exports: SnChatDocuments

// ─── Mime → icon + tint ─────────────────────────────────────────────
function DocGlyph({ kind, size = 36 }) {
  // colored shorts; tinted background for the wrapper
  const variants = {
    pdf:  { bg: 'rgba(255,77,77,0.14)',  fg: '#D03A3A', label: 'PDF' },
    zip:  { bg: 'rgba(245,158,11,0.16)', fg: '#B45309', label: 'ZIP' },
    xlsx: { bg: 'rgba(16,185,129,0.14)', fg: '#0E8C5F', label: 'XLSX' },
    docx: { bg: 'rgba(45,111,247,0.14)', fg: '#2D6FF7', label: 'DOCX' },
    png:  { bg: 'rgba(124,58,237,0.14)', fg: '#7C3AED', label: 'PNG' },
    text: { bg: 'var(--sn-bg-soft)',      fg: 'var(--sn-text-2)', label: 'TXT' },
  };
  const v = variants[kind] || variants.text;
  return (
    <div style={{
      width: size, height: size, borderRadius: 9,
      background: v.bg, color: v.fg, flexShrink: 0,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      position: 'relative',
    }}>
      <svg width={size * 0.5} height={size * 0.5} viewBox="0 0 24 24" fill="none" style={{ position: 'absolute', top: 4, left: '50%', transform: 'translateX(-50%)' }}>
        <path d="M14 3H6.5A1.5 1.5 0 005 4.5v15A1.5 1.5 0 006.5 21h11A1.5 1.5 0 0019 19.5V8l-5-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        <path d="M14 3v5h5" stroke="currentColor" strokeWidth="1.8"/>
      </svg>
      <div style={{
        position: 'absolute', bottom: 4, left: 0, right: 0, textAlign: 'center',
        fontSize: size * 0.18, fontWeight: 700, letterSpacing: 0.2, color: v.fg,
        fontFamily: "'Geist Mono', monospace",
      }}>{v.label}</div>
    </div>
  );
}

// ─── A trailing action — download / open / progress ────────────────
function DocTrailing({ state = 'cloud', pct = 0, isOut }) {
  if (state === 'progress') {
    const r = 14, c = 2 * Math.PI * r;
    return (
      <div style={{
        width: 34, height: 34, borderRadius: 17,
        background: isOut ? 'rgba(255,255,255,0.18)' : 'var(--sn-accent-soft)',
        color: isOut ? '#fff' : 'var(--sn-accent)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        position: 'relative', flexShrink: 0,
      }}>
        <svg width="34" height="34" viewBox="-17 -17 34 34" style={{ position: 'absolute' }}>
          <circle r={r} cx="0" cy="0" fill="none" stroke={isOut ? 'rgba(255,255,255,0.25)' : 'var(--sn-text-4)'} strokeWidth="2"/>
          <circle r={r} cx="0" cy="0" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"
            strokeDasharray={c} strokeDashoffset={c * (1 - pct)} transform="rotate(-90)"/>
        </svg>
        <svg width="9" height="9" viewBox="0 0 24 24" fill="none">
          <rect x="6" y="6" width="12" height="12" rx="1" fill="currentColor"/>
        </svg>
      </div>
    );
  }
  if (state === 'open') {
    return (
      <div style={{
        width: 34, height: 34, borderRadius: 17,
        background: isOut ? 'rgba(255,255,255,0.18)' : 'var(--sn-accent-soft)',
        color: isOut ? '#fff' : 'var(--sn-accent)',
        display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
      }}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
          <path d="M5 12h14M13 6l6 6-6 6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </div>
    );
  }
  // cloud / download
  return (
    <div style={{
      width: 34, height: 34, borderRadius: 17,
      background: isOut ? 'rgba(255,255,255,0.18)' : 'var(--sn-accent-soft)',
      color: isOut ? '#fff' : 'var(--sn-accent)',
      display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
    }}>
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
        <path d="M12 4v12M6 10l6 6 6-6M4 20h16" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
    </div>
  );
}

// ─── Document bubble — extends bubble pattern from chat-view ────────
function DocBubble({ side = 'in', tail = true, time, read, kind, name, size, sub, state = 'cloud', pct, caption }) {
  const isOut = side === 'out';
  const align = isOut ? 'flex-end' : 'flex-start';
  const bg = isOut ? 'var(--sn-accent)' : 'var(--sn-surface)';
  const fg = isOut ? '#FFFFFF' : 'var(--sn-text)';
  const metaFg = isOut ? 'rgba(255,255,255,0.78)' : 'var(--sn-text-3)';
  const subFg = isOut ? 'rgba(255,255,255,0.78)' : 'var(--sn-text-3)';
  const r = 18, rTail = 6;
  const radius = isOut
    ? `${r}px ${r}px ${tail ? rTail : r}px ${r}px`
    : `${r}px ${r}px ${r}px ${tail ? rTail : r}px`;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: align, padding: '1.5px 12px', marginTop: tail ? 6 : 1 }}>
      <div style={{
        maxWidth: '82%', minWidth: 240,
        background: bg, color: fg, borderRadius: radius,
        padding: '10px 12px 8px',
        boxShadow: isOut ? '0 1px 1px rgba(45,111,247,0.18)' : '0 1px 1px rgba(15,23,32,0.05)',
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
          <DocGlyph kind={kind}/>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{
              fontSize: 14, fontWeight: 600, letterSpacing: -0.1,
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}>{name}</div>
            <div style={{ fontSize: 11.5, fontWeight: 500, color: subFg, marginTop: 2, letterSpacing: -0.05 }}>
              {state === 'progress'
                ? <>{Math.round(pct * 100)}% · {size}</>
                : <>{size}{sub ? ' · ' + sub : ''}</>}
            </div>
          </div>
          <DocTrailing state={state} pct={pct} isOut={isOut}/>
        </div>

        {caption && (
          <div style={{
            paddingTop: 8, marginTop: 8,
            borderTop: isOut ? '0.5px solid rgba(255,255,255,0.18)' : '0.5px solid var(--sn-divider)',
            fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
          }}>{caption}</div>
        )}

        <div style={{
          display: 'inline-flex', alignItems: 'center', gap: 4,
          float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2,
          fontSize: 11, fontWeight: 500, color: metaFg, letterSpacing: -0.05,
        }}>
          {time}
          {isOut && (
            <svg width="14" height="10" viewBox="0 0 22 14" fill="none">
              <path d="M1 7l4.5 4.5L13 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              {read && <path d="M9 7l4.5 4.5L21 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>}
            </svg>
          )}
        </div>
      </div>
    </div>
  );
}

// ─── Header (reusing the conversational chat chrome) ────────────────
function DocHeader({ name = 'Maria Chen' }) {
  return (
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
      <SnAvatar name={name} size={36} online/>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: -0.2, color: 'var(--sn-text)' }}>{name}</div>
        <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-success)' }}>online</div>
      </div>
      <div style={{ width: 36, height: 36, color: 'var(--sn-text)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
        </svg>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// SnChatDocuments
// ════════════════════════════════════════════════════════════════════
function SnChatDocuments({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DocHeader name="Maria Chen"/>

      <div className="sn-scroll" style={{ flex: 1, display: 'flex', flexDirection: 'column', padding: '8px 0' }}>
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <div style={{
            padding: '4px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)',
            fontSize: 11, fontWeight: 600, color: 'var(--sn-text-3)',
            letterSpacing: 0.2, textTransform: 'uppercase',
          }}>Today</div>
        </div>

        {/* Incoming PDF — already cached, can open */}
        <DocBubble side="in" time="09:14"
          kind="pdf" name="Sinhron — design proposal v3.pdf"
          size="4.2 MB" sub="42 pages"
          state="open"/>

        <div style={{ display: 'flex', justifyContent: 'flex-start', padding: '4px 12px' }}>
          <div style={{
            maxWidth: '78%', background: 'var(--sn-surface)', color: 'var(--sn-text)',
            borderRadius: '18px 18px 18px 6px', padding: '8px 12px 7px',
            boxShadow: '0 1px 1px rgba(15,23,32,0.05)',
            fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
          }}>
            had time to read it on the train — section 4 needs another pass
            <div style={{ display: 'inline-flex', float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2, fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)' }}>09:15</div>
          </div>
        </div>

        {/* Outgoing XLSX with caption */}
        <DocBubble side="out" time="09:42" read
          kind="xlsx" name="Q2-targets.xlsx"
          size="184 KB" sub="3 sheets"
          state="open"
          caption="updated numbers — last row was off by a factor of 10 🙃"/>

        {/* Incoming ZIP — needs download (cloud icon) */}
        <DocBubble side="in" time="10:08"
          kind="zip" name="design-tokens-export.zip"
          size="12.6 MB"
          state="cloud"/>

        {/* Incoming PNG mockup — in-progress download */}
        <DocBubble side="in" time="10:09"
          kind="png" name="lockscreen-mockup-v2.png"
          size="2.8 MB"
          state="progress" pct={0.34}/>

        {/* Outgoing DOCX with size already known */}
        <DocBubble side="out" time="10:14" read
          kind="docx" name="release-notes-1.0.docx"
          size="62 KB"
          state="open"/>
      </div>

      {/* Composer with active attachment chip — shows the user is staging a doc */}
      <div style={{
        background: 'var(--sn-bg)',
        borderTop: '0.5px solid var(--sn-divider)',
      }}>
        {/* Attachment chip above the composer */}
        <div style={{ padding: '8px 12px 0' }}>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 10,
            padding: '8px 8px 8px 10px',
            background: 'var(--sn-accent-soft)',
            borderRadius: 12,
          }}>
            <DocGlyph kind="pdf" size={30}/>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{
                fontSize: 13, fontWeight: 600, color: 'var(--sn-text)', letterSpacing: -0.1,
                whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
              }}>cabin-deploy-runbook.pdf</div>
              <div style={{ fontSize: 11, color: 'var(--sn-text-3)', marginTop: 1 }}>1.4 MB · ready to send</div>
            </div>
            <div style={{
              width: 26, height: 26, borderRadius: 13,
              background: 'rgba(15,23,32,0.06)', color: 'var(--sn-text-2)',
              display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
            }}>
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
                <path d="M5 5l14 14M19 5L5 19" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"/>
              </svg>
            </div>
          </div>
        </div>

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
            background: 'var(--sn-bg-soft)', padding: '8px 14px',
            display: 'flex', alignItems: 'center',
            fontSize: 15, color: 'var(--sn-text)', letterSpacing: -0.15,
          }}>have a look when you get a sec</div>
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
    </div>
  );
}

Object.assign(window, { SnChatDocuments });
