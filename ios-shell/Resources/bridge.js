/*
 * BitChord iOS shim, injected at document start.
 *
 * 1. Answers the page's extension bridge (protocol v1, "relay" transport) so the
 *    web app believes a companion extension is installed. yt.fetch and
 *    lyrics.fetch are served by native code; everything else is declined.
 * 2. Routes the page's own fetch() calls to YouTube / googlevideo through native
 *    HTTP, which adds the Origin/Referer headers the extension's DNR rules added
 *    and is not subject to CORS.
 */
(() => {
  if (window.__bcShim) return;
  window.__bcShim = true;

  const CH = 'bitchord-bridge';
  const PROTO = 1;
  const UA = navigator.userAgent;
  const nativeCall = (payload) => window.webkit.messageHandlers.bc.postMessage(payload);

  const LYRIC_HOSTS = [
    'lrc.red', 'lyrics-api.binimum.org', 'lyrics-api.boidu.dev', 'unison.boidu.dev',
    'lyrics.paxsenix.org', 'api.paxsenix.org', 'lyricsplus.prjktla.my.id',
    'lyricsplus.atomix.one', 'lyricsplus.binimum.org', 'lyricsplus.prjktla.workers.dev',
    'lyricsplus-seven.vercel.app', 'lyrics-plus-backend.vercel.app', 'lrclib.net',
    'mobileservice.kugou.com', 'lyrics.kugou.com', 'apic.musixmatch.com',
    'www.musixmatch.com', 'genius.com', 'music.apple.com', 'amp-api.music.apple.com',
  ];
  const lyricOrigins = LYRIC_HOSTS.map((h) => 'https://' + h);

  // ---- base64 helpers ---------------------------------------------------------
  const toB64 = (u8) => {
    let s = '';
    for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  };
  const fromB64 = (b64) => {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  };
  const textToB64 = (t) => toB64(new TextEncoder().encode(t));

  // ---- 1. fetch() to YouTube goes through native HTTP ---------------------------
  const YT_HOST = /(^|\.)(youtube\.com|googlevideo\.com)$/i;
  const originalFetch = window.fetch.bind(window);

  window.fetch = async function (input, init) {
    let req;
    let url;
    try {
      req = new Request(input, init);
      url = new URL(req.url);
    } catch (_) {
      return originalFetch(input, init);
    }
    if (!/^https?:$/.test(url.protocol) || !YT_HOST.test(url.hostname)) return originalFetch(input, init);

    if (req.signal && req.signal.aborted) throw new DOMException('Aborted', 'AbortError');

    const headers = {};
    req.headers.forEach((v, k) => { headers[k] = v; });
    if (!headers['user-agent']) headers['user-agent'] = UA;
    if (!headers['accept-language']) headers['accept-language'] = navigator.language || 'en-US';

    const method = req.method.toUpperCase();
    const body = method === 'GET' || method === 'HEAD' ? null : toB64(new Uint8Array(await req.arrayBuffer()));

    const call = nativeCall({ mode: 'page', url: req.url, method, headers, body });
    const aborted = new Promise((_, reject) => {
      if (req.signal) req.signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
    });

    let reply;
    try {
      reply = await Promise.race([call, aborted]);
    } catch (e) {
      if (e && e.name === 'AbortError') throw e;
      throw new TypeError('Failed to fetch');
    }

    const nullBody = [101, 204, 205, 304].includes(reply.status);
    const res = new Response(nullBody ? null : fromB64(reply.body), {
      status: reply.status,
      statusText: '',
      headers: reply.headers,
    });
    try { Object.defineProperty(res, 'url', { value: reply.url }); } catch (_) {}
    return res;
  };

  // ---- 2. extension bridge (relay transport) -------------------------------------
  const signedOutYt = { browserSignedIn: false, connected: false, signedIn: false, accounts: [], active: null, problem: null };
  const signedOutSpotify = { browserSignedIn: false, connected: false, signedIn: false, user: null, problem: null };
  const discordOff = { available: false, connected: false, enabled: false, user: null, gateway: 'off', problem: null };

  const httpParams = (p) => ({
    url: p.url,
    method: p.method || 'GET',
    headers: p.headers || {},
    body: p.body == null ? null : p.bodyEncoding === 'base64' ? p.body : textToB64(p.body),
  });

  async function handle(method, params) {
    switch (method) {
      case 'ping':
        return { version: '1.0.0-ios', protocol: PROTO, browser: 'chromium', capabilities: ['yt', 'lyrics'] };
      case 'yt.fetch':
        if (params.auth) throw Object.assign(new Error('Signing in is not available in the iOS app.'), { code: 'unauthenticated' });
        return nativeCall({ mode: 'yt', ...httpParams(params) });
      case 'yt.authState':
      case 'yt.selectChannel':
      case 'yt.setConnected':
        return signedOutYt;
      case 'lyrics.fetch':
        return nativeCall({ mode: 'lyrics', ...httpParams(params) });
      case 'lyrics.permissions':
        return { granted: (params.origins || []).filter((o) => lyricOrigins.includes(o)) };
      case 'lyrics.requestPermissions':
        return {};
      case 'spotify.authState':
      case 'spotify.setConnected':
        return signedOutSpotify;
      case 'discord.state':
      case 'discord.disconnect':
      case 'discord.setEnabled':
        return discordOff;
      case 'discord.presence':
        return {};
      default:
        throw Object.assign(new Error(method + " isn't available in the iOS app."), { code: 'unsupported' });
    }
  }

  window.addEventListener('message', async (event) => {
    if (event.source !== window) return;
    const d = event.data;
    if (!d || d.channel !== CH || d.direction !== 'to-extension' || typeof d.id !== 'string') return;

    const base = { channel: CH, protocol: PROTO, direction: 'to-page', id: d.id };
    if (d.protocol !== PROTO) {
      window.postMessage({ ...base, ok: false, error: { code: 'protocol', message: 'Bridge protocol mismatch.' } }, '*');
      return;
    }
    try {
      const result = await handle(d.method, d.params || {});
      window.postMessage({ ...base, ok: true, result }, '*');
    } catch (e) {
      const known = e && e.code;
      const code = ['unsupported', 'forbidden', 'unauthenticated', 'permission'].includes(known) ? known : 'network';
      window.postMessage({ ...base, ok: false, error: { code, message: String((e && e.message) || e) } }, '*');
    }
  });
})();
