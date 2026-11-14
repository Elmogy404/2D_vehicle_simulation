// Express application factory (no listen) - reusable by tests via supertest.
const path = require("path");
const express = require("express");
const helmet = require("helmet");
const methodOverride = require("method-override");
const cookieParser = require("cookie-parser");
const session = require("express-session");
const connectPgSimple = require("connect-pg-simple");
const flash = require("connect-flash");
const rateLimit = require("express-rate-limit");
const { Pool } = require("pg");

const config = require("./config");
const t = require("./locales/ar");
const { doubleCsrfProtection, generateCsrfToken } = require("./middleware/csrf");
const authContext = require("./middleware/authContext");
const { notFound, errorHandler } = require("./middleware/errorHandler");

const authRoutes = require("./routes/auth.routes");
const dashboardRoutes = require("./routes/dashboard.routes");
const userRoutes = require("./routes/user.routes");
const courseRoutes = require("./routes/course.routes");
const bookingRoutes = require("./routes/booking.routes");
const attendanceRoutes = require("./routes/attendance.routes");

function createApp(overrides = {}) {
  const app = express();
  app.disable("x-powered-by");
  app.set("view engine", "ejs");
  app.set("views", path.join(__dirname, "views"));

  // static assets: own styles + vendored bootstrap
  app.use(express.static(path.join(__dirname, "..", "public")));
  app.use("/vendor/bootstrap", express.static(path.join(__dirname, "..", "node_modules", "bootstrap", "dist")));

  // security headers + CSP
  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          styleSrc: ["'self'", "https://cdn.jsdelivr.net", "'unsafe-inline'"],
          scriptSrc: ["'self'", "https://cdn.jsdelivr.net"],
          imgSrc: ["'self'", "data:"],
          fontSrc: ["'self'", "https://fonts.gstatic.com"],
          formAction: ["'self'"],
          // keep dev usable over plain HTTP; forces HTTPS in production
          upgradeInsecureRequests: config.isProduction ? [] : null,
        },
      },
    })
  );

  // body parsing + HTTP method override for HTML forms (PUT/DELETE via hidden _method)
  app.use(express.urlencoded({ extended: true }));
  app.use(express.json({ limit: "200kb" }));
  app.use(methodOverride("_method"));

  // session store in PostgreSQL (connect-pg-simple)
  const pool = new Pool({ connectionString: config.activeDatabaseUrl, max: config.nodeEnv === "test" ? 5 : 10 });
  app.set("pgPool", pool);
  const PgStore = connectPgSimple(session);
  app.use(
    session({
      store: new PgStore({ pool, createTableIfMissing: true, tableName: "user_sessions" }),
      name: "course.sid",
      secret: config.sessionSecret,
      resave: false,
      saveUninitialized: false,
      cookie: {
        httpOnly: true,
        sameSite: "lax",
        secure: config.isProduction,
        maxAge: 7 * 24 * 60 * 60 * 1000,
        path: "/",
      },
    })
  );

  app.use(cookieParser());
  app.use(flash());

  // shared locals for every view
  app.use((req, res, next) => {
    res.locals.t = t;
    res.locals.title = t.app.title;
    res.locals.currentUser = null;
    res.locals.url = req.originalUrl;
    res.locals.query = req.query;
    res.locals.messages = { success: req.flash("success"), error: req.flash("error") };
    next();
  });

  // rate limiting for auth submissions
  const rateLimitHandler = (req, res) => {
    req.flash("error", t.errors.rateLimited);
    return res.status(429).redirect(req.originalUrl.startsWith("/register") ? "/register" : "/login");
  };
  const loginLimiter = rateLimit({
    windowMs: overrides.loginRateLimitWindowMs ?? config.loginRateLimitWindowMs,
    limit: overrides.loginRateLimitMax ?? config.loginRateLimitMax,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    handler: rateLimitHandler,
  });
  const registerLimiter = rateLimit({
    windowMs: overrides.loginRateLimitWindowMs ?? config.loginRateLimitWindowMs,
    limit: overrides.loginRateLimitMax ?? config.loginRateLimitMax,
    standardHeaders: "draft-8",
    legacyHeaders: false,
    handler: rateLimitHandler,
  });

  // authenticated user context
  app.use(authContext);

  // CSRF protection (session + cookie-parser + body parser must precede this)
  app.use(doubleCsrfProtection);
  app.use((req, res, next) => {
    res.locals.csrfToken = req.csrfToken ? req.csrfToken() : generateCsrfToken(req, res);
    next();
  });

  // routes (mounting order matters little; each route carries its own role guards)
  app.use("/", authRoutes(loginLimiter, registerLimiter));
  app.use("/", dashboardRoutes);
  app.use("/users", userRoutes);
  app.use("/courses", courseRoutes);
  app.use("/bookings", bookingRoutes);
  app.use("/", attendanceRoutes);

  app.use(notFound);
  app.use(errorHandler);

  return app;
}

module.exports = { createApp };
