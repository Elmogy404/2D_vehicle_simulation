// Admin-only user management business logic (trainers, admins, and overview).
const prisma = require("../db");
const bcrypt = require("bcrypt");
const t = require("../locales/ar");
const { NotFoundError, ForbiddenError, ConflictError } = require("../errors");
const { buildValidationError } = require("../validators/helpers");
const { BCRYPT_ROUNDS } = require("./authService");

function assertAdmin(user) {
  if (!user || user.role !== "ADMIN") throw new ForbiddenError(t.errors.forbidden);
}

async function list(actor, { search = "", role, page = 1, pageSize = 10 } = {}) {
  assertAdmin(actor);
  const q = String(search || "").trim();
  const where = {
    AND: [
      role ? { role } : {},
      q
        ? {
            OR: [{ name: { contains: q, mode: "insensitive" } }, { email: { contains: q, mode: "insensitive" } }],
          }
        : {},
    ],
  };
  const [total, users] = await Promise.all([
    prisma.user.count({ where }),
    prisma.user.findMany({
      where,
      select: { id: true, name: true, email: true, role: true, createdAt: true },
      orderBy: { createdAt: "desc" },
      skip: (page - 1) * pageSize,
      take: pageSize,
    }),
  ]);
  return { items: users, total, page, pageSize, pageCount: Math.max(1, Math.ceil(total / pageSize)) };
}

async function getById(actor, id) {
  assertAdmin(actor);
  const user = await prisma.user.findUnique({
    where: { id },
    select: { id: true, name: true, email: true, role: true, createdAt: true },
  });
  if (!user) throw new NotFoundError();
  return user;
}

async function create(actor, { name, email, password, role }) {
  assertAdmin(actor);
  const normalised = String(email).toLowerCase().trim();
  const existing = await prisma.user.findUnique({ where: { email: normalised } });
  if (existing) {
    throw buildValidationError({ email: [t.validation.emailExists] }, t.users.messages.emailExists);
  }
  const passwordHash = await bcrypt.hash(String(password), BCRYPT_ROUNDS);
  return prisma.user.create({
    data: { name: String(name).trim(), email: normalised, passwordHash, role },
    select: { id: true, name: true, email: true, role: true, createdAt: true },
  });
}

async function update(actor, id, { name, email, password }) {
  assertAdmin(actor);
  const data = { name: String(name).trim() };
  const normalised = String(email).toLowerCase().trim();
  const other = await prisma.user.findUnique({ where: { email: normalised } });
  if (other && other.id !== id) {
    throw buildValidationError({ email: [t.validation.emailExists] }, t.users.messages.emailExists);
  }
  data.email = normalised;
  if (password && String(password).length > 0) {
    data.passwordHash = await bcrypt.hash(String(password), BCRYPT_ROUNDS);
  }
  return prisma.user.update({
    where: { id },
    data,
    select: { id: true, name: true, email: true, role: true, createdAt: true },
  });
}

async function remove(actor, id) {
  assertAdmin(actor);
  if (actor.id === id) throw new ForbiddenError(t.users.messages.selfDelete);
  const exists = await prisma.user.findUnique({ where: { id } });
  if (!exists) throw new NotFoundError();
  try {
    await prisma.user.delete({ where: { id } });
  } catch (err) {
    // FK restrict: referenced by courses/attendance-markedBy, etc.
    if (err && err.code === "P2003") {
      throw new ConflictError(t.users.messages.referenced);
    }
    throw err;
  }
}

module.exports = { list, getById, create, update, remove };
