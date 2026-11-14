// Loaded via jest "setupFiles" before any test module imports src code.
// Injects development secrets from .env into process.env (tests use the TEST database).
const fs = require("fs");
const path = require("path");

process.env.NODE_ENV = "test";

const envPath = path.join(__dirname, "..", ".env");
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m && process.env[m[1]] === undefined) {
      process.env[m[1]] = m[2];
    }
  }
}

process.env.TEST_DATABASE_URL =
  process.env.TEST_DATABASE_URL || "postgresql://postgres:postgres@localhost:5432/courses_test";
process.env.DATABASE_URL = process.env.DATABASE_URL || process.env.TEST_DATABASE_URL;
if (!process.env.SESSION_SECRET) process.env.SESSION_SECRET = "test-session-secret";
if (!process.env.CSRF_SECRET) process.env.CSRF_SECRET = "test-csrf-secret";
