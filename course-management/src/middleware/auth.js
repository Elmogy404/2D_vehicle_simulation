// RBAC middleware.
// 403 for authorised-but-wrong-role, redirects to /login when not authenticated.
const { ForbiddenError } = require("../errors");
const t = require("../locales/ar");

function requireAuth(req, res, next) {
  if (!req.currentUser) {
    if (req.method === "GET") {
      if (req.session) req.session.next = req.originalUrl || "/";
      return res.redirect("/login");
    }
    return res.redirect("/login");
  }
  return next();
}

function requireRole(...roles) {
  return (req, res, next) => {
    if (!req.currentUser) {
      if (req.method === "GET") {
        if (req.session) req.session.next = req.originalUrl || "/";
        return res.redirect("/login");
      }
      return res.redirect("/login");
    }
    if (!roles.includes(req.currentUser.role)) {
      return next(new ForbiddenError(t.errors.forbidden));
    }
    return next();
  };
}

module.exports = { requireAuth, requireRole };
