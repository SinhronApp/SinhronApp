// no-internet.jsx — Cold-start offline / hard-disconnected full-screen
// This is NOT the slim "Reconnecting…" toast in states.jsx. This is what
// the user sees when the app cold-starts with no network at all, or when
// the WS layer gives up after enough failed retries that we owe the user
// a real explanation. Renders the chat list behind so they still see
// their chats (locally), but with the list dimmed and an authoritative
// banner up top.
//
// Two variants:
//   1. SnNoInternet         — total offline (no Wi-Fi, no cellular)
//   2. SnServerUnreachable  — phone has internet but cabin.sinhron.app is down
//
// Exports: SnNoInternet, SnServerUnreachable

// ─── A "no internet" inline-card that pretends to be a sheet ──────
function OfflineHero({ title, copy, icon, accent }) {
  return (
    <div style={{
      position: 'absolute', left: 14, right: 14, top: 70,
      background: 'var(--sn-surface)',
      borderRadius: 18,
      padding: '16px 16px 18px',
      boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 12px 32px rgba(15,23,32,0.10), 0 0 0 0.5px var(--sn-divider-strong)',
      display: 'flex', flexDirection: 'column', gap: 12,
      zIndex: 6,
    }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 12 }}>
        <div style={{
          width: 42, height: 42, borderRadius: 11,
          background: accent === 'red' ? 'rgba(255,77,77,0.14)' : 'rgba(217,119,6,0.14)',
          color: accent === 'red' ? '#FF4D4D' : '#C2410C',
          display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
        }}>{icon}</div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 15.5, fontWeight: 600, letterSpacing: -0.15, color: 'var(--sn-text)' }}>{title}</div>
          <div style={{
            fontSize: 13, fontWeight: 500, color: 'var(--sn-text-2)',
            lineHeight: '18px', letterSpacing: -0.05, marginTop: 3,
          }}>{copy}</div>
        </div>
      </div>

      <div style={{ display: 'flex', gap: 8 }}>
        <div style={{
          flex: 1, height: 38, borderRadius: 12,
          background: 'var(--sn-accent)', color: '#fff',
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
          fontSize: 13.5, fontWeight: 600, letterSpacing: -0.05,
          boxShadow: '0 1px 2px rgba(45,111,247,0.20), 0 4px 10px rgba(45,111,247,0.18)',
        }}>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
            <path d="M21 5v6h-6M3 19v-6h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
            <path d="M19 11a8 8 0 00-14-3M5 13a8 8 0 0014 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
          Try again
        </div>
        <div style={{
          height: 38, padding: '0 14px', borderRadius: 12,
          color: 'var(--sn-text-2)', fontSize: 13.5, fontWeight: 600,
          display: 'flex', alignItems: 'center', justifyContent: 'center', letterSpacing: -0.05,
          background: 'var(--sn-bg-soft)',
        }}>Details</div>
      </div>
    </div>
  );
}

// ─── Bottom diagnostic card — "what we know" ────────────────────────
function OfflineDiag({ rows }) {
  return (
    <div style={{
      position: 'absolute', left: 14, right: 14, bottom: 110,
      background: 'var(--sn-surface)',
      borderRadius: 14,
      padding: '4px 0',
      boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
      zIndex: 6,
    }}>
      {rows.map((r, i) => (
        <div key={r.label} style={{
          display: 'flex', alignItems: 'center', gap: 10,
          padding: '10px 14px', minHeight: 38,
          borderTop: i === 0 ? 'none' : '0.5px solid var(--sn-divider)',
        }}>
          <div style={{
            width: 8, height: 8, borderRadius: 4,
            background: r.tone === 'ok' ? 'var(--sn-success)' : (r.tone === 'warn' ? '#F59E0B' : '#FF4D4D'),
            flexShrink: 0,
          }}/>
          <div style={{ flex: 1, fontSize: 12.5, fontWeight: 500, color: 'var(--sn-text-2)', letterSpacing: -0.05 }}>{r.label}</div>
          <div className="sn-mono" style={{ fontSize: 11.5, fontWeight: 500, color: r.tone === 'ok' ? 'var(--sn-success)' : 'var(--sn-text-3)' }}>{r.value}</div>
        </div>
      ))}
    </div>
  );
}

// ─── Shared shell — dimmed chat list + hero card + diag card ────────
function OfflineShell({ dark, platform, hero, diag }) {
  return (
    <div style={{ width: '100%', height: '100%', position: 'relative', overflow: 'hidden' }}>
      {/* Behind: chat list, dimmed */}
      <div style={{ position: 'absolute', inset: 0, filter: 'saturate(0.6) opacity(0.55)' }}>
        <SinhronChatList dark={dark} platform={platform}/>
      </div>
      {/* Subtle scrim so the foreground reads first */}
      <div style={{
        position: 'absolute', inset: 0,
        background: dark
          ? 'linear-gradient(180deg, rgba(11,16,22,0.55) 0%, rgba(11,16,22,0.15) 35%, rgba(11,16,22,0.55) 100%)'
          : 'linear-gradient(180deg, rgba(255,255,255,0.45) 0%, rgba(255,255,255,0.05) 35%, rgba(255,255,255,0.45) 100%)',
      }}/>
      {hero}
      {diag}
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. No internet — phone-level
// ════════════════════════════════════════════════════════════════════
function SnNoInternet({ dark = false, platform = 'ios' }) {
  return (
    <OfflineShell dark={dark} platform={platform}
      hero={
        <OfflineHero accent="red"
          title="You're offline"
          copy="Sinhron can't reach the network. Existing chats are still readable; new messages will send the moment you're back online."
          icon={
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path d="M2 8.5C5 6 8.4 4.5 12 4.5s7 1.5 10 4M5 12.5C7 11 9.4 10 12 10s5 1 7 2.5M8 16.5c1.2-1 2.5-1.5 4-1.5s2.8.5 4 1.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
              <circle cx="12" cy="20" r="1.3" fill="currentColor"/>
              <path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"/>
            </svg>
          }
        />
      }
      diag={
        <OfflineDiag rows={[
          { label: 'Wi-Fi',    value: 'off',          tone: 'bad' },
          { label: 'Cellular', value: 'no service',   tone: 'bad' },
          { label: 'Last sync', value: '12 min ago',  tone: 'warn' },
        ]}/>
      }
    />
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Server unreachable — phone is online, our server is down
// ════════════════════════════════════════════════════════════════════
function SnServerUnreachable({ dark = false, platform = 'ios' }) {
  return (
    <OfflineShell dark={dark} platform={platform}
      hero={
        <OfflineHero accent="warn"
          title="Server unreachable"
          copy={<span>You're online, but <span className="sn-mono" style={{ fontSize: 12, color: 'var(--sn-text)' }}>cabin.sinhron.app</span> isn't responding. The server admin may be running an update — we'll keep retrying in the background.</span>}
          icon={
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
              <rect x="3" y="4" width="18" height="6" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
              <rect x="3" y="14" width="18" height="6" rx="1.5" stroke="currentColor" strokeWidth="1.8"/>
              <circle cx="7" cy="7" r="1.1" fill="currentColor"/>
              <circle cx="7" cy="17" r="1.1" fill="currentColor"/>
              <path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"/>
            </svg>
          }
        />
      }
      diag={
        <OfflineDiag rows={[
          { label: 'Wi-Fi',          value: 'home-5G',     tone: 'ok' },
          { label: 'Server',         value: 'no response', tone: 'bad' },
          { label: 'Retry in',       value: '00:14',       tone: 'warn' },
          { label: 'Attempt',        value: '4 / ∞',       tone: 'warn' },
        ]}/>
      }
    />
  );
}

Object.assign(window, { SnNoInternet, SnServerUnreachable });
