// HTTP entry point.
const { createApp } = require("./app");
const config = require("./config");
const prisma = require("./db");

const app = createApp();
const server = app.listen(config.port, () => {
  console.log(`[server] ${config.nodeEnv} app listening on http://localhost:${config.port}`);
});

async function shutdown(signal) {
  console.log(`[server] ${signal} received, shutting down...`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
  await prisma.$disconnect().catch(() => {});
  const pool = app.get("pgPool");
  if (pool) await pool.end().catch(() => {});
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
