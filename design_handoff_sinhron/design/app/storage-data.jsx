// storage-data.jsx — Settings → Storage & data
// Premium-messenger pattern. Two cards:
//   1. Storage usage breakdown by media type with a stacked bar
//   2. Auto-download rules per network (cellular / Wi-Fi / roaming)
// Plus: Clear cache (non-destructive — keeps chat list) and Clear chat
// history (destructive — wipes message store).
//
// Exports: SnStorageData

// ─── A single segment of the storage bar ────────────────────────────
function StorageSeg({ pct, color }) {
  return <div style={{ width: pct + '%', height: '100%', background: color }}/>;
}

// ─── A legend dot ───────────────────────────────────────────────────
function LegendDot({ color, label, value }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
      <div style={{ width: 10, height: 10, borderRadius: 5, background: color, flexShrink: 0 }}/>
      <div style={{ flex: 1, fontSize: 13.5, fontWeight: 500, color: 'var(--sn-text)', letterSpacing: -0.1 }}>{label}</div>
      <div className="sn-mono" style={{ fontSize: 12.5, fontWeight: 500, color: 'var(--sn-text-2)' }}>{value}</div>
    </div>
  );
}

// ─── Generic Settings card (matches existing settings style) ────────
function StgCard({ title, footnote, children }) {
  return (
    <div style={{ padding: '0 14px', marginBottom: 22 }}>
      {title && (
        <div style={{
          fontSize: 11, fontWeight: 700, letterSpacing: 0.6,
          color: 'var(--sn-text-3)', textTransform: 'uppercase',
          padding: '0 8px 8px',
        }}>{title}</div>
      )}
      <div style={{
        background: 'var(--sn-surface)',
        borderRadius: 'var(--sn-radius-card)',
        boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
        overflow: 'hidden',
      }}>{children}</div>
      {footnote && (
        <div style={{
          fontSize: 11.5, fontWeight: 500, lineHeight: '16px',
          color: 'var(--sn-text-3)', letterSpacing: -0.05,
          padding: '8px 8px 0',
        }}>{footnote}</div>
      )}
    </div>
  );
}

function StgRow({ icon, iconBg, label, value, danger, toggleOn, last }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 14,
      padding: '13px 18px', minHeight: 52,
      borderBottom: last ? 'none' : '0.5px solid var(--sn-divider)',
    }}>
      {icon && (
        <div style={{
          width: 28, height: 28, borderRadius: 8,
          background: iconBg || 'var(--sn-accent-soft)',
          color: danger ? '#FF4D4D' : 'var(--sn-accent)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          flexShrink: 0,
        }}>{icon}</div>
      )}
      <div style={{
        flex: 1, fontSize: 14.5, fontWeight: 500, letterSpacing: -0.1,
        color: danger ? '#FF4D4D' : 'var(--sn-text)',
      }}>{label}</div>
      {value != null && (
        <div style={{
          fontSize: 13.5, fontWeight: 500, color: 'var(--sn-text-2)',
          letterSpacing: -0.05,
        }}>{value}</div>
      )}
      {toggleOn != null && (
        <div style={{
          width: 44, height: 26, borderRadius: 13,
          background: toggleOn ? 'var(--sn-accent)' : 'var(--sn-text-4)',
          position: 'relative',
          transition: 'background .15s ease',
        }}>
          <div style={{
            position: 'absolute',
            top: 2, left: toggleOn ? 20 : 2,
            width: 22, height: 22, borderRadius: 11,
            background: '#fff',
            boxShadow: '0 1px 2px rgba(0,0,0,0.20), 0 2px 4px rgba(0,0,0,0.10)',
            transition: 'left .15s ease',
          }}/>
        </div>
      )}
    </div>
  );
}

// ─── Auto-download toggle row — three columns of media types ────────
function AutoDownloadRow({ label, photos, voice, videos, docs }) {
  return (
    <div style={{
      padding: '14px 18px', minHeight: 60,
      borderBottom: '0.5px solid var(--sn-divider)',
    }}>
      <div style={{ fontSize: 14.5, fontWeight: 500, letterSpacing: -0.1, color: 'var(--sn-text)', marginBottom: 8 }}>{label}</div>
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
        {[['Photos', photos], ['Voice', voice], ['Videos', videos], ['Files', docs]].map(([k, on]) => (
          <div key={k} style={{
            padding: '5px 10px 5px 8px', borderRadius: 999,
            background: on ? 'var(--sn-accent-soft)' : 'var(--sn-bg-soft)',
            color: on ? 'var(--sn-accent)' : 'var(--sn-text-3)',
            display: 'inline-flex', alignItems: 'center', gap: 5,
            fontSize: 12, fontWeight: 600, letterSpacing: -0.05,
          }}>
            {on ? (
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none">
                <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            ) : (
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none">
                <path d="M5 5l14 14M19 5L5 19" stroke="currentColor" strokeWidth="3" strokeLinecap="round"/>
              </svg>
            )}
            {k}
          </div>
        ))}
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// SnStorageData
// ════════════════════════════════════════════════════════════════════
function SnStorageData({ dark = false, platform = 'ios' }) {
  // Total = 1.62 GB / 2.0 GB budget
  const segs = [
    { label: 'Photos',  value: '710 MB',  pct: 35, color: '#FF6E54' },
    { label: 'Videos',  value: '480 MB',  pct: 24, color: '#7C3AED' },
    { label: 'Voice',   value: '210 MB',  pct: 10, color: '#10B981' },
    { label: 'Files',   value: '180 MB',  pct:  9, color: '#F59E0B' },
    { label: 'Messages',value: ' 40 MB',  pct:  2, color: '#3B82F6' },
  ];
  const free = 100 - segs.reduce((n, s) => n + s.pct, 0);

  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* Header */}
      <div style={{
        display: 'flex', alignItems: 'center',
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
          color: 'var(--sn-text)', textAlign: 'center',
        }}>Storage & data</div>
        <div style={{ width: 32 }}/>
      </div>

      <div className="sn-scroll" style={{ flex: 1, paddingTop: 22, paddingBottom: 30 }}>
        {/* Hero — stacked bar + numbers */}
        <div style={{ padding: '0 14px 22px' }}>
          <div style={{
            background: 'var(--sn-surface)',
            borderRadius: 22,
            padding: '18px 18px 16px',
            boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
          }}>
            <div style={{
              display: 'flex', alignItems: 'baseline', justifyContent: 'space-between',
              marginBottom: 10,
            }}>
              <div>
                <div style={{ fontSize: 26, fontWeight: 600, letterSpacing: -0.5, color: 'var(--sn-text)' }}>
                  1.62 <span style={{ fontSize: 17, color: 'var(--sn-text-3)' }}>GB</span>
                </div>
                <div style={{ fontSize: 12.5, fontWeight: 500, color: 'var(--sn-text-3)', letterSpacing: -0.05, marginTop: 2 }}>
                  of 2 GB cache budget
                </div>
              </div>
              <div style={{
                padding: '4px 10px', borderRadius: 999,
                background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
                fontSize: 12, fontWeight: 700, letterSpacing: -0.05,
              }}>81%</div>
            </div>

            {/* Stacked bar */}
            <div style={{
              display: 'flex', height: 12, borderRadius: 6,
              overflow: 'hidden', background: 'var(--sn-bg-soft)',
              marginBottom: 16,
            }}>
              {segs.map(s => <StorageSeg key={s.label} pct={s.pct} color={s.color}/>)}
              <StorageSeg pct={free} color="transparent"/>
            </div>

            <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
              {segs.map(s => <LegendDot key={s.label} color={s.color} label={s.label} value={s.value}/>)}
            </div>
          </div>
        </div>

        {/* Per-type cleanup */}
        <StgCard title="By media type" footnote="Plaintext media lives only in RAM while you're viewing it. Cleared blobs are re-fetched encrypted from the server if still in retention.">
          <StgRow icon={
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <rect x="3" y="5" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
              <circle cx="9" cy="11" r="2" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M3 17l5-4 4 3 3-2 6 5" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
            </svg>
          } iconBg="rgba(255,110,84,0.14)" label="Photos" value="710 MB"/>
          <StgRow icon={
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
            </svg>
          } iconBg="rgba(124,58,237,0.14)" label="Videos" value="480 MB"/>
          <StgRow icon={
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <path d="M2 12h2M6 8v8M10 5v14M14 8v8M18 10v4M22 12h-2" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
            </svg>
          } iconBg="rgba(16,185,129,0.14)" label="Voice messages" value="210 MB"/>
          <StgRow icon={
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <path d="M14 3H6.5A1.5 1.5 0 005 4.5v15A1.5 1.5 0 006.5 21h11A1.5 1.5 0 0019 19.5V8l-5-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              <path d="M14 3v5h5" stroke="currentColor" strokeWidth="1.8"/>
            </svg>
          } iconBg="rgba(245,158,11,0.14)" label="Files" value="180 MB" last/>
        </StgCard>

        {/* Auto-download rules */}
        <StgCard title="Auto-download" footnote="Files larger than 25 MB always ask before downloading regardless of this setting.">
          <AutoDownloadRow label="On Wi-Fi"       photos={true}  voice={true}  videos={true}  docs={false}/>
          <AutoDownloadRow label="On cellular"    photos={true}  voice={true}  videos={false} docs={false}/>
          <AutoDownloadRow label="When roaming"   photos={false} voice={false} videos={false} docs={false}/>

          <div style={{
            display: 'flex', alignItems: 'center', gap: 14,
            padding: '14px 18px', minHeight: 52,
          }}>
            <div style={{
              width: 28, height: 28, borderRadius: 8,
              background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
              display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
            }}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
                <path d="M12 4v12M6 10l6 6 6-6M4 20h16" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </div>
            <div style={{ flex: 1, fontSize: 14.5, fontWeight: 500, color: 'var(--sn-text)' }}>Max file size</div>
            <div style={{ fontSize: 13.5, fontWeight: 500, color: 'var(--sn-text-2)' }}>25 MB</div>
          </div>
        </StgCard>

        {/* Cache budget */}
        <StgCard title="Cache budget" footnote="LRU eviction kicks in when usage exceeds the budget. Older blobs are dropped first.">
          <StgRow icon={
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <rect x="3" y="5" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M3 12h18" stroke="currentColor" strokeWidth="1.8"/>
            </svg>
          } label="On-device cache limit" value="2 GB" last/>
        </StgCard>

        {/* Actions */}
        <StgCard title="Clean up">
          <StgRow icon={
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <path d="M21 5v6h-6M3 19v-6h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              <path d="M19 11a8 8 0 00-14-3M5 13a8 8 0 0014 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          } label="Clear cache" value="1.62 GB"/>
          <StgRow danger icon={
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <path d="M3 6h18M8 6V4a1 1 0 011-1h6a1 1 0 011 1v2M6 6l1 14a1 1 0 001 1h8a1 1 0 001-1l1-14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          } iconBg="rgba(255,77,77,0.14)" label="Clear chat history…" last/>
        </StgCard>
      </div>
    </div>
  );
}

Object.assign(window, { SnStorageData });
