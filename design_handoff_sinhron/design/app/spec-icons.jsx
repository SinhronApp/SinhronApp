// spec-icons.jsx — Full Sinhron icon set in one grid with labels
// All icons drawn at 24×24 viewBox, 1.8 stroke. Some flow icons (mic, etc) use
// filled glyphs — those are noted with a • dot before the name.
//
// Exports: SinhronIconSet

// ─── Atomic icon component (SVG body passed as JSX) ─────────────────
function IconBody({ children, size = 22 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      {children}
    </svg>
  );
}

// ─── The full set, grouped by usage ─────────────────────────────────
const ICON_GROUPS = [
  {
    title: 'Navigation',
    icons: [
      ['chats',     <><path d="M4 6.5C4 5.12 5.12 4 6.5 4h11A2.5 2.5 0 0120 6.5v8a2.5 2.5 0 01-2.5 2.5H10l-4 3.5V17H6.5A2.5 2.5 0 014 14.5v-8z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></>],
      ['calls',     <><path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></>],
      ['contacts',  <><circle cx="12" cy="8" r="4" stroke="currentColor" strokeWidth="1.8"/><path d="M4 21c0-4 3.6-7 8-7s8 3 8 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['settings',  <><path d="M4 7h11M4 12h16M9 17h11" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><circle cx="17" cy="7" r="2.2" stroke="currentColor" strokeWidth="1.8"/><circle cx="6" cy="12" r="2.2" stroke="currentColor" strokeWidth="1.8"/><circle cx="14" cy="17" r="2.2" stroke="currentColor" strokeWidth="1.8"/></>],
      ['back',      <><path d="M15 5l-7 7 7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['forward',   <><path d="M9 5l7 7-7 7" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['close',     <><path d="M5 5l14 14M19 5L5 19" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></>],
      ['more',      <><circle cx="6" cy="12" r="1.7" fill="currentColor"/><circle cx="12" cy="12" r="1.7" fill="currentColor"/><circle cx="18" cy="12" r="1.7" fill="currentColor"/></>],
    ],
  },
  {
    title: 'Chat actions',
    icons: [
      ['compose',   <><path d="M16.5 3.5l4 4-12 12H4.5v-4l12-12z" stroke="currentColor" strokeWidth="1.9" strokeLinejoin="round"/><path d="M13.5 6.5l4 4" stroke="currentColor" strokeWidth="1.9"/></>],
      ['reply',     <><path d="M9 17l-6-6 6-6M3 11h11a6 6 0 016 6v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['forward·',  <><path d="M15 7l6 6-6 6M21 13H10a6 6 0 00-6 6v1" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['copy',      <><rect x="9" y="3" width="13" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/><path d="M5 7v12a2 2 0 002 2h11" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['star',      <><path d="M12 3.5l2.7 5.5 6 .8-4.4 4.2 1.1 6L12 17.2l-5.4 2.8 1.1-6L3.3 9.8l6-.8L12 3.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></>],
      ['pin',       <><path d="M12 2l4 4-1.5 1.5L17 10l-4 4-2.5-2.5L4 18v2h2l6.5-6.5L15 16l4-4-2.5-2.5L18 8l-4-4z" fill="currentColor"/></>],
      ['info',      <><circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/><path d="M12 11v6M12 7.5v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></>],
      ['delete',    <><path d="M3 6h18M8 6V4a1 1 0 011-1h6a1 1 0 011 1v2M6 6l1 14a1 1 0 001 1h8a1 1 0 001-1l1-14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['archive',   <><rect x="2.5" y="4" width="19" height="5" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><path d="M4 9v10a1 1 0 001 1h14a1 1 0 001-1V9" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M9.5 13h5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['mark-read', <><path d="M3 7l4.5 4.5L13 6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/><path d="M11 13l4.5 4.5L21 12" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['select',    <><rect x="4" y="4" width="16" height="16" rx="3" stroke="currentColor" strokeWidth="1.8"/><path d="M8 12l3 3 5-6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['search',    <><circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/><path d="M16.5 16.5L21 21" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
    ],
  },
  {
    title: 'Composer & media',
    icons: [
      ['plus',      <><path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></>],
      ['attach',    <><path d="M9 14V7a4 4 0 018 0v9a6 6 0 11-12 0V9" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['camera',    <><rect x="3" y="6" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/><circle cx="12" cy="13" r="4" stroke="currentColor" strokeWidth="1.8"/><path d="M8 6l1.5-2.5h5L16 6" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></>],
      ['gallery',   <><rect x="3" y="5" width="18" height="14" rx="2" stroke="currentColor" strokeWidth="1.8"/><circle cx="9" cy="11" r="2" stroke="currentColor" strokeWidth="1.8"/><path d="M3 17l5-4 4 3 3-2 6 5" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></>],
      ['mic',       <><rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="1.8" fill="currentColor"/><path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['mic-off',   <><rect x="9" y="2.5" width="6" height="12" rx="3" stroke="currentColor" strokeWidth="1.8"/><path d="M5 11a7 7 0 0014 0M12 18v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"/></>],
      ['video',     <><rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="1.8"/><path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></>],
      ['video-off', <><rect x="2.5" y="6" width="13" height="12" rx="2.5" stroke="currentColor" strokeWidth="1.8"/><path d="M15.5 10l5-2.5v9l-5-2.5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"/></>],
      ['file',      <><path d="M14 3H6.5A1.5 1.5 0 005 4.5v15A1.5 1.5 0 006.5 21h11A1.5 1.5 0 0019 19.5V8l-5-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><path d="M14 3v5h5" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></>],
      ['location',  <><path d="M12 22s-7-6.5-7-12a7 7 0 1114 0c0 5.5-7 12-7 12z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><circle cx="12" cy="10" r="2.5" stroke="currentColor" strokeWidth="1.8"/></>],
      ['sticker',   <><path d="M3 12a9 9 0 0114-7.5L21 9v3a9 9 0 11-18 0z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><circle cx="9" cy="11" r="1" fill="currentColor"/><circle cx="15" cy="11" r="1" fill="currentColor"/><path d="M9 15c.5 1 1.6 1.7 3 1.7s2.5-.7 3-1.7" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></>],
      ['emoji',     <><circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/><circle cx="9" cy="10" r="1.1" fill="currentColor"/><circle cx="15" cy="10" r="1.1" fill="currentColor"/><path d="M8.5 14c.7 1 1.9 1.7 3.5 1.7s2.8-.7 3.5-1.7" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></>],
      ['send',      <><path d="M3 12l18-9-7 18-3-7-8-2z" fill="currentColor"/></>],
      ['scheduled', <><circle cx="12" cy="13" r="8" stroke="currentColor" strokeWidth="1.8"/><path d="M12 9v4l3 2M8 3l-2 3M16 3l2 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
    ],
  },
  {
    title: 'Calls',
    icons: [
      ['accept',    <><path d="M22 16.92v3a2 2 0 01-2.18 2 19.79 19.79 0 01-8.63-3.07 19.5 19.5 0 01-6-6 19.79 19.79 0 01-3.07-8.67A2 2 0 014.11 2h3a2 2 0 012 1.72c.13.96.36 1.9.7 2.81a2 2 0 01-.45 2.11L8.09 9.91a16 16 0 006 6l1.27-1.27a2 2 0 012.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0122 16.92z" fill="currentColor"/></>],
      ['decline',   <><path d="M3 12c0-2 5-5 9-5s9 3 9 5l-2 2-3-1-1-2c-2-1-4-1-6 0l-1 2-3 1-2-2z" fill="currentColor"/></>],
      ['speaker',   <><path d="M11 5L6 9H3v6h3l5 4V5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><path d="M16 9a4 4 0 010 6M19 6a8 8 0 010 12" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['flip',      <><path d="M3 9a4 4 0 014-4h10l-3-3M21 15a4 4 0 01-4 4H7l3 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['grid',      <><rect x="3" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="14" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="3" y="14" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="14" y="14" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/></>],
      ['raise-hand', <><path d="M9 3v9M12 2v10M15 3v9M18 6v8a6 6 0 01-12 0v-2l-2-3 2-2 2 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['add-user',  <><circle cx="11" cy="9" r="4" stroke="currentColor" strokeWidth="1.8"/><path d="M3 21c0-4 3.2-7 7-7s7 3 7 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M19 6v6M16 9h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['minimise',  <><path d="M4 16L8 12 4 8M20 16l-4-4 4-4M8 12h12" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></>],
    ],
  },
  {
    title: 'Status & receipts',
    icons: [
      ['check',     <><path d="M5 12l5 5L20 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['check·2',   <><path d="M2 12l5 5L15 7M11 12l5 5L23 8" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['clock',     <><circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/><path d="M12 7v5l3.5 2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['mute',      <><path d="M12 4a5 5 0 015 5v4l2 3H5l2-3V9a5 5 0 015-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><path d="M3 3l18 18" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></>],
      ['bell',      <><path d="M12 4a5 5 0 015 5v4l2 3H5l2-3V9a5 5 0 015-5z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><path d="M10 20a2 2 0 004 0" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['typing',    <><circle cx="6" cy="12" r="1.5" fill="currentColor"/><circle cx="12" cy="12" r="1.5" fill="currentColor"/><circle cx="18" cy="12" r="1.5" fill="currentColor"/></>],
      ['voice-wave', <><path d="M2 12h2M6 8v8M10 5v14M14 8v8M18 10v4M22 12h-2" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></>],
      ['play',      <><path d="M6 4l14 8-14 8V4z" fill="currentColor"/></>],
      ['pause',     <><rect x="6" y="4" width="4" height="16" rx="1" fill="currentColor"/><rect x="14" y="4" width="4" height="16" rx="1" fill="currentColor"/></>],
      ['warning',   <><path d="M12 3l10 18H2L12 3z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><path d="M12 10v5M12 18v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></>],
      ['error',     <><circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/><path d="M12 7v6M12 16v.5" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></>],
      ['refresh',   <><path d="M21 5v6h-6M3 19v-6h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/><path d="M19 11a8 8 0 00-14-3M5 13a8 8 0 0014 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['mention',   <><circle cx="12" cy="12" r="4" stroke="currentColor" strokeWidth="1.8"/><path d="M16 12v2.5a2.5 2.5 0 005 0V12a9 9 0 10-3.5 7.1" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['typing-3',  <><rect x="3" y="10" width="3" height="4" rx="1.5" fill="currentColor"/><rect x="10" y="10" width="3" height="4" rx="1.5" fill="currentColor"/><rect x="17" y="10" width="3" height="4" rx="1.5" fill="currentColor"/></>],
    ],
  },
  {
    title: 'Identity & security',
    icons: [
      ['key',       <><circle cx="8" cy="14" r="4" stroke="currentColor" strokeWidth="1.8"/><path d="M11 11l9-9 2 2-2 2 2 2-2 2-2-2-3 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['shield',    <><path d="M12 3l9 4v6c0 5-4 9-9 10-5-1-9-5-9-10V7l9-4z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/></>],
      ['shield·ok', <><path d="M12 3l9 4v6c0 5-4 9-9 10-5-1-9-5-9-10V7l9-4z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><path d="M8 12l3 3 5-6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></>],
      ['fingerpr.', <><path d="M12 2a10 10 0 00-10 10M12 2a10 10 0 0110 10M6 14c0 5 3 8 6 8s6-3 6-8a6 6 0 10-12 0M10 14a2 2 0 014 0v3" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></>],
      ['qr',        <><rect x="3" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="14" y="3" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="3" y="14" width="7" height="7" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><path d="M14 14h3v3h-3zM17 17h4v4h-4z" stroke="currentColor" strokeWidth="1.8"/></>],
      ['scan',      <><path d="M3 8V5a2 2 0 012-2h3M21 8V5a2 2 0 00-2-2h-3M3 16v3a2 2 0 002 2h3M21 16v3a2 2 0 01-2 2h-3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M3 12h18" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['eye',       <><path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><circle cx="12" cy="12" r="3" stroke="currentColor" strokeWidth="1.8"/></>],
      ['eye-off',   <><path d="M2 12s4-7 10-7c2 0 3.7.6 5.2 1.5M22 12s-4 7-10 7c-2 0-3.7-.6-5.2-1.5" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" strokeLinecap="round"/><circle cx="12" cy="12" r="3" stroke="currentColor" strokeWidth="1.8"/><path d="M3 3l18 18" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"/></>],
      ['lock',      <><rect x="5" y="11" width="14" height="10" rx="2" stroke="currentColor" strokeWidth="1.8"/><path d="M8 11V8a4 4 0 018 0v3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['unlock',    <><rect x="5" y="11" width="14" height="10" rx="2" stroke="currentColor" strokeWidth="1.8"/><path d="M8 11V8a4 4 0 017-2.6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['devices',   <><rect x="2.5" y="5" width="13" height="11" rx="2" stroke="currentColor" strokeWidth="1.8"/><rect x="14" y="9" width="7.5" height="12" rx="1.8" stroke="currentColor" strokeWidth="1.8"/></>],
      ['server',    <><rect x="3" y="4" width="18" height="6" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="3" y="14" width="18" height="6" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><circle cx="7" cy="7" r="1" fill="currentColor"/><circle cx="7" cy="17" r="1" fill="currentColor"/></>],
      ['link',      <><path d="M10 14a4 4 0 005.66 0l3-3a4 4 0 10-5.66-5.66L11.5 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M14 10a4 4 0 00-5.66 0l-3 3a4 4 0 105.66 5.66L12.5 17" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
    ],
  },
  {
    title: 'Profile & people',
    icons: [
      ['user',      <><circle cx="12" cy="8" r="4" stroke="currentColor" strokeWidth="1.8"/><path d="M4 21c0-4 3.6-7 8-7s8 3 8 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['group',     <><circle cx="9" cy="9" r="3.5" stroke="currentColor" strokeWidth="1.8"/><circle cx="16.5" cy="9.5" r="2.7" stroke="currentColor" strokeWidth="1.8"/><path d="M3 18.5c0-3 2.7-5.2 6-5.2s6 2.2 6 5.2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M14.5 18c.4-1.6 1.7-2.9 3.5-3.4 2.4-.6 3.5 1.1 3.5 3.4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['user-plus', <><circle cx="11" cy="9" r="4" stroke="currentColor" strokeWidth="1.8"/><path d="M3 21c0-4 3.2-7 7-7s7 3 7 7" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M19 6v6M16 9h6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['block',     <><circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/><path d="M5.5 5.5l13 13" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></>],
      ['edit',      <><path d="M16.5 3.5l4 4-12 12H4.5v-4l12-12z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><path d="M13.5 6.5l4 4" stroke="currentColor" strokeWidth="1.8"/></>],
      ['share',     <><circle cx="6" cy="12" r="3" stroke="currentColor" strokeWidth="1.8"/><circle cx="18" cy="6" r="3" stroke="currentColor" strokeWidth="1.8"/><circle cx="18" cy="18" r="3" stroke="currentColor" strokeWidth="1.8"/><path d="M9 11l6-3M9 13l6 3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></>],
      ['palette',   <><path d="M12 3a9 9 0 100 18c1.5 0 2-1.5 1-2.5s-.5-2.5 1-2.5h2a5 5 0 005-5A8 8 0 0012 3z" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round"/><circle cx="7" cy="11" r="1.2" fill="currentColor"/><circle cx="10" cy="7" r="1.2" fill="currentColor"/><circle cx="15" cy="7" r="1.2" fill="currentColor"/></>],
      ['language',  <><circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8"/><path d="M3 12h18M12 3a13 13 0 010 18M12 3a13 13 0 000 18" stroke="currentColor" strokeWidth="1.8"/></>],
    ],
  },
];

// ─── The card ───────────────────────────────────────────────────────
function SinhronIconSet({ dark = false }) {
  const total = ICON_GROUPS.reduce((n, g) => n + g.icons.length, 0);
  return (
    <div className={`sn-app ${dark ? 'sn-theme-dark' : 'sn-theme-light'}`} style={{
      width: '100%', height: '100%',
      background: 'var(--sn-bg)',
      padding: '28px 28px 28px',
      boxSizing: 'border-box', overflow: 'auto',
    }}>
      {/* Title */}
      <div style={{
        display: 'flex', alignItems: 'baseline', gap: 12,
        paddingBottom: 18,
        borderBottom: '0.5px solid var(--sn-divider)',
        marginBottom: 22,
      }}>
        <div style={{ fontSize: 22, fontWeight: 600, letterSpacing: -0.4, color: 'var(--sn-text)' }}>Iconography</div>
        <div style={{ fontSize: 12, fontWeight: 500, color: 'var(--sn-text-3)', letterSpacing: -0.05 }}>
          {total} glyphs · 24×24 · 1.8px stroke · currentColor
        </div>
      </div>

      {/* Groups */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
        {ICON_GROUPS.map(g => (
          <div key={g.title}>
            <div style={{
              fontSize: 11, fontWeight: 700, letterSpacing: 0.6, textTransform: 'uppercase',
              color: 'var(--sn-text-3)', marginBottom: 10,
            }}>{g.title} · {g.icons.length}</div>
            <div style={{
              display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)',
              gap: 8,
            }}>
              {g.icons.map(([name, body]) => (
                <div key={name} style={{
                  display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8,
                  padding: '14px 6px',
                  background: 'var(--sn-surface)',
                  borderRadius: 12,
                  boxShadow: '0 0 0 0.5px var(--sn-divider)',
                }}>
                  <div style={{ color: 'var(--sn-text)' }}>
                    <IconBody>{body}</IconBody>
                  </div>
                  <div className="sn-mono" style={{
                    fontSize: 10, fontWeight: 500, letterSpacing: -0.05,
                    color: 'var(--sn-text-3)',
                    whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                    maxWidth: '100%',
                  }}>{name}</div>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>

      {/* Footnote */}
      <div style={{
        marginTop: 24, fontSize: 11.5, fontWeight: 500,
        color: 'var(--sn-text-3)', lineHeight: '17px', letterSpacing: -0.05,
      }}>
        Glyphs use <span className="sn-mono">currentColor</span> so they inherit from the row / button text. Filled glyphs (send, pin, accept) reinforce action; outlined glyphs (mostly everything else) sit calmly inside the chrome.
      </div>
    </div>
  );
}

Object.assign(window, { SinhronIconSet });
