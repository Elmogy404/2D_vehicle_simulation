// Centralised, fail-fast environment configuration.
// Reads .env (development) / process env; validates required variables at require time.
const fs = require("fs");
const path = require("path");

// Load .env only when running outside jest (tests inject their own env in tests/setup.env.js)
if (!process.env.JEST_WORKER_ID) {
  const envPath = path.join(process.cwd(), ".env");
  if (fs.existsSync(envPath)) {
    require("dotenv").config({ path: envPath });
  }
}

const required = (name) => {
  const value = process.env[name];
  if (!value || !value.trim()) {
    console.error(`[config] Missing required environment variable: ${name}`);
    console.error("[config] Copy .env.example to .env and fill the values, then retry.");
    process.exit(1);
  }
  return value;
};

const env = {
  nodeEnv: process.env.NODE_ENV || "development",
  port: Number(process.env.PORT || 3000),
  sessionSecret: process.env.SESSION_SECRET,
  csrfSecret: process.env.CSRF_SECRET || process.env.SESSION_SECRET,
  databaseUrl: process.env.DATABASE_URL,
  directUrl: process.env.DIRECT_URL,
  testDatabaseUrl: process.env.TEST_DATABASE_URL,
  testDirectUrl: process.env.TEST_DIRECT_URL,
  loginRateLimitMax: Number(process.env.LOGIN_RATE_LIMIT_MAX || 10),
  loginRateLimitWindowMs: Number(process.env.LOGIN_RATE_LIMIT_WINDOW_MS || 15 * 60 * 1000),
  pageSize: Number(process.env.PAGE_SIZE || 6),
};

if (env.nodeEnv === "test") env.sessionSecret = env.sessionSecret || "test-session-secret";

required("DATABASE_URL");
required("SESSION_SECRET");
if (env.nodeEnv === "test") required("TEST_DATABASE_URL");

env.isProduction = env.nodeEnv === "production";
env.isTest = env.nodeEnv === "test";

// The database actually in use (test DB during the test run).
env.activeDatabaseUrl = env.isTest && env.testDatabaseUrl ? env.testDatabaseUrl : env.databaseUrl;

module.exports = env;
