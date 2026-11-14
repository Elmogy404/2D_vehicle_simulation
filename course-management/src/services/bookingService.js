// Booking business logic (trainees book/cancel; admins confirm/cancel). Ownership checked here.
const prisma = require("../db");
const t = require("../locales/ar");
const { NotFoundError, ForbiddenError, ConflictError } = require("../errors");

const LIST_PAGE_SIZE = 8;

// status transitions:
//   PENDING    -> CONFIRMED (admin)
//   PENDING    -> CANCELLED (admin, or the owning trainee)
//   CONFIRMED  -> CANCELLED (admin only)
//   CANCELLED  -> final (no changes); a trainee may "re-book" -> resets to PENDING
async function create(trainee, courseId) {
  if (trainee.role !== "TRAINEE") throw new ForbiddenError(t.errors.forbidden);
  const course = await prisma.course.findUnique({ where: { id: courseId }, include: { trainer: { select: { name: true } } } });
  if (!course) throw new NotFoundError();

  const existing = await prisma.booking.findUnique({
    where: { courseId_traineeId: { courseId, traineeId: trainee.id } },
  });
  if (existing && existing.status !== "CANCELLED") {
    // duplicate booking (PENDING or CONFIRMED already exists)
    throw new ConflictError(t.bookings.messages.duplicate);
  }
  const booking = await prisma.booking.upsert({
    where: { courseId_traineeId: { courseId, traineeId: trainee.id } },
    update: { status: "PENDING", createdAt: new Date() }, // reactivate a cancelled booking
    create: { courseId, traineeId: trainee.id, status: "PENDING" },
    include: { course: { include: { trainer: { select: { name: true } } } } },
  });
  return booking;
}

async function getOwned(id, traineeId) {
  const booking = await prisma.booking.findUnique({
    where: { id },
    include: { course: true },
  });
  if (!booking || booking.traineeId !== traineeId) throw new NotFoundError();
  return booking;
}

async function confirm(admin, bookingId) {
  if (admin.role !== "ADMIN") throw new ForbiddenError(t.errors.forbidden);
  const booking = await prisma.booking.findUnique({ where: { id: bookingId } });
  if (!booking) throw new NotFoundError();
  if (booking.status === "CONFIRMED") return booking; // idempotent
  if (booking.status === "CANCELLED") throw new ConflictError(t.bookings.messages.cancelledNoChange);
  return prisma.booking.update({ where: { id: bookingId }, data: { status: "CONFIRMED" } });
}

async function cancel(user, bookingId) {
  const booking = await prisma.booking.findUnique({ where: { id: bookingId }, include: { course: true } });
  if (!booking) throw new NotFoundError();
  if (user.role === "ADMIN") {
    if (booking.status === "CANCELLED") return booking; // idempotent
    return prisma.booking.update({ where: { id: bookingId }, data: { status: "CANCELLED" } });
  }
  if (user.role === "TRAINEE") {
    if (booking.traineeId !== user.id) throw new NotFoundError(); // IDOR camouflage
    if (booking.status !== "PENDING") {
      throw new ForbiddenError(t.errors.forbidden);
    }
    return prisma.booking.update({ where: { id: bookingId }, data: { status: "CANCELLED" } });
  }
  throw new ForbiddenError(t.errors.forbidden);
}

async function listForTrainee(traineeId, { page = 1, pageSize = LIST_PAGE_SIZE } = {}) {
  const where = { traineeId };
  const [total, bookings] = await Promise.all([
    prisma.booking.count({ where }),
    prisma.booking.findMany({
      where,
      include: { course: { include: { trainer: { select: { name: true } } } } },
      orderBy: { createdAt: "desc" },
      skip: (page - 1) * pageSize,
      take: pageSize,
    }),
  ]);
  return { items: bookings, total, page, pageSize, pageCount: Math.max(1, Math.ceil(total / pageSize)) };
}

async function listForAdmin({ courseId, status, page = 1, pageSize = LIST_PAGE_SIZE } = {}) {
  const where = {
    ...(courseId ? { courseId } : {}),
    ...(status ? { status } : {}),
  };
  const [total, bookings] = await Promise.all([
    prisma.booking.count({ where }),
    prisma.booking.findMany({
      where,
      include: {
      course: { include: { trainer: { select: { name: true } } } },
      trainee: { select: { name: true, email: true } },
    },
      orderBy: { createdAt: "desc" },
      skip: (page - 1) * pageSize,
      take: pageSize,
    }),
  ]);
  return { items: bookings, total, page, pageSize, pageCount: Math.max(1, Math.ceil(total / pageSize)) };
}

module.exports = { create, confirm, cancel, listForTrainee, listForAdmin };
