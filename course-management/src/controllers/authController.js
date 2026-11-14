// Auth controller: login / register / logout.
const authService = require("../services/authService");
const { parse, schemas } = require("../validators");
const t = require("../locales/ar");

function safeNext(target) {
  return typeof target === "string" && target.startsWith("/") && !target.startsWith("//") ? target : "/dashboard";
}

function renderLogin(res, { status = 200, fieldErrors = {}, values = {} } = {}) {
  res.status(status).render("auth/login", {
    title: t.auth.loginTitle,
    fieldErrors,
    values,
    formError: (fieldErrors && fieldErrors._form && fieldErrors._form[0]) || null,
    loggedOut: null,
  });
}

function renderRegister(res, { status = 200, fieldErrors = {}, values = {} } = {}) {
  res.status(status).render("auth/register", {
    title: t.auth.registerTitle,
    fieldErrors,
    values,
    formError: (fieldErrors && fieldErrors._form && fieldErrors._form[0]) || null,
  });
}

const getLogin = (req, res) => {
  if (req.currentUser) return res.redirect("/dashboard");
  renderLogin(res, {});
};

const postLogin = (loginLimiter) => [
  loginLimiter,
  async (req, res, next) => {
    try {
      let data;
      try {
        data = parse(schemas.login, req.body);
      } catch (err) {
        if (err.fieldErrors) {
          return renderLogin(res, { status: 422, fieldErrors: err.fieldErrors, values: { email: req.body.email } });
        }
        throw err;
      }

      let user;
      try {
        user = await authService.login(data);
      } catch (err) {
        // auth failure -> same generic message (no user enumeration)
        return renderLogin(res, {
          status: 401,
          fieldErrors: { _form: [t.auth.loginFailed] },
          values: { email: data.email },
        });
      }

      // rotate the session at privilege elevation, then record the user
      await new Promise((resolve) => req.session.regenerate(() => resolve()));
      const target = req.session.next ? req.session.next : "/dashboard";
      delete req.session.next;
      req.session.userId = user.id;
      req.flash("success", `${t.auth.welcome}: ${user.name}`);
      return res.redirect(safeNext(target));
    } catch (err) {
      return next(err);
    }
  },
];

const getRegister = (req, res) => {
  if (req.currentUser) return res.redirect("/dashboard");
  renderRegister(res, {});
};

const postRegister = (registerLimiter) => [
  registerLimiter,
  async (req, res, next) => {
    try {
      let data;
      try {
        data = parse(schemas.register, req.body);
        if (data.password !== data.confirmPassword) {
          const err = new Error("Validation failed");
          err.fieldErrors = { confirmPassword: [t.validation.passwordMismatch] };
          throw err;
        }
      } catch (err) {
        if (err.fieldErrors) {
          return renderRegister(res, {
            status: 422,
            fieldErrors: err.fieldErrors,
            values: { name: req.body.name, email: req.body.email },
          });
        }
        throw err;
      }

      const user = await authService.register(data);
      await new Promise((resolve) => req.session.regenerate(() => resolve()));
      req.session.userId = user.id;
      req.flash("success", t.auth.registered);
      return res.redirect("/dashboard");
    } catch (err) {
      if (err && err.fieldErrors) {
        return renderRegister(res, {
          status: 422,
          fieldErrors: err.fieldErrors,
          values: { name: req.body.name, email: req.body.email },
        });
      }
      return next(err);
    }
  },
];

const postLogout = (req, res, next) => {
  res.clearCookie("course.sid");
  req.session.destroy(() => {
    res.redirect("/login?loggedout=1");
  });
};

module.exports = { getLogin, postLogin, getRegister, postRegister, postLogout };
