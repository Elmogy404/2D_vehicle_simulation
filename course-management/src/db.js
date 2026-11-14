// Prisma client singleton. Uses the test database automatically during jest runs.
// DATABASE_URL in .env may be a pooled URL (e.g. Neon pgbouncer); migrations use
// DIRECT_URL via the environment override in npm scripts.
const { PrismaClient } = require("@prisma/client");
const config = require("./config");

const prisma = new PrismaClient({
  datasourceUrl: config.activeDatabaseUrl,
  log: config.isTest ? ["error"] : ["error", "warn"],
});

module.exports = prisma;
