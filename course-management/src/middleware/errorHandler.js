// Centralised error + not-found handling. Detailed logs on the server only,
// friendly Arabic error pages in the response. No stack traces in production.
const config = require("../config");
const t = require("../locales/ar");
const { AppError } = require("../errors");

function notFound(req, res, next) {
  if (req.method === "GET" || req.method === "HEAD") {
    return res.status(404).render("errors/404", { title: t.errors.notFoundTitle, t, currentUser: req.currentUser ?? null, csrfToken: res.locals.csrfToken });
  }
  return next(new AppError(t.errors.notFound, 404));
}

// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  const status = err && err.status ? err.status : 500;
  const isAppError = err instanceof AppError;

  // Server-side detailed log (never leaks into the response in production)
  console.error(`[error] ${req.method} ${req.originalUrl} -> ${status}`, {
    name: err && err.name,
    message: err && err.message,
    stack: err && err.stack,
  });

  if (res.headersSent) return next(err);

  // form validation errors: reload page with field errors if the request opts in
  if (err && err.name === "ValidationError") {
    if (req.accepts(["html", "json"]) === "json") {
      return res.status(422).json({ errors: err.fieldErrors });
    }
    return res.status(422).redirect("back");
  }

  const statusLabel = status === 403 ? "forbidden" : status === 404 ? "notFound" : "server";
  const userMessage = isAppError && err.show ? err.message : t.errors.server;

  if (req.accepts(["html", "json"]) === "json") {
    return res.status(status).json({ error: userMessage });
  }

  return res.status(status).render("errors/error", {
    title: t.errors.title,
    heading: t.errors[statusLabel] === undefined ? t.errors.serverTitle : t.errors[statusLabel + "Title"],
    message: userMessage,
    t,
    currentUser: req.currentUser ?? null,
    csrfToken: res.locals.csrfToken,
  });
}

module.exports = { notFound, errorHandler };
