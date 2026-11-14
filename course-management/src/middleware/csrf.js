// CSRF protection using csrf-csrf (maintained replacement for the deprecated csurf).
// Double-submit cookie pattern: token in cookie + token in the form field (_csrf).
// A stable session identifier is bound into the token (synchronises token/secret with the v4 API).
const { doubleCsrf } = require("csrf-csrf");
const config = require("../config");
const t = require("../locales/ar");

const { doubleCsrfProtection, generateCsrfToken } = doubleCsrf({
  getSecret: () => config.csrfSecret || config.sessionSecret,
  getSessionIdentifier: (req) => (req.session ? String(req.session.id) : "no-session"),
  cookieName: config.isProduction ? "__Host-csrf_token" : "csrf_token",
  cookieOptions: {
    sameSite: "strict",
    path: "/",
    secure: config.isProduction,
    httpOnly: true,
  },
  size: 64,
  ignoredMethods: ["GET", "HEAD", "OPTIONS"],
  getCsrfTokenFromRequest: (req) => {
    if (!req.body || typeof req.body !== "object") return undefined;
    const value = req.body._csrf;
    return typeof value === "string" ? value : undefined;
  },
  errorConfig: {
    statusCode: 403,
    message: t.errors.forbidden,
    code: "EBADCSRFTOKEN",
  },
});

module.exports = { doubleCsrfProtection, generateCsrfToken };
