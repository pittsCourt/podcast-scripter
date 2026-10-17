// auth.js
// Two ways in, both optional:
//  - NOTES_USER / NOTES_PASSWORD: HTTP Basic login for people in a browser.
//    Safari and other browsers show their own login prompt and can save it.
//  - NOTES_TOKEN: a bearer token for the Mac app and the iPhone Shortcut.
// Either one is accepted on every route. With neither set, everything is open.

const crypto = require('crypto');

const OPEN_PATHS = new Set(['/api/health', '/favicon.svg']);

/** Constant-time string comparison (hashing first makes the lengths equal). */
function safeEqual(a, b) {
  const hash = (s) => crypto.createHash('sha256').update(String(s)).digest();
  return crypto.timingSafeEqual(hash(a), hash(b));
}

function parseBasic(header) {
  const match = header.match(/^Basic\s+(.+)$/i);
  if (!match) return null;
  const decoded = Buffer.from(match[1], 'base64').toString('utf8');
  const colon = decoded.indexOf(':');
  if (colon === -1) return null;
  return { user: decoded.slice(0, colon), password: decoded.slice(colon + 1) };
}

function createAuth({ token, user, password }) {
  const loginEnabled = !!(user && password);
  const enabled = !!token || loginEnabled;

  function middleware(req, res, next) {
    if (!enabled || OPEN_PATHS.has(req.path)) return next();
    // With only a token configured, the page itself is public; its API calls aren't.
    if (!loginEnabled && !req.path.startsWith('/api/')) return next();

    const header = req.get('authorization') || '';

    if (token) {
      const supplied = header.replace(/^Bearer\s+/i, '') || req.get('x-notes-token') || req.query.token;
      if (supplied && !/^Basic\s/i.test(supplied) && safeEqual(supplied, token)) return next();
    }

    if (loginEnabled) {
      const creds = parseBasic(header);
      // Evaluate both comparisons so timing doesn't reveal which part was wrong.
      if (creds && safeEqual(creds.user, user) & safeEqual(creds.password, password)) return next();
      res.set('WWW-Authenticate', 'Basic realm="Newsdesk", charset="UTF-8"');
    }

    if (req.path.startsWith('/api/')) {
      if (req.query.reply === 'text') {
        return res.status(401).type('text').send('Couldn’t add it: the token is missing or wrong. Check the token in the Shortcut’s URL.');
      }
      return res.status(401).json({ error: loginEnabled ? 'Log in required.' : 'Missing or wrong token.' });
    }
    res.status(401).type('text').send('Log in required.');
  }

  return { middleware, enabled, loginEnabled, tokenEnabled: !!token };
}

module.exports = { createAuth };
