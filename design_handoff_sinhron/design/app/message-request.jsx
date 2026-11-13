// message-request.jsx — Inbound message from a non-contact (sealed sender)
// One screen with two states (controlled via prop `state`):
//   • 'request'  — the request is open; CTAs (Accept / Block / Delete)
//   • 'verified' — same chat after Accept (composer enabled, banner gone)
//
// The visual hierarchy is the trickiest design moment in the whole product:
// the user receives crypto-verified ciphertext from someone they don't know.
// We don't let them reply until they decide. The first message bubble is
// rendered DIMMED with a "tap to reveal" affordance so a malicious first
// message can't be used to flash content on screen during preview swipes.
//
// Exports: SnMessageRequest, SnMessageRequestAccepted

function MrHeader({ name }) {
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
      <SnAvatar name={name} size={36}/>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 15, fontWeight: 600, letterSpacing: -0.2, color: 'var(--sn-text)' }}>{name}</div>
        <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)' }}>Message request</div>
      </div>
      <div style={{ width: 36, height: 36, color: 'var(--sn-text-3)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
          <circle cx="6" cy="12" r="1.7" fill="currentColor"/>
          <circle cx="12" cy="12" r="1.7" fill="currentColor"/>
          <circle cx="18" cy="12" r="1.7" fill="currentColor"/>
        </svg>
      </div>
    </div>
  );
}

// Profile card at top — what we know (and admit we don't)
function MrProfile({ name }) {
  return (
    <div style={{
      display: 'flex', flexDirection: 'column', alignItems: 'center',
      padding: '24px 24px 18px', gap: 10,
    }}>
      <SnAvatar name={name} size={84}/>
      <div style={{ fontSize: 22, fontWeight: 600, letterSpacing: -0.4, color: 'var(--sn-text)' }}>{name}</div>
      <div className="sn-mono" style={{
        fontSize: 13, fontWeight: 500, color: 'var(--sn-text-3)', letterSpacing: 0,
      }}>@mariachen · cabin.sinhron.app</div>

      <div style={{
        marginTop: 6, padding: '6px 12px 6px 10px',
        borderRadius: 999, background: 'var(--sn-bg-soft)',
        display: 'inline-flex', alignItems: 'center', gap: 6,
        fontSize: 12, fontWeight: 500, color: 'var(--sn-text-2)', letterSpacing: -0.05,
      }}>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
          <path d="M12 3l9 4v6c0 5-4 9-9 10-5-1-9-5-9-10V7l9-4z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round"/>
        </svg>
        Not in your contacts
      </div>
    </div>
  );
}

// "What you can do" card — explains why this screen exists
function MrExplain() {
  return (
    <div style={{
      margin: '0 14px 18px',
      padding: '14px 16px',
      background: 'var(--sn-surface)',
      borderRadius: 14,
      boxShadow: '0 0 0 0.5px var(--sn-divider)',
    }}>
      <div style={{ display: 'flex', gap: 12, alignItems: 'flex-start' }}>
        <div style={{
          width: 28, height: 28, borderRadius: 9,
          background: 'var(--sn-accent-soft)', color: 'var(--sn-accent)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0,
        }}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
            <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
            <path d="M12 11v6M12 7.5v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
          </svg>
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 14, fontWeight: 600, color: 'var(--sn-text)', letterSpacing: -0.1, marginBottom: 4 }}>You haven't messaged before</div>
          <div style={{ fontSize: 13, fontWeight: 500, color: 'var(--sn-text-2)', lineHeight: '18px', letterSpacing: -0.05 }}>
            They got your username from the directory on <span className="sn-mono" style={{ fontSize: 12, color: 'var(--sn-text)' }}>cabin.sinhron.app</span>. Accept to start chatting, or delete without notifying them.
          </div>
        </div>
      </div>
    </div>
  );
}

// "First message" — dimmed, with a tap-to-reveal target
function MrPreviewBubble({ revealed }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'flex-start', padding: '4px 12px' }}>
      <div style={{
        maxWidth: '78%',
        background: 'var(--sn-surface)', color: 'var(--sn-text)',
        borderRadius: '18px 18px 18px 6px',
        padding: '10px 14px',
        position: 'relative',
        boxShadow: '0 1px 1px rgba(15,23,32,0.05)',
        fontSize: 15, lineHeight: '20px', letterSpacing: -0.15,
        filter: revealed ? 'none' : 'blur(5px)',
      }}>
        Hey — got your handle from the dir. I'm Maria, work with Henry. Wanted to chat about the design proposal.
        <div style={{ display: 'inline-flex', float: 'right', marginLeft: 8, marginTop: 4, marginBottom: -2, fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)' }}>09:14</div>
      </div>
    </div>
  );
}

// ════════════════════════════════════════════════════════════════════
// 1. Message request — pending decision
// ════════════════════════════════════════════════════════════════════
function SnMessageRequest({ dark = false, platform = 'ios' }) {
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      display: 'flex', flexDirection: 'column',
      background: 'var(--sn-bg)',
      position: 'relative', overflow: 'hidden',
    }}>
      <MrHeader name="Maria Chen"/>

      <div className="sn-scroll" style={{ flex: 1 }}>
        <MrProfile name="Maria Chen"/>
        <MrExplain/>

        {/* The preview itself */}
        <div style={{
          padding: '0 4px 12px',
          fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase',
          color: 'var(--sn-text-3)', textAlign: 'center',
        }}>First message</div>
        <MrPreviewBubble revealed={false}/>
        <div style={{ display: 'flex', justifyContent: 'center', padding: '6px 0 14px' }}>
          <div style={{
            display: 'inline-flex', alignItems: 'center', gap: 6,
            padding: '5px 12px', borderRadius: 999,
            background: 'var(--sn-bg-soft)', color: 'var(--sn-text-2)',
            fontSize: 12, fontWeight: 600, letterSpacing: -0.05,
          }}>
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none">
              <path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/>
              <circle cx="12" cy="12" r="3" stroke="currentColor" strokeWidth="1.8"/>
            </svg>
            Tap to reveal
          </div>
        </div>
      </div>

      {/* Action bar — replaces the composer until decided */}
      <div style={{
        padding: '12px 14px 16px',
        borderTop: '0.5px solid var(--sn-divider)',
        background: 'var(--sn-bg)',
        display: 'flex', flexDirection: 'column', gap: 10,
      }}>
        <div style={{ display: 'flex', gap: 10 }}>
          <DsButton variant="secondary" leading={
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/>
              <path d="M5.5 5.5l13 13" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>
            </svg>
          }>Block</DsButton>
          <DsButton variant="secondary" leading={
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
              <path d="M3 6h18M8 6V4a1 1 0 011-1h6a1 1 0 011 1v2M6 6l1 14a1 1 0 001 1h8a1 1 0 001-1l1-14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
            </svg>
          }>Delete</DsButton>
        </div>
        <DsButton variant="primary" leading={
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
            <path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        }>Accept · start chatting</DsButton>
        <div style={{
          fontSize: 11, fontWeight: 500, color: 'var(--sn-text-3)',
          textAlign: 'center', letterSpacing: -0.05, lineHeight: '16px',
        }}>
          Deleting doesn't notify Maria. Blocking hides any further messages from her on this server.
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SnMessageRequest });
