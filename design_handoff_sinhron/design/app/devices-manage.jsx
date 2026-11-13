// devices-manage.jsx — Linked devices in edit / manage mode
// The existing "Linked devices" row in Settings opens a quick list. This is
// the deeper-edit screen the user lands on when they tap "Edit": each row
// shows fingerprint + OS + paired-on, can be renamed inline, and revoked
// individually. "This device" is pinned at the top and can't be revoked
// from itself (that flow lives in account-delete.jsx → SnDeleteDevice).
//
// Exports: SnDevicesManage

const DEVICES = [
  { name: 'iPhone 15 Pro',     os: 'iOS 18.4',     fp: 'a4f7 b321 9c08 ec22', paired: 'Apr 02 · 14:22', last: 'just now', self: true,  pushable: true,   icon: 'phone' },
  { name: 'MacBook Pro',       os: 'macOS 14.5',   fp: '7e10 2b48 c5a9 3f01', paired: 'Apr 02 · 14:48', last: '12 min ago', pushable: false, icon: 'laptop' },
  { name: 'iPad mini',         os: 'iPadOS 17.4',  fp: 'd29c 1e7b 0a83 b610', paired: 'Mar 18 · 09:11', last: '3 days ago', pushable: true,   icon: 'tablet' },
  { name: 'Pixel 8 (work)',    os: 'Android 14',   fp: '4f02 b9d6 1a55 e7c3', paired: 'Jan 12 · 18:30', last: '2 weeks ago', warn: true,      pushable: true,   icon: 'phone' },
];

function DeviceIcon({ kind, color = 'var(--sn-accent)' }) {
  const map = {
    phone: <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><rect x="6" y="2" width="12" height="20" rx="2.5" stroke={color} strokeWidth="1.8"/><circle cx="12" cy="18.5" r="0.9" fill={color}/></svg>,
    laptop: <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><rect x="3.5" y="5" width="17" height="11" rx="1.5" stroke={color} strokeWidth="1.8"/><path d="M2 18h20" stroke={color} strokeWidth="1.8" strokeLinecap="round"/></svg>,
    tablet: <svg width="22" height="22" viewBox="0 0 24 24" fill="none"><rect x="4" y="3" width="16" height="18" rx="2" stroke={color} strokeWidth="1.8"/><path d="M10 18h4" stroke={color} strokeWidth="1.8" strokeLinecap="round"/></svg>,
  };
  return map[kind] || map.phone;
}

function DevHeader({ title }) {
  return (
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
      }}>{title}</div>
      <div style={{
        fontSize: 14, fontWeight: 600, color: 'var(--sn-accent)', letterSpacing: -0.1,
        paddingRight: 4,
      }}>Done</div>
    </div>
  );
}

// One device card — opens to reveal Rename / Revoke when expanded
function DeviceCard({ d, expanded, editing }) {
  return (
    <div style={{
      background: 'var(--sn-surface)',
      borderRadius: 16,
      padding: '14px 16px',
      boxShadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider)',
      display: 'flex', flexDirection: 'column', gap: 12,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
        <div style={{
          width: 42, height: 42, borderRadius: 11,
          background: d.warn ? 'rgba(217,119,6,0.14)' : 'var(--sn-accent-soft)',
          color: d.warn ? '#C2410C' : 'var(--sn-accent)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
        }}>
          <DeviceIcon kind={d.icon} color="currentColor"/>
        </div>

        <div style={{ flex: 1, minWidth: 0 }}>
          {editing && d.self ? (
            <div style={{
              display: 'flex', alignItems: 'center', gap: 8,
              padding: '4px 0',
              borderBottom: '1.5px solid var(--sn-accent)',
            }}>
              <div style={{ fontSize: 15, fontWeight: 600, color: 'var(--sn-text)', letterSpacing: -0.15 }}>{d.name}</div>
              <div style={{ width: 1.5, height: 18, background: 'var(--sn-accent)' }}/>
            </div>
          ) : (
            <div style={{
              fontSize: 15, fontWeight: 600, letterSpacing: -0.15,
              color: 'var(--sn-text)',
              display: 'flex', alignItems: 'center', gap: 8,
              whiteSpace: 'nowrap', overflow: 'hidden',
            }}>
              <span style={{ whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{d.name}</span>
              {d.self && (
                <span style={{
                  fontSize: 10.5, fontWeight: 700, letterSpacing: 0.2,
                  padding: '2px 6px', borderRadius: 4,
                  background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
                  textTransform: 'uppercase', flexShrink: 0,
                }}>This device</span>
              )}
            </div>
          )}
          <div className="sn-mono" style={{
            fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)', marginTop: 3, letterSpacing: 0,
          }}>{d.os} · last seen {d.last}</div>
        </div>

        {/* Right side — rename pencil OR warn dot */}
        {d.warn ? (
          <div style={{
            padding: '4px 10px', borderRadius: 999,
            background: 'rgba(217,119,6,0.14)', color: '#C2410C',
            fontSize: 11, fontWeight: 700, letterSpacing: 0.2, textTransform: 'uppercase',
            flexShrink: 0,
          }}>Stale</div>
        ) : (
          <div style={{
            width: 32, height: 32, borderRadius: 10,
            background: 'var(--sn-bg-soft)', color: 'var(--sn-text-2)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
          }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <path d="M16.5 3.5l4 4-12 12H4.5v-4l12-12z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              <path d="M13.5 6.5l4 4" stroke="currentColor" strokeWidth="1.8"/>
            </svg>
          </div>
        )}
      </div>

      {/* Fingerprint + paired — always shown in manage view */}
      <div style={{
        display: 'flex', alignItems: 'center', gap: 8,
        padding: '8px 12px', borderRadius: 10,
        background: 'var(--sn-bg-soft)',
      }}>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-text-3)', flexShrink: 0 }}>
          <path d="M12 2a10 10 0 00-10 10M12 2a10 10 0 0110 10M6 14c0 5 3 8 6 8s6-3 6-8a6 6 0 10-12 0M10 14a2 2 0 014 0v3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round"/>
        </svg>
        <div className="sn-mono" style={{
          flex: 1, fontSize: 11.5, fontWeight: 500, color: 'var(--sn-text-2)',
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
        }}>{d.fp}</div>
        <div className="sn-mono" style={{ fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)' }}>{d.paired}</div>
      </div>

      {/* Inline action row — only on the warn'd/expanded card */}
      {expanded && (
        <div style={{
          display: 'flex', gap: 8,
          paddingTop: 4,
        }}>
          {!d.self && (
            <div style={{
              flex: 1, height: 40, borderRadius: 12,
              background: 'var(--sn-bg-soft)', color: 'var(--sn-text)',
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
              fontSize: 13.5, fontWeight: 600, letterSpacing: -0.05,
            }}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                <path d="M16.5 3.5l4 4-12 12H4.5v-4l12-12z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
                <path d="M13.5 6.5l4 4" stroke="currentColor" strokeWidth="1.8"/>
              </svg>
              Rename
            </div>
          )}
          <div style={{
            flex: 1, height: 40, borderRadius: 12,
            background: 'rgba(255,77,77,0.14)', color: '#D03A3A',
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
            fontSize: 13.5, fontWeight: 600, letterSpacing: -0.05,
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
              <rect x="2.5" y="5" width="13" height="11" rx="2" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M15 9l5 5M20 9l-5 5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
            {d.self ? 'Sign out this device' : 'Revoke'}
          </div>
        </div>
      )}
    </div>
  );
}

function SnDevicesManage({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <DevHeader title="Linked devices"/>

      <div className="sn-scroll" style={{ flex: 1, padding: '18px 14px 24px' }}>
        {/* Lead — total + add device CTA */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 16 }}>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 22, fontWeight: 600, letterSpacing: -0.5, color: 'var(--sn-text)' }}>
              {DEVICES.length} <span style={{ fontSize: 15, color: 'var(--sn-text-3)' }}>devices · 1 stale</span>
            </div>
            <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)', marginTop: 2 }}>
              Each is a leaf in your MLS groups
            </div>
          </div>
          <div style={{
            height: 38, padding: '0 14px', borderRadius: 12,
            background: 'var(--sn-accent)', color: '#fff',
            display: 'flex', alignItems: 'center', gap: 6,
            fontSize: 13.5, fontWeight: 600, letterSpacing: -0.05,
            boxShadow: '0 1px 2px rgba(45,111,247,0.20), 0 4px 12px rgba(45,111,247,0.18)',
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
              <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"/>
            </svg>
            Link new
          </div>
        </div>

        {/* This device */}
        <div style={{
          fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase',
          color: 'var(--sn-text-3)', padding: '0 4px 8px',
        }}>This device</div>
        <DeviceCard d={DEVICES[0]} editing/>

        {/* Other devices */}
        <div style={{
          fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase',
          color: 'var(--sn-text-3)', padding: '18px 4px 8px',
        }}>Other devices · {DEVICES.length - 1}</div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {DEVICES.slice(1).map((d, i) => (
            <DeviceCard key={d.name} d={d} expanded={d.warn}/>
          ))}
        </div>

        {/* Footnote */}
        <div style={{
          marginTop: 16, padding: '12px 14px',
          background: 'var(--sn-bg-soft)', borderRadius: 12,
          fontSize: 12, fontWeight: 500, lineHeight: '18px', letterSpacing: -0.05,
          color: 'var(--sn-text-2)',
        }}>
          Revoking a device commits an MLS <span className="sn-mono" style={{ fontSize: 11, color: 'var(--sn-text)', background: 'var(--sn-surface)', padding: '0 5px', borderRadius: 4 }}>Remove</span> across every group you're in. After the commit, that device can't decrypt any further messages.
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SnDevicesManage });
