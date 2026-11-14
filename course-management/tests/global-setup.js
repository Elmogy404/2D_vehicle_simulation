// Jest global setup: applies schema migrations to the TEST database once per run.
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

function loadEnvFile() {
  const envPath = path.join(__dirname, "..", ".env");
  if (fs.existsSync(envPath)) {
    for (const line of fs.readFileSync(envPath, "utf8").split(/\r?\n/)) {
      const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
      if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2];
    }
  }
}

module.exports = async function globalSetup() {
  loadEnvFile();
  const databaseUrl = process.env.TEST_DATABASE_URL;
  const directUrl = process.env.TEST_DIRECT_URL || databaseUrl;
  if (!databaseUrl) {
    throw new Error("TEST_DATABASE_URL is not set (copy .env.example to .env and fill it).");
  }
  console.log("[global-setup] applying migrations to the test database...");
  execSync("npx prisma migrate deploy", {
    cwd: path.join(__dirname, ".."),
    stdio: "inherit",
    env: { ...process.env, DATABASE_URL: databaseUrl, DIRECT_URL: directUrl, NODE_ENV: "test" },
  });
  console.log("[global-setup] test database ready.");
};
