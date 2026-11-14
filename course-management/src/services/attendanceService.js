// Class sessions + attendance marking.
// Trainers may only touch their OWN courses (IDOR-safe, 404 on foreign resources).
// Admins have read-only access; marking is trainer-only.
const prisma = require("../db");
const t = require("../locales/ar");
const { NotFoundError, ForbiddenError, ConflictError } = require("../errors");

async function loadCourseForAdminOrOwnTrainer(user, courseId) {
  const course = await prisma.course.findUnique({ where: { id: courseId } });
  if (!course) throw new NotFoundError();
  if (user.role === "ADMIN") return course;
  if (user.role === "TRAINER" && course.trainerId === user.id) return course;
  throw new NotFoundError(); // camouflage existing-but-foreign courses
}

async function loadSessionForAdminOrOwnTrainer(user, sessionId) {
  const session = await prisma.session.findUnique({ where: { id: sessionId }, include: { course: true } });
  if (!session) throw new NotFoundError();
  if (user.role === "ADMIN") return session;
  if (user.role === "TRAINER" && session.course.trainerId === user.id) return session;
  throw new NotFoundError();
}

async function createSession(user, courseId, { date, title }) {
  const course = await loadCourseForAdminOrOwnTrainer(user, courseId);
  const session = await prisma.session.create({
    data: { courseId: course.id, date, title: title },
  });
  return session;
}

async function listForCourse(user, courseId) {
  const course = await loadCourseForAdminOrOwnTrainer(user, courseId);
  const sessions = await prisma.session.findMany({
    where: { courseId },
    orderBy: { date: "asc" },
    include: {
      attendance: { include: { trainee: { select: { id: true, name: true } } } },
    },
  });
  // sum present/absent per session
  return sessions.map((s) => ({
    ...s,
    presentCount: s.attendance.filter((a) => a.status === "PRESENT").length,
    absentCount: s.attendance.filter((a) => a.status === "ABSENT").length,
  }));
}

// Attendance sheet: admin read-only, trainer editable for own course.
async function getSessionForAttendance(user, sessionId) {
  const session = await loadSessionForAdminOrOwnTrainer(user, sessionId);
  const confirmed = await prisma.booking.findMany({
    where: { courseId: session.courseId, status: "CONFIRMED" },
    include: { trainee: { select: { id: true, name: true, email: true } } },
    orderBy: { traineeId: "asc" },
  });
  const existing = await prisma.attendance.findMany({ where: { sessionId } });
  const byTrainee = Object.fromEntries(existing.map((a) => [a.traineeId, a]));
  return {
    session,
    editable: user.role === "TRAINER",
    rows: confirmed.map((b) => ({
      trainee: b.trainee,
      attendance: byTrainee[b.trainee.id] || null,
    })),
  };
}

// Save marks: upsert per confirmed trainee. Marking is trainer-only (admin is read-only).
async function saveMarks(trainer, sessionId, traineeId, status) {
  if (!trainer || trainer.role !== "TRAINER") throw new ForbiddenError(t.errors.forbidden);
  if (!["PRESENT", "ABSENT"].includes(status) || !Number.isInteger(traineeId)) {
    throw new ForbiddenError(t.validation.selectAttendance);
  }
  const session = await loadSessionForAdminOrOwnTrainer(trainer, sessionId);
  if (session.course.trainerId !== trainer.id) throw new NotFoundError();
  const booking = await prisma.booking.findUnique({
    where: { courseId_traineeId: { courseId: session.courseId, traineeId } },
  });
  if (!booking || booking.status !== "CONFIRMED") {
    throw new ConflictError(t.attendance.messages.unconfirmed);
  }
  return prisma.attendance.upsert({
    where: { sessionId_traineeId: { sessionId, traineeId } },
    update: { status, markedById: trainer.id, updatedAt: new Date() },
    create: { sessionId, traineeId, status, markedById: trainer.id },
  });
}

// Trainee: own records only, grouped per course with present/absent summary.
async function getMyAttendance(traineeId) {
  const rows = await prisma.attendance.findMany({
    where: { traineeId },
    include: { session: { include: { course: { include: { trainer: { select: { name: true } } } } } } },
    orderBy: [{ session: { date: "desc" } }, { createdAt: "asc" }],
  });
  const byCourse = new Map();
  for (const row of rows) {
    const courseId = row.session.courseId;
    if (!byCourse.has(courseId)) {
      byCourse.set(courseId, {
        course: { id: row.session.course.id, title: row.session.course.title, trainer: row.session.course.trainer.name },
        sessions: [],
        present: 0,
        absent: 0,
      });
    }
    const entry = byCourse.get(courseId);
    entry.sessions.push({ sessionId: row.sessionId, date: row.session.date, status: row.status });
    if (row.status === "PRESENT") entry.present += 1;
    else entry.absent += 1;
  }
  return Array.from(byCourse.values());
}

// Admin: read-only overview for a course (each session + marks).
async function getCourseOverviewForAdmin(user, courseId) {
  if (user.role !== "ADMIN") throw new ForbiddenError(t.errors.forbidden);
  const course = await prisma.course.findUnique({ where: { id: courseId } });
  if (!course) throw new NotFoundError();
  const sessions = await prisma.session.findMany({
    where: { courseId },
    orderBy: { date: "asc" },
    include: { attendance: { include: { trainee: { select: { name: true } } } } },
  });
  return {
    course,
    sessions: sessions.map((s) => ({
      id: s.id,
      date: s.date,
      title: s.title,
      present: s.attendance.filter((a) => a.status === "PRESENT").length,
      absent: s.attendance.filter((a) => a.status === "ABSENT").length,
    })),
  };
}

// Trainer (own): attendance page + summary by course (used by their dashboard/home).
// Trainer's recent sessions across own courses (home widget).
async function getRecentSessionsForTrainer(trainerId) {
  return prisma.session.findMany({
    where: { course: { trainerId } },
    orderBy: { date: "desc" },
    include: { course: { select: { title: true, trainerId: true } }, attendance: true },
    take: 20,
  });
}

module.exports = {
  createSession,
  listForCourse,
  getSessionForAttendance,
  saveMarks,
  getMyAttendance,
  getCourseOverviewForAdmin,
  getRecentSessionsForTrainer,
};
