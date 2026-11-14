// Course business logic. All ownership/authorisation checked here too (not only in routes).
const prisma = require("../db");
const t = require("../locales/ar");
const { NotFoundError, ForbiddenError, ConflictError } = require("../errors");

async function listAll({ page = 1, pageSize = 6 }) {
  const [total, courses] = await Promise.all([
    prisma.course.count(),
    prisma.course.findMany({
      include: { trainer: { select: { name: true } }, _count: { select: { bookings: true, sessions: true } } },
      orderBy: { createdAt: "desc" },
      skip: (page - 1) * pageSize,
      take: pageSize,
    }),
  ]);
  return { items: courses, total, page, pageSize, pageCount: Math.max(1, Math.ceil(total / pageSize)) };
}

async function listOwnCourses(trainerId, { page = 1, pageSize = 6 }) {
  const where = { trainerId };
  const [total, courses] = await Promise.all([
    prisma.course.count({ where }),
    prisma.course.findMany({
      where,
      include: { trainer: { select: { name: true } }, _count: { select: { bookings: true, sessions: true } } },
      orderBy: { createdAt: "desc" },
      skip: (page - 1) * pageSize,
      take: pageSize,
    }),
  ]);
  return { items: courses, total, page, pageSize, pageCount: Math.max(1, Math.ceil(total / pageSize)) };
}

// Note: partial IDOR camouflage - missing vs foreign both result in 404 for restricted viewers.
async function getForCoursePage(currentUser, courseId) {
  const course = await prisma.course.findUnique({
    where: { id: courseId },
    include: { trainer: { select: { name: true, email: true } }, _count: { select: { bookings: true, sessions: true } } },
  });
  if (!course) throw new NotFoundError();
  if (currentUser.role === "TRAINEE") {
    return course;
  }
  if (currentUser.role === "ADMIN") {
    return course;
  }
  if (currentUser.role === "TRAINER") {
    if (course.trainerId !== currentUser.id) throw new NotFoundError();
    return course;
  }
  throw new ForbiddenError(t.errors.forbidden);
}

async function getByIdForEdit(currentUser, courseId) {
  if (currentUser.role !== "ADMIN") throw new ForbiddenError(t.errors.forbidden);
  const course = await prisma.course.findUnique({ where: { id: courseId } });
  if (!course) throw new NotFoundError();
  return course;
}

async function create(admin, input) {
  if (!admin || admin.role !== "ADMIN") throw new ForbiddenError(t.errors.forbidden);
  // re-check the trainer role in service (defence in depth)
  const trainer = await prisma.user.findUnique({ where: { id: input.trainerId }, select: { id: true, role: true } });
  if (!trainer || trainer.role !== "TRAINER") {
    throw new ForbiddenError(t.validation.selectTrainer);
  }
  const course = prisma.course.create({
    data: {
      title: input.title,
      description: input.description,
      price: input.price,
      trainerId: input.trainerId,
    },
  });
  return course;
}

async function update(admin, courseId, input) {
  const course = await getByIdForEdit(admin, courseId);
  const trainer = await prisma.user.findUnique({ where: { id: input.trainerId }, select: { id: true, role: true } });
  if (!trainer || trainer.role !== "TRAINER") {
    throw new ForbiddenError(t.validation.selectTrainer);
  }
  return prisma.course.update({
    where: { id: course.id },
    data: {
      title: input.title,
      description: input.description,
      price: input.price,
      trainerId: input.trainerId,
    },
  });
}

// Course deletion is safe+documented: blocked while bookings exist (any status);
// otherwise cascading removes sessions and their attendance rows only.
async function remove(admin, courseId) {
  const course = await getByIdForEdit(admin, courseId);
  const bookings = await prisma.booking.count({ where: { courseId } });
  if (bookings > 0) {
    throw new ConflictError(t.courses.messages.deleteBlocked);
  }
  return prisma.course.delete({ where: { id: course.id } });
}

module.exports = { listAll, listOwnCourses, getForCoursePage, getByIdForEdit, create, update, remove };
