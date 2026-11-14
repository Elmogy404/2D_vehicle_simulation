// Single source of truth for the "current" DB connection in services.
// In the test run, Prisma must point at the test database.
const config = require("../config");

module.exports = config;
