// loading-skeletons.jsx — Sinhron loading states
// Two: chat-list skeleton (cold start), message-history skeleton (opening a chat).
// Both shimmer with a slow, single-direction sweep. Keep amplitudes low —
// premium apps suggest content, not strobe.
//
// Exports: SnSkeletonChatList, SnSkeletonChatView

// ─── Shimmer CSS (one keyframe shared) ──────────────────────────────
const SK_STYLE = `
@keyframes sn-shimmer {
  0%   { background-position: -200px 0; }
  100% { background-position: calc(200px + 100%) 0; }
}
.sn-skel {
  background: linear-gradient(
    90deg,
    var(--sn-bg-soft) 0%,
    var(--sn-divider-strong) 50%,
    var(--sn-bg-soft) 100%
  );
  background-size: 200px 100%;
  background-repeat: no-repeat;
  background-color: var(--sn-bg-soft);
  animation: sn-shimmer 1.6s ease-in-out infinite;
  border-radius: 6px;
}
.sn-skel-round { border-radius: 999px; }
`;

function SkelLine({ width = '60%', height = 12, round = false, style }) {
  return (
    <div className={`sn-skel ${round ? 'sn-skel-round' : ''}`} style={{
      width, height, ...style,
    }}/>
  );
}

function SkelCircle({ size = 50 }) {
  return (
    <div className="sn-skel sn-skel-round" style={{
      width: size, height: size, flexShrink: 0,
    }}/>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. Chat-list skeleton — same chrome as the real list
// ════════════════════════════════════════════════════════════════════
function SnSkeletonChatList({ dark = false, platform = 'ios' }) {
  // 10 placeholder rows with varied widths so the rhythm reads as real list
  const rows = [
    { name: '70%', preview: '88%', time: 30 },
    { name: '55%', preview: '60%', time: 28 },
    { name: '64%', preview: '78%', time: 30, hasBadge: true },
    { name: '48%', preview: '55%', time: 26 },
    { name: '72%', preview: '82%', time: 30 },
    { name: '52%', preview: '65%', time: 28, hasBadge: true },
    { name: '60%', preview: '50%', time: 24 },
    { name: '68%', preview: '85%', time: 30 },
    { name: '50%', preview: '72%', time: 26 },
    { name: '58%', preview: '60%', time: 30 },
  ];

  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <style dangerouslySetInnerHTML={{ __html: SK_STYLE }}/>

      {/* Header — REAL chrome (not skeleton). The "Chats" word loads instantly
          from the app shell; only the data below is async. */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        padding: '6px 16px 12px',
      }}>
        <SkelCircle size={40}/>
        <div style={{
          flex: 1, fontSize: 24, fontWeight: 600, letterSpacing: -0.5,
          color: 'var(--sn-text)',
        }}>Chats</div>
        <div style={{
          width: 36, height: 36, borderRadius: 10,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: 'var(--sn-text-3)',
        }}>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
            <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M16.5 16.5L21 21" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
        </div>
      </div>

      {/* Filter pills — kept real (instant) but greyed out */}
      <div style={{ display: 'flex', gap: 8, padding: '4px 16px 14px', opacity: 0.55 }}>
        {['All', 'Unread', 'Groups'].map((f, i) => (
          <div key={f} style={{
            padding: '7px 14px', borderRadius: 999,
            background: i === 0 ? 'var(--sn-accent-soft)' : 'transparent',
            color: i === 0 ? 'var(--sn-accent)' : 'var(--sn-text-3)',
            fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1,
          }}>{f}</div>
        ))}
      </div>

      {/* Rows */}
      <div className="sn-scroll" style={{
        flex: 1, paddingBottom: platform === 'ios' ? 110 : 100,
      }}>
        {rows.map((r, i) => (
          <div key={i} style={{
            display: 'flex', alignItems: 'center', gap: 12,
            padding: '14px 16px',
          }}>
            <SkelCircle size={50}/>
            <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 8 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <SkelLine width={r.name} height={13}/>
                <div style={{ flex: 1 }}/>
                <SkelLine width={r.time} height={10}/>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <SkelLine width={r.preview} height={10}/>
                {r.hasBadge && (
                  <div className="sn-skel sn-skel-round" style={{ width: 22, height: 22 }}/>
                )}
              </div>
            </div>
          </div>
        ))}
      </div>

      {/* Tab bar — real, no skeleton (it's part of the shell) */}
      <SnTabBar platform={platform} dark={dark}/>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Message-history skeleton — bubbles of varied widths, in/out
// ════════════════════════════════════════════════════════════════════
function SnSkeletonChatView({ dark = false, platform = 'ios' }) {
  // [side, widthPx, heightPx]
  const bubbles = [
    ['in', 180, 38, false],
    ['in', 140, 24, true],   // contiguous
    ['out', 220, 24],
    ['in', 240, 64],
    ['out', 160, 24],
    ['out', 200, 44, true],
    ['in', 180, 24],
    ['in', 110, 24, true],
    ['out', 240, 44],
  ];

  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <style dangerouslySetInnerHTML={{ __html: SK_STYLE }}/>

      {/* Header — chrome is real, only the title resolves once data arrives */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        padding: '8px 14px 10px',
        borderBottom: '0.5px solid var(--sn-divider)',
      }}>
        <div style={{
          width: 32, height: 32, color: 'var(--sn-text)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          marginLeft: -6,
        }}>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
            <path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
        <SkelCircle size={36}/>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 5 }}>
          <SkelLine width={120} height={12}/>
          <SkelLine width={64} height={9}/>
        </div>
        <div className="sn-skel sn-skel-round" style={{ width: 22, height: 22 }}/>
        <div className="sn-skel sn-skel-round" style={{ width: 22, height: 22 }}/>
      </div>

      {/* Bubbles */}
      <div className="sn-scroll" style={{ flex: 1, padding: '14px 0' }}>
        {/* day separator placeholder */}
        <div style={{ display: 'flex', justifyContent: 'center', padding: '4px 0 12px' }}>
          <SkelLine width={64} height={18} style={{ borderRadius: 999 }}/>
        </div>

        {bubbles.map((b, i) => {
          const [side, w, h, contiguous] = b;
          const isOut = side === 'out';
          const r = 18, rTail = 6;
          const radius = isOut
            ? `${r}px ${r}px ${contiguous ? r : rTail}px ${r}px`
            : `${r}px ${r}px ${r}px ${contiguous ? r : rTail}px`;
          return (
            <div key={i} style={{
              display: 'flex', justifyContent: isOut ? 'flex-end' : 'flex-start',
              padding: '0 12px', marginTop: contiguous ? 2 : 6,
            }}>
              <div className="sn-skel" style={{
                width: w, height: h,
                borderRadius: radius,
                // override the default 6px corners with a bubble shape
                backgroundColor: isOut
                  ? (dark ? 'rgba(79,138,255,0.20)' : 'rgba(45,111,247,0.12)')
                  : 'var(--sn-surface)',
                backgroundImage: `linear-gradient(90deg,
                  transparent 0%,
                  var(--sn-divider-strong) 50%,
                  transparent 100%)`,
              }}/>
            </div>
          );
        })}
      </div>

      {/* Composer — real, instant */}
      <div style={{
        display: 'flex', alignItems: 'flex-end', gap: 8,
        padding: '8px 10px 10px',
        borderTop: '0.5px solid var(--sn-divider)',
      }}>
        <div style={{
          width: 36, height: 36, borderRadius: '50%',
          background: 'var(--sn-bg-soft)', color: 'var(--sn-text-3)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
          </svg>
        </div>
        <div style={{
          flex: 1, height: 36, borderRadius: 18,
          background: 'var(--sn-bg-soft)',
        }}/>
        <div style={{
          width: 36, height: 36, borderRadius: '50%',
          background: 'var(--sn-bg-soft)', color: 'var(--sn-text-3)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="2"/>
            <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
          </svg>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SnSkeletonChatList, SnSkeletonChatView });
