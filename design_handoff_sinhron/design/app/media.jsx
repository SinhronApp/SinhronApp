// media.jsx — Photo/video viewer, camera-before-send, voice recording
// Exports: SnMediaViewer, SnCameraSend, SnVoiceRecording

// ─── Abstract "photo" placeholder ─────────────────────────────────
function PhotoBackdrop({ seed = 0, full = false }) {
  // Pick a colour pair from the avatar palette by seed
  const [c1, c2] = SN_AVATAR_PALETTES[seed % SN_AVATAR_PALETTES.length];
  return (
    <div style={{
      position: 'absolute', inset: 0,
      background: `linear-gradient(155deg, ${c1} 0%, ${c2} 100%)`,
      overflow: 'hidden',
    }}>
      <svg width="100%" height="100%" preserveAspectRatio="xMidYMid slice" viewBox="0 0 400 600" style={{ position: 'absolute', inset: 0 }}>
        <circle cx="300" cy="120" r="70" fill="rgba(255,255,255,0.45)"/>
        <path d="M0 420 Q 100 360 200 400 T 400 380 L 400 600 L 0 600 Z" fill="rgba(15,23,32,0.30)"/>
        <path d="M0 460 Q 130 410 230 440 T 400 420 L 400 600 L 0 600 Z" fill="rgba(15,23,32,0.45)"/>
        {full && (
          <>
            <ellipse cx="120" cy="240" rx="50" ry="36" fill="rgba(255,255,255,0.25)"/>
            <path d="M0 360 Q 70 320 140 340" stroke="rgba(255,255,255,0.40)" strokeWidth="2" fill="none"/>
          </>
        )}
      </svg>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. Media viewer — full-bleed photo, top chrome + caption + bottom strip
// ════════════════════════════════════════════════════════════════════
function SnMediaViewer({ dark = false, platform = 'ios' }) {
  return (
    <div style={{
      width: '100%', height: '100%',
      position: 'relative', overflow: 'hidden',
      background: '#000', color: '#fff',
      fontFamily: "'Geist', sans-serif",
    }}>
      <PhotoBackdrop seed={2} full/>

      {/* Top chrome */}
      <div style={{
        position: 'absolute', top: 0, left: 0, right: 0,
        background: 'linear-gradient(180deg, rgba(0,0,0,0.55) 0%, transparent 100%)',
        padding: '50px 14px 20px',
        display: 'flex', alignItems: 'center', gap: 12,
      }}>
        <button style={{
          width: 36, height: 36, borderRadius: 18, border: 'none',
          background: 'rgba(0,0,0,0.36)', backdropFilter: 'blur(20px)',
          color: '#fff', padding: 0, cursor: 'pointer',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
          </svg>
        </button>
        <SnAvatar name="Maria Chen" size={32}/>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 14, fontWeight: 600, letterSpacing: -0.1 }}>Maria Chen</div>
          <div style={{ fontSize: 12, fontWeight: 500, color: 'rgba(255,255,255,0.7)' }}>Yesterday · 20:14</div>
        </div>
        <button style={{
          width: 36, height: 36, borderRadius: 18, border: 'none',
          background: 'rgba(0,0,0,0.36)', backdropFilter: 'blur(20px)',
          color: '#fff', padding: 0, cursor: 'pointer',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
            <circle cx="5" cy="12" r="1.8" fill="currentColor"/>
            <circle cx="12" cy="12" r="1.8" fill="currentColor"/>
            <circle cx="19" cy="12" r="1.8" fill="currentColor"/>
          </svg>
        </button>
      </div>

      {/* Bottom: caption + thumbnails + actions */}
      <div style={{
        position: 'absolute', bottom: 0, left: 0, right: 0,
        background: 'linear-gradient(0deg, rgba(0,0,0,0.55) 0%, transparent 100%)',
        padding: '32px 16px 24px',
        display: 'flex', flexDirection: 'column', gap: 14,
      }}>
        {/* Caption */}
        <div style={{
          fontSize: 15, fontWeight: 500, lineHeight: '21px',
          color: '#fff', letterSpacing: -0.15,
          maxWidth: '88%',
        }}>Found this new spot ☀️</div>

        {/* Thumbnail strip — current item highlighted */}
        <div style={{ display: 'flex', gap: 6 }}>
          {[1, 2, 3, 4, 5, 6, 7, 8].map(i => {
            const active = i === 3;
            return (
              <div key={i} style={{
                flex: 1, aspectRatio: '1', borderRadius: 6,
                position: 'relative', overflow: 'hidden',
                boxShadow: active ? '0 0 0 2px #fff' : 'none',
                opacity: active ? 1 : 0.6,
              }}>
                <PhotoBackdrop seed={i + 1}/>
              </div>
            );
          })}
        </div>

        {/* Action row */}
        <div style={{
          display: 'flex', alignItems: 'center', gap: 18,
          paddingTop: 4,
        }}>
          {[
            <svg key="r" width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path d="M9 17l-6-6 6-6M3 11h11a6 6 0 016 6v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>,
            <svg key="f" width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path d="M15 7l6 6-6 6M21 13H10a6 6 0 00-6 6v1" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>,
            <svg key="s" width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path d="M21 15v3a2 2 0 01-2 2H5a2 2 0 01-2-2v-3M12 4v12M7 11l5 5 5-5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>,
          ].map((icon, i) => (
            <div key={i} style={{
              width: 40, height: 40, borderRadius: 20,
              background: 'rgba(0,0,0,0.36)', backdropFilter: 'blur(20px)',
              color: '#fff',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>{icon}</div>
          ))}
          <div style={{ flex: 1 }}/>
          <div style={{
            display: 'inline-flex', alignItems: 'center', gap: 8,
            padding: '8px 14px 8px 12px', borderRadius: 999,
            background: 'rgba(0,0,0,0.36)', backdropFilter: 'blur(20px)',
            color: '#fff', fontSize: 13, fontWeight: 600, letterSpacing: -0.1,
          }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <path d="M9 17l-6-6 6-6M3 11h11a6 6 0 016 6v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
            Reply
          </div>
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. Camera before send — captured photo with edit tools + caption
// ════════════════════════════════════════════════════════════════════
function SnCameraSend({ dark = false, platform = 'ios' }) {
  return (
    <div style={{
      width: '100%', height: '100%',
      position: 'relative', overflow: 'hidden',
      background: '#000', color: '#fff',
      display: 'flex', flexDirection: 'column',
      fontFamily: "'Geist', sans-serif",
    }}>
      {/* Captured image */}
      <div style={{ position: 'relative', flex: 1 }}>
        <PhotoBackdrop seed={4} full/>

        {/* Top chrome */}
        <div style={{
          position: 'absolute', top: 0, left: 0, right: 0,
          padding: '50px 16px 12px',
          display: 'flex', alignItems: 'center', gap: 14,
        }}>
          <button style={{
            width: 36, height: 36, borderRadius: 18, border: 'none',
            background: 'rgba(0,0,0,0.36)', backdropFilter: 'blur(20px)',
            color: '#fff', cursor: 'pointer',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
              <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
            </svg>
          </button>
          <div style={{ flex: 1 }}/>
          {/* Right-edge vertical tool stack */}
          {[
            <svg key="crop" width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path d="M6 2v16h16M2 6h16v16" stroke="currentColor" strokeWidth="1.8"/>
            </svg>,
            <svg key="text" width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path d="M4 6h16M12 6v14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>,
            <svg key="draw" width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path d="M3 17l11-11 4 4-11 11H3v-4z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
            </svg>,
          ].map((icon, i) => (
            <button key={i} style={{
              width: 36, height: 36, borderRadius: 18, border: 'none',
              background: 'rgba(0,0,0,0.36)', backdropFilter: 'blur(20px)',
              color: '#fff', cursor: 'pointer',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>{icon}</button>
          ))}
        </div>
      </div>

      {/* Bottom composer — caption + recipient + send */}
      <div style={{
        background: 'rgba(0,0,0,0.92)',
        backdropFilter: 'blur(20px)',
        padding: '14px 14px 22px',
        display: 'flex', flexDirection: 'column', gap: 12,
      }}>
        {/* Caption */}
        <div style={{
          minHeight: 36, borderRadius: 18,
          background: 'rgba(255,255,255,0.10)',
          display: 'flex', alignItems: 'center', gap: 8,
          padding: '8px 14px',
          fontSize: 15, color: 'rgba(255,255,255,0.55)', letterSpacing: -0.1,
        }}>Add a caption…</div>

        {/* Recipient row + send */}
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
        }}>
          <div style={{
            display: 'inline-flex', alignItems: 'center', gap: 8,
            padding: '6px 12px 6px 4px', borderRadius: 999,
            background: 'rgba(255,255,255,0.12)',
          }}>
            <SnAvatar name="Maria Chen" size={28}/>
            <span style={{ fontSize: 13.5, fontWeight: 600, letterSpacing: -0.1 }}>Maria Chen</span>
          </div>
          <div style={{ flex: 1 }}/>
          <div style={{
            width: 48, height: 48, borderRadius: 24,
            background: 'var(--sn-accent)', color: '#fff',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            boxShadow: '0 6px 16px rgba(45,111,247,0.40)',
          }}>
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path d="M3 12l18-9-7 18-3-7-8-2z" fill="currentColor"/>
            </svg>
          </div>
        </div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. Voice recording in-progress — composer expanded with waveform
// ════════════════════════════════════════════════════════════════════
function SnVoiceRecording({ dark = false, platform = 'ios' }) {
  // Live waveform — left scrolled, with recent peaks tallest
  const samples = [3,5,4,8,11,7,14,18,12,16,9,11,20,15,17,22,18,14,11,8,12,16,21,19,14,8,5,9,13,17,20,16,12,9,14,18,16,11];
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* Header — same as 1:1 chat */}
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
        <SnAvatar name="Maria Chen" size={36} online/>
        <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 1 }}>
          <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: -0.2, color: 'var(--sn-text)' }}>Maria Chen</div>
          <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-success)' }}>online</div>
        </div>
      </div>

      {/* Faint chat history behind */}
      <div className="sn-scroll" style={{ flex: 1, opacity: 0.4, pointerEvents: 'none' }}>
        <div style={{ padding: '12px 12px' }}>
          <div style={{ display: 'flex', justifyContent: 'flex-start', padding: '2px 0' }}>
            <div style={{
              maxWidth: '78%', background: 'var(--sn-surface)', borderRadius: '18px 18px 18px 6px',
              padding: '8px 12px', fontSize: 15, color: 'var(--sn-text)',
              boxShadow: '0 1px 1px rgba(15,23,32,0.05)',
            }}>Sounds great — see you at 9 tomorrow ☕</div>
          </div>
        </div>
      </div>

      {/* Expanded recording composer */}
      <div style={{
        background: 'var(--sn-bg)',
        borderTop: '0.5px solid var(--sn-divider)',
        padding: '10px 14px 14px',
        display: 'flex', flexDirection: 'column', gap: 10,
        position: 'relative',
      }}>
        {/* Slide-to-cancel hint */}
        <div style={{
          display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 6,
          fontSize: 12.5, fontWeight: 500, color: 'var(--sn-text-3)',
          padding: '2px 0',
        }}>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
            <path d="M14 6l-6 6 6 6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
          Slide to cancel
        </div>

        {/* Recording bar */}
        <div style={{
          display: 'flex', alignItems: 'center', gap: 12,
          padding: '10px 14px',
          background: 'var(--sn-bg-soft)',
          borderRadius: 24,
          minHeight: 50,
        }}>
          {/* Pulse dot + timer */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexShrink: 0 }}>
            <div style={{
              width: 10, height: 10, borderRadius: 5,
              background: '#E04A4A',
              boxShadow: '0 0 0 4px rgba(224,74,74,0.20)',
            }}/>
            <div className="sn-mono" style={{
              fontSize: 14, fontWeight: 600, color: 'var(--sn-text)',
              letterSpacing: 0.2, fontVariantNumeric: 'tabular-nums',
              minWidth: 48,
            }}>0:14</div>
          </div>

          {/* Live waveform */}
          <div style={{
            flex: 1, display: 'flex', alignItems: 'center', gap: 2,
            height: 26, overflow: 'hidden',
            mask: 'linear-gradient(90deg, transparent 0%, #000 12%, #000 100%)',
            WebkitMask: 'linear-gradient(90deg, transparent 0%, #000 12%, #000 100%)',
          }}>
            {samples.map((amp, i) => (
              <div key={i} style={{
                width: 2, height: amp, borderRadius: 1.5,
                background: 'var(--sn-accent)',
                opacity: 0.4 + (i / samples.length) * 0.6,
              }}/>
            ))}
          </div>

          {/* Trash (cancel) */}
          <button style={{
            width: 32, height: 32, borderRadius: 16, border: 'none',
            background: 'transparent', color: 'var(--sn-text-2)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            flexShrink: 0,
          }}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
              <path d="M3 6h18M8 6V4a1 1 0 011-1h6a1 1 0 011 1v2M6 6l1 14a1 1 0 001 1h8a1 1 0 001-1l1-14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          </button>
        </div>

        {/* Bottom row — mic (held) + send-now option */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <div style={{
            flex: 1, fontSize: 12.5, fontWeight: 500,
            color: 'var(--sn-text-3)', letterSpacing: -0.05,
            paddingLeft: 4,
          }}>Release to send · drag up to lock</div>
          {/* Lock pill */}
          <div style={{
            display: 'flex', flexDirection: 'column', alignItems: 'center',
            padding: '8px 10px 8px', borderRadius: 18,
            background: 'var(--sn-bg-soft)',
            color: 'var(--sn-text-3)', gap: 4,
          }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <rect x="5" y="11" width="14" height="9" rx="2" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M8 11V8a4 4 0 018 0v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          </div>
          {/* Mic — pressed state */}
          <div style={{
            width: 50, height: 50, borderRadius: 25,
            background: 'var(--sn-accent)', color: '#fff',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            boxShadow: '0 0 0 6px rgba(45,111,247,0.20), 0 6px 18px rgba(45,111,247,0.45)',
            transform: 'scale(1.05)',
          }}>
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
              <rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="2.2" fill="currentColor"/>
              <path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"/>
            </svg>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SnMediaViewer, SnCameraSend, SnVoiceRecording });
