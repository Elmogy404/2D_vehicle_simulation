// Authentication business logic: registration (TRAINEE only), login, password hashing.
// Password hashes are never returned or logged.
const bcrypt = require("bcrypt");
const prisma = require("../db");
const t = require("../locales/ar");
const { NotFoundError } = require("../errors");
const { buildValidationError } = require("../validators/helpers");

const BCRYPT_ROUNDS = 12;

async function register(input) {
  const email = String(input.email).toLowerCase().trim();
  const existing = await prisma.user.findUnique({ where: { email } });
  if (existing) {
    throw buildValidationError({
      email: [t.validation.emailExists],
      message: t.users.messages.emailExists,
    });
  }
  const passwordHash = await bcrypt.hash(String(input.password), BCRYPT_ROUNDS);
  const user = await prisma.user.create({
    data: { name: String(input.name).trim(), email, passwordHash, role: "TRAINEE" },
    select: { id: true, name: true, email: true, role: true, createdAt: true },
  });
  return user;
}

async function login(input) {
  const email = String(input.email).toLowerCase().trim();
  const user = await prisma.user.findUnique({ where: { email } });
  if (!user) {
    throw new NotFoundError(t.auth.loginFailed); // message doubles as auth failure text
  }
  const ok = await bcrypt.compare(String(input.password), user.passwordHash);
  if (!ok) {
    throw new NotFoundError(t.auth.loginFailed);
  }
  // never expose the hash
  return { id: user.id, name: user.name, email: user.email, role: user.role };
}

async function findUserById(id) {
  const user = await prisma.user.findUnique({ where: { id } });
  if (!user) throw new NotFoundError();
  return { id: user.id, name: user.name, email: user.email, role: user.role };
}

module.exports = { register, login, findUserById, BCRYPT_ROUNDS };
