// Jest global teardown: closes any Prisma clients opened by helpers.
module.exports = async function globalTeardown() {
  try {
    const prisma = require("./prismaShared");
    if (prisma && typeof prisma.$disconnect === "function") {
      await prisma.$disconnect();
    }
  } catch (e) {
    // ignore
  }
};
