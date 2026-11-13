// spec-buttons.jsx — All button states for the Sinhron design system
// Variants: primary, secondary, ghost, danger
// States: default, pressed, disabled, loading
// Plus: with leading icon, icon-only round, and size scale.
//
// Exports: SinhronButtonStates

// ─── Pure-CSS spinning ring (reusable) ──────────────────────────────
const BTN_STYLE = `
@keyframes sn-btn-spin { to { transform: rotate(360deg); } }
.sn-btn-ring {
  width: 16px; height: 16px; border-radius: 50%;
  border: 2px solid currentColor; border-right-color: transparent;
  opacity: 0.85;
  animation: sn-btn-spin 0.8s linear infinite;
  display: inline-block;
}
`;

// ─── One button (state-driven, not interactive) ─────────────────────
function SpecButton({
  variant = 'primary',
  state = 'default',
  leading, trailing, children, full = true, height = 50,
  iconOnly = false,
}) {
  // Base palettes — match entry.jsx DsButton
  const palettes = {
    primary: {
      default:  { bg: 'var(--sn-accent)', fg: '#fff', shadow: '0 1px 2px rgba(45,111,247,0.20), 0 6px 16px rgba(45,111,247,0.18)', border: 'none' },
      pressed:  { bg: 'color-mix(in srgb, var(--sn-accent) 88%, #000)', fg: '#fff', shadow: '0 0 0 0 rgba(45,111,247,0)', border: 'none', transform: 'translateY(1px) scale(0.985)' },
      disabled: { bg: 'var(--sn-bg-soft)', fg: 'var(--sn-text-4)', shadow: 'none', border: 'none' },
      loading:  { bg: 'var(--sn-accent)', fg: '#fff', shadow: '0 1px 2px rgba(45,111,247,0.20), 0 6px 16px rgba(45,111,247,0.18)', border: 'none' },
    },
    secondary: {
      default:  { bg: 'var(--sn-surface)', fg: 'var(--sn-text)', shadow: '0 1px 2px rgba(15,23,32,0.04), 0 0 0 0.5px var(--sn-divider-strong)', border: 'none' },
      pressed:  { bg: 'var(--sn-bg-soft)', fg: 'var(--sn-text)', shadow: '0 0 0 0.5px var(--sn-divider-strong)', border: 'none', transform: 'translateY(1px) scale(0.985)' },
      disabled: { bg: 'var(--sn-bg-soft)', fg: 'var(--sn-text-4)', shadow: 'none', border: 'none' },
      loading:  { bg: 'var(--sn-surface)', fg: 'var(--sn-text-2)', shadow: '0 0 0 0.5px var(--sn-divider-strong)', border: 'none' },
    },
    ghost: {
      default:  { bg: 'transparent', fg: 'var(--sn-accent)', shadow: 'none', border: 'none' },
      pressed:  { bg: 'var(--sn-accent-soft)', fg: 'var(--sn-accent)', shadow: 'none', border: 'none' },
      disabled: { bg: 'transparent', fg: 'var(--sn-text-4)', shadow: 'none', border: 'none' },
      loading:  { bg: 'transparent', fg: 'var(--sn-accent)', shadow: 'none', border: 'none' },
    },
    danger: {
      default:  { bg: '#FF4D4D', fg: '#fff', shadow: '0 1px 2px rgba(255,77,77,0.22), 0 6px 16px rgba(255,77,77,0.20)', border: 'none' },
      pressed:  { bg: '#E03B3B', fg: '#fff', shadow: '0 0 0 0 rgba(0,0,0,0)', border: 'none', transform: 'translateY(1px) scale(0.985)' },
      disabled: { bg: 'var(--sn-bg-soft)', fg: 'var(--sn-text-4)', shadow: 'none', border: 'none' },
      loading:  { bg: '#FF4D4D', fg: '#fff', shadow: '0 1px 2px rgba(255,77,77,0.22), 0 6px 16px rgba(255,77,77,0.20)', border: 'none' },
    },
  };
  const p = palettes[variant][state];
  const showRing = state === 'loading';

  return (
    <div style={{
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 8,
      width: full ? '100%' : 'auto',
      minWidth: iconOnly ? height : 0,
      height,
      padding: iconOnly ? 0 : (height >= 44 ? '0 18px' : '0 14px'),
      borderRadius: iconOnly ? height / 2 : 14,
      background: p.bg, color: p.fg,
      border: p.border, boxShadow: p.shadow,
      transform: p.transform || 'none',
      fontFamily: "'Geist', sans-serif",
      fontSize: height >= 44 ? 16 : (height >= 36 ? 14 : 12.5),
      fontWeight: 600, letterSpacing: -0.15,
      transition: 'transform .12s ease',
    }}>
      {showRing && <span className="sn-btn-ring"/>}
      {!showRing && leading}
      {!iconOnly && children}
      {!showRing && trailing}
    </div>
  );
}

// ─── Section helper ─────────────────────────────────────────────────
function BSection({ title, subtitle, children }) {
  return (
    <div style={{ marginBottom: 26 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: 12 }}>
        <div style={{
          fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase',
          color: 'var(--sn-text-3)',
        }}>{title}</div>
        {subtitle && (
          <div style={{ fontSize: 11, fontWeight: 500, color: 'var(--sn-text-4)', letterSpacing: -0.05 }}>{subtitle}</div>
        )}
      </div>
      {children}
    </div>
  );
}

// State column header
function StateLabel({ children }) {
  return (
    <div style={{
      fontSize: 10, fontWeight: 600, letterSpacing: 0.4, textTransform: 'uppercase',
      color: 'var(--sn-text-3)',
      marginBottom: 8, paddingLeft: 2,
    }}>{children}</div>
  );
}

// Variant row header
function VariantLabel({ children, hint }) {
  return (
    <div style={{
      fontSize: 11, fontWeight: 600, color: 'var(--sn-text-2)', letterSpacing: -0.05,
      width: 88, flexShrink: 0,
      display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 2,
    }}>
      {children}
      {hint && <div style={{ fontSize: 9.5, fontWeight: 500, color: 'var(--sn-text-3)', letterSpacing: 0 }}>{hint}</div>}
    </div>
  );
}

// ─── Card ───────────────────────────────────────────────────────────
function SinhronButtonStates({ dark = false }) {
  const variants = ['primary', 'secondary', 'ghost', 'danger'];
  const states = ['default', 'pressed', 'disabled', 'loading'];

  // Sample icon — paper-plane / send
  const sendIcon = (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
      <path d="M3 12l18-9-7 18-3-7-8-2z" fill="currentColor"/>
    </svg>
  );

  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      background: 'var(--sn-bg)',
      padding: '28px 26px',
      boxSizing: 'border-box', overflow: 'auto',
    }}>
      <style dangerouslySetInnerHTML={{ __html: BTN_STYLE }}/>

      {/* Title */}
      <div style={{
        display: 'flex', alignItems: 'baseline', gap: 12,
        paddingBottom: 18,
        borderBottom: '0.5px solid var(--sn-divider)',
        marginBottom: 22,
      }}>
        <div style={{ fontSize: 22, fontWeight: 600, letterSpacing: -0.4, color: 'var(--sn-text)' }}>Buttons</div>
        <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)' }}>
          4 variants · 4 states · pill 14r · 50h default
        </div>
      </div>

      {/* MAIN MATRIX — variant × state */}
      <BSection title="Variants × States" subtitle="50h pill · 16/600 label · color-mix on pressed">
        {/* Column headers */}
        <div style={{ display: 'flex', gap: 12, alignItems: 'flex-end', paddingLeft: 88 + 12 }}>
          {states.map(s => (
            <div key={s} style={{ flex: 1 }}>
              <StateLabel>{s}</StateLabel>
            </div>
          ))}
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {variants.map(v => (
            <div key={v} style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
              <VariantLabel hint={
                v === 'primary' ? 'accent fill' :
                v === 'secondary' ? 'soft surface' :
                v === 'ghost' ? 'transparent' :
                'red fill'
              }>{v}</VariantLabel>
              {states.map(s => (
                <div key={s} style={{ flex: 1, minWidth: 0 }}>
                  <SpecButton variant={v} state={s}>
                    {v === 'primary'   ? 'Send' :
                     v === 'secondary' ? 'Cancel' :
                     v === 'ghost'     ? 'Skip' :
                                         'Delete'}
                  </SpecButton>
                </div>
              ))}
            </div>
          ))}
        </div>
      </BSection>

      {/* SIZE SCALE — same primary, different heights */}
      <BSection title="Size scale" subtitle="36 · 42 · 50 · 60">
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <SpecButton variant="primary" height={36} full={false}>Small</SpecButton>
          <SpecButton variant="primary" height={42} full={false}>Medium</SpecButton>
          <SpecButton variant="primary" height={50} full={false}>Default</SpecButton>
          <SpecButton variant="primary" height={60} full={false}>Large</SpecButton>
        </div>
      </BSection>

      {/* WITH ICON — leading / trailing */}
      <BSection title="With icon" subtitle="leading · trailing · icon-only">
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          <SpecButton variant="primary" full={false} leading={sendIcon}>Send message</SpecButton>
          <SpecButton variant="secondary" full={false} trailing={
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none"><path d="M9 5l7 7-7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>
          }>Open settings</SpecButton>
          <SpecButton variant="ghost" full={false}>Learn more</SpecButton>
          <SpecButton variant="primary" full={false} iconOnly height={50}>
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path d="M3 12l18-9-7 18-3-7-8-2z" fill="currentColor"/>
            </svg>
          </SpecButton>
          <SpecButton variant="secondary" full={false} iconOnly height={50}>
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none" style={{ color: 'var(--sn-text)' }}>
              <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
            </svg>
          </SpecButton>
          <SpecButton variant="danger" full={false} iconOnly height={50}>
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
              <path d="M3 6h18M8 6V4a1 1 0 011-1h6a1 1 0 011 1v2M6 6l1 14a1 1 0 001 1h8a1 1 0 001-1l1-14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          </SpecButton>
        </div>
      </BSection>

      {/* LIVE LOADING — to communicate that the spinner is animated, not a static SVG */}
      <BSection title="Loading">
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ flex: 1 }}><SpecButton variant="primary" state="loading">Sending…</SpecButton></div>
          <div style={{ flex: 1 }}><SpecButton variant="secondary" state="loading">Connecting…</SpecButton></div>
        </div>
      </BSection>

      {/* Notes */}
      <div style={{
        marginTop: 8, fontSize: 11.5, fontWeight: 500,
        color: 'var(--sn-text-3)', lineHeight: '17px', letterSpacing: -0.05,
      }}>
        Pressed darkens the fill by ~12% via color-mix; ghost flashes the accent-soft fill instead. Disabled drops to bg-soft + text-4. Loading swaps the leading slot for a 16px ring and keeps the label, so the user knows what's happening.
      </div>
    </div>
  );
}

Object.assign(window, { SinhronButtonStates });
