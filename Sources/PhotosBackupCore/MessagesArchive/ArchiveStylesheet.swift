extension ArchiveHTML {
    /// Shared by every page; the colours are Messages' own, light and dark.
    static let stylesheet = """
    :root {
      color-scheme: light dark;
      --bg: #ffffff;
      --surface: #f5f5f7;
      --text: #1d1d1f;
      --secondary: #6e6e73;
      --hairline: rgba(0, 0, 0, 0.1);
      --them: #e9e9eb;
      --them-text: #1d1d1f;
      --imessage: #0a84ff;
      --sms: #30d158;
      --chip: rgba(0, 0, 0, 0.05);
      --avatar-top: #a8adb8;
      --avatar-bottom: #868b96;
      --badge: #e9e9eb;
      --link-me: #ffffff;
      --accent: #0a7aff;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1c1c1e;
        --surface: #2c2c2e;
        --text: #f5f5f7;
        --secondary: #98989d;
        --hairline: rgba(255, 255, 255, 0.12);
        --them: #3a3a3c;
        --them-text: #f5f5f7;
        --chip: rgba(255, 255, 255, 0.08);
        --avatar-top: #6c6f76;
        --avatar-bottom: #4f5258;
        --badge: #3a3a3c;
        --accent: #0a84ff;
      }
    }
    * { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 15px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    a { color: var(--accent); }
    footer { color: var(--secondary); font-size: 12px; text-align: center; padding: 32px 16px 48px; }

    .avatar {
      flex: none; width: 40px; height: 40px; border-radius: 50%;
      display: inline-flex; align-items: center; justify-content: center;
      background: linear-gradient(180deg, var(--avatar-top), var(--avatar-bottom));
      color: #fff; font-weight: 600; font-size: 15px; letter-spacing: 0.02em;
    }

    /* Root index */
    .hero { max-width: 760px; margin: 0 auto; padding: 48px 20px 16px; }
    .hero h1 { font-size: 30px; font-weight: 700; margin: 0 0 6px; letter-spacing: -0.01em; }
    .hero p { margin: 0; color: var(--secondary); }
    .conversations { list-style: none; margin: 8px auto 0; padding: 0 12px; max-width: 760px; }
    .conversations li a {
      display: flex; gap: 12px; align-items: center; padding: 10px 10px; border-radius: 12px;
      color: inherit; text-decoration: none;
    }
    .conversations li a:hover { background: var(--surface); }
    .conversations li + li .info { border-top: 1px solid var(--hairline); }
    .conversations .info { flex: 1; min-width: 0; padding: 8px 0; margin: -10px 0; }
    .conversations .line { display: flex; justify-content: space-between; gap: 12px; align-items: baseline; }
    .conversations strong { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .conversations time, .conversations .sub { color: var(--secondary); font-size: 13px; white-space: nowrap; }
    .conversations .sub { display: flex; justify-content: space-between; gap: 12px; margin-top: 2px; }
    .conversations .sub span:first-child { overflow: hidden; text-overflow: ellipsis; }

    /* Conversation */
    .topbar {
      position: sticky; top: 0; z-index: 2;
      background: color-mix(in srgb, var(--bg) 82%, transparent);
      -webkit-backdrop-filter: saturate(180%) blur(20px); backdrop-filter: saturate(180%) blur(20px);
      border-bottom: 1px solid var(--hairline);
      padding: 10px 16px 12px;
    }
    .topbar .back { font-size: 14px; text-decoration: none; }
    .topbar .who { display: flex; flex-direction: column; align-items: center; gap: 6px; margin-top: 2px; text-align: center; }
    .topbar .who > div { min-width: 0; max-width: 100%; }
    .topbar h1 { font-size: 15px; font-weight: 600; margin: 0; }
    .topbar p { margin: 2px 0 0; font-size: 12px; color: var(--secondary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .transcript { max-width: 760px; margin: 0 auto; padding: 8px 16px 24px; display: flex; flex-direction: column; }
    .day, .gap { text-align: center; color: var(--secondary); font-size: 11px; font-weight: 600; margin: 20px 0 8px; }
    .gap { font-weight: 500; margin-top: 14px; }
    .event { text-align: center; color: var(--secondary); font-size: 12px; margin: 10px 32px; }
    .event time { display: none; }
    .event:hover time { display: inline; margin-left: 6px; }

    .msg { display: flex; flex-direction: column; max-width: 72%; margin-top: 8px; }
    .msg.cont { margin-top: 2px; }
    .msg.me { align-self: flex-end; align-items: flex-end; }
    .msg.them { align-self: flex-start; align-items: flex-start; }
    .sender { font-size: 11px; color: var(--secondary); margin: 0 12px 2px; }
    .stack { position: relative; display: flex; flex-direction: column; gap: 2px; align-items: inherit; max-width: 100%; }
    .bubble {
      padding: 7px 12px 8px; border-radius: 18px; white-space: pre-wrap; overflow-wrap: anywhere;
      max-width: 100%; font-size: 15px;
    }
    .them .bubble { background: var(--them); color: var(--them-text); }
    .me.imessage .bubble { background: var(--imessage); color: #fff; }
    .me.sms .bubble { background: var(--sms); color: #fff; }
    .me .bubble a { color: var(--link-me); }
    .bubble.note { font-style: italic; opacity: 0.75; }
    .bubble.audio { padding: 6px 8px; }
    .bubble.audio audio { display: block; height: 32px; }
    .media { display: block; border-radius: 16px; overflow: hidden; max-width: min(320px, 100%); line-height: 0; }
    .media img, video.media { display: block; max-width: 100%; max-height: 360px; object-fit: cover; border-radius: 16px; }
    .media.sticker { border-radius: 0; max-width: 140px; }
    .media.sticker img { border-radius: 0; }
    .chip {
      display: inline-flex; flex-direction: column; gap: 1px; padding: 8px 12px; border-radius: 14px;
      background: var(--chip); color: inherit; text-decoration: none; max-width: 100%;
      border: 1px solid var(--hairline);
    }
    .chip .name { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .chip .why { font-size: 11px; color: var(--secondary); }
    .chip.off { opacity: 0.8; }
    .reply {
      display: block; font-size: 12px; color: var(--secondary); text-decoration: none; margin: 0 4px 3px;
      padding: 4px 10px; border-left: 2px solid var(--hairline); max-width: 100%;
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    }
    .reply .who { font-weight: 600; margin-right: 6px; }
    .tapbacks {
      position: absolute; top: -20px; display: flex; gap: 2px;
      background: var(--badge); border: 2px solid var(--bg); border-radius: 14px; padding: 2px 6px;
      font-size: 13px; line-height: 18px;
    }
    .them .tapbacks { right: -16px; }
    .me .tapbacks { left: -16px; }
    .msg:has(.tapbacks) { margin-top: 22px; }
    .meta { font-size: 11px; color: var(--secondary); margin: 3px 10px 0; min-height: 0; }
    .meta time { display: none; }
    .msg:hover .meta time { display: inline; }
    .flag { font-weight: 500; }
    .flag + .flag::before, .msg:hover .meta time + .flag::before { content: " \\00B7  "; font-weight: 400; }
    .meta:not(:has(.flag)) { margin: 0; }
    .msg:hover .meta:not(:has(.flag)) { margin: 3px 10px 0; }
    .history { font-size: 12px; color: var(--secondary); margin: 2px 10px 0; max-width: 100%; }
    .history summary { cursor: pointer; }
    .history p { margin: 4px 0 0; white-space: pre-wrap; overflow-wrap: anywhere; }
    .event .history { text-align: center; }
    @media (max-width: 560px) { .msg { max-width: 86%; } }
    @media print { .topbar { position: static; } .meta time { display: inline; } }
    """
}
