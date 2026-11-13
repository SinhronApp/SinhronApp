// onboarding-splash.jsx — One-time intro the first time the app is opened
// Three swipe-cards explaining the model: (1) what Sinhron is, (2) what it
// is not (no email/phone/password), (3) what living in it means. Shown
// BEFORE the Welcome screen — once. After the user taps "Continue" they
// land on SnWelcome (Get started / Link a device).
//
// Exports: SnOnboardSplash1, SnOnboardSplash2, SnOnboardSplash3

// ─── Pager-dots ─────────────────────────────────────────────────────
function Dots({ index, total = 3 }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'center', gap: 6, padding: '4px 0 14px' }}>
      {Array.from({ length: total }).map((_, i) => (
        <div key={i} style={{
          width: i === index ? 22 : 6, height: 6, borderRadius: 3,
          background: i === index ? 'var(--sn-accent)' : 'var(--sn-text-4)',
          transition: 'width .15s ease',
        }}/>
      ))}
    </div>
  );
}

// ─── Common frame ───────────────────────────────────────────────────
function SplashFrame({ dark, hero, eyebrow, title, copy, list, index, primary }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      {/* Top — Skip on the right (subtle) */}
      <div style={{ display: 'flex', alignItems: 'center', padding: '14px 18px 0' }}>
        <div style={{ flex: 1 }}/>
        <div style={{
          fontSize: 13, fontWeight: 600, color: 'var(--sn-text-3)', letterSpacing: -0.05,
        }}>Skip</div>
      </div>

      {/* Hero */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', padding: '0 26px' }}>
        <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 30 }}>
          {hero}
        </div>

        {/* Eyebrow */}
        <div style={{
          display: 'inline-flex', alignSelf: 'flex-start',
          padding: '4px 10px', borderRadius: 999,
          background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
          fontSize: 11, fontWeight: 700, letterSpacing: 0.4, textTransform: 'uppercase',
          marginBottom: 14,
        }}>{eyebrow}</div>

        <div style={{
          fontSize: 32, fontWeight: 600, letterSpacing: -0.8,
          color: 'var(--sn-text)', lineHeight: '38px',
          textWrap: 'pretty',
        }}>{title}</div>

        {copy && (
          <div style={{
            marginTop: 12, fontSize: 15.5, fontWeight: 500,
            color: 'var(--sn-text-2)', lineHeight: '22px', letterSpacing: -0.1,
          }}>{copy}</div>
        )}

        {list && (
          <div style={{ marginTop: 22, display: 'flex', flexDirection: 'column', gap: 14 }}>
            {list.map((it, i) => (
              <div key={i} style={{ display: 'flex', gap: 12, alignItems: 'flex-start' }}>
                <div style={{
                  width: 24, height: 24, borderRadius: 12, marginTop: 2,
                  background: it.no ? 'var(--sn-bg-soft)' : 'var(--sn-accent-soft)',
                  color: it.no ? 'var(--sn-text-3)' : 'var(--sn-accent)',
                  display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
                }}>
                  {it.no ? (
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                      <path d="M5 5l14 14M19 5L5 19" stroke="currentColor" strokeWidth="2.8" strokeLinecap="round"/>
                    </svg>
                  ) : (
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none">
                      <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
                    </svg>
                  )}
                </div>
                <div style={{ flex: 1, fontSize: 14.5, lineHeight: '20px', letterSpacing: -0.05 }}>
                  <span style={{ fontWeight: 600, color: 'var(--sn-text)' }}>{it.k}</span>
                  {it.v && <span style={{ color: 'var(--sn-text-2)' }}> · {it.v}</span>}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Bottom — dots + CTA */}
      <div style={{ padding: '0 22px 18px' }}>
        <Dots index={index}/>
        <DsButton variant="primary" trailing={
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
            <path d="M9 5l7 7-7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        }>{primary || 'Continue'}</DsButton>
      </div>
    </div>
  );
}

// ─── Hero illustrations — abstract, color-rich, no faces ────────────
function HeroLayered() {
  return (
    <svg width="200" height="170" viewBox="0 0 200 170" fill="none">
      {/* layered "messages" */}
      <rect x="20"  y="32" width="120" height="36" rx="14" fill="#FFB089"/>
      <rect x="55"  y="76" width="130" height="36" rx="14" fill="#A0C4FF"/>
      <rect x="30"  y="120" width="100" height="36" rx="14" fill="#C5A0FF"/>
      {/* lock badge */}
      <circle cx="170" cy="38" r="22" fill="#2D6FF7"/>
      <rect x="160" y="34" width="20" height="14" rx="3" fill="none" stroke="#fff" strokeWidth="2"/>
      <path d="M163 34v-3a7 7 0 0114 0v3" stroke="#fff" strokeWidth="2" strokeLinecap="round"/>
    </svg>
  );
}

function HeroNoIdentity() {
  return (
    <svg width="200" height="170" viewBox="0 0 200 170" fill="none">
      {/* @ symbol crossed */}
      <circle cx="80" cy="85" r="60" fill="none" stroke="var(--sn-text-4)" strokeWidth="2.5"/>
      <circle cx="80" cy="85" r="22" fill="none" stroke="var(--sn-text-4)" strokeWidth="2.5"/>
      <path d="M105 85v15a12 12 0 0024 0v-15" stroke="var(--sn-text-4)" strokeWidth="2.5" strokeLinecap="round"/>
      <path d="M30 30l120 120" stroke="#FF6E54" strokeWidth="5" strokeLinecap="round"/>
      {/* recovery phrase tiles */}
      <rect x="120" y="20" width="60" height="22" rx="6" fill="#A0C4FF"/>
      <rect x="130" y="48" width="60" height="22" rx="6" fill="#9DE6CB"/>
      <rect x="140" y="76" width="50" height="22" rx="6" fill="#C5A0FF"/>
    </svg>
  );
}

function HeroServer() {
  return (
    <svg width="200" height="170" viewBox="0 0 200 170" fill="none">
      {/* server rack */}
      <rect x="50" y="20" width="100" height="36" rx="6" fill="#2D6FF7"/>
      <circle cx="64" cy="38" r="3" fill="#fff"/>
      <rect x="50" y="64" width="100" height="36" rx="6" fill="#7C3AED"/>
      <circle cx="64" cy="82" r="3" fill="#fff"/>
      <rect x="50" y="108" width="100" height="36" rx="6" fill="#10B981"/>
      <circle cx="64" cy="126" r="3" fill="#fff"/>
      {/* small devices fanned out */}
      <rect x="6"   y="58" width="28" height="44" rx="5" fill="none" stroke="var(--sn-text-3)" strokeWidth="2.4"/>
      <rect x="166" y="58" width="28" height="44" rx="5" fill="none" stroke="var(--sn-text-3)" strokeWidth="2.4"/>
      {/* connection lines */}
      <path d="M34 80h12M154 80h12" stroke="var(--sn-text-4)" strokeWidth="2.4" strokeLinecap="round"/>
    </svg>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. What Sinhron is
// ════════════════════════════════════════════════════════════════════
function SnOnboardSplash1({ dark = false, platform = 'ios' }) {
  return (
    <SplashFrame dark={dark}
      hero={<HeroLayered/>}
      index={0}
      eyebrow="Welcome"
      title="Premium chat. Private by default."
      copy="Sinhron is end-to-end encrypted from the very first message. Your messages, calls and files are readable only on the devices you control."
    />
  );
}

// ════════════════════════════════════════════════════════════════════
// 2. What it isn't
// ════════════════════════════════════════════════════════════════════
function SnOnboardSplash2({ dark = false, platform = 'ios' }) {
  return (
    <SplashFrame dark={dark}
      hero={<HeroNoIdentity/>}
      index={1}
      eyebrow="No identity, no profile"
      title="No email, no phone, no password."
      list={[
        { no: true,  k: 'No email',                v: 'we never ask for one' },
        { no: true,  k: 'No phone number',         v: 'your contacts find you by username' },
        { no: true,  k: 'No password',             v: 'a 24-word phrase restores you' },
        { no: false, k: 'You own the identity key', v: 'lost the phrase = lost the account' },
      ]}
    />
  );
}

// ════════════════════════════════════════════════════════════════════
// 3. Self-hosted = your data, your rules
// ════════════════════════════════════════════════════════════════════
function SnOnboardSplash3({ dark = false, platform = 'ios' }) {
  return (
    <SplashFrame dark={dark}
      hero={<HeroServer/>}
      index={2}
      eyebrow="Self-hosted"
      title="Sinhron runs on a server you trust."
      copy={<span>Your team, your company, or you can run one with <span className="sn-mono" style={{ fontSize: 13, color: 'var(--sn-text)' }}>docker compose up -d</span>. Your data lives there and nowhere else — not with us, not with anyone.</span>}
      primary="Get started"
    />
  );
}

Object.assign(window, { SnOnboardSplash1, SnOnboardSplash2, SnOnboardSplash3 });
