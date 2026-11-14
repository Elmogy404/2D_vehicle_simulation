// Role-aware dashboard figures, strictly scoped to the signed-in user.
const prisma = require("../db");

async function getAdminStats() {
  const [courses, trainees, bookings, byStatus, recent] = await Promise.all([
    prisma.course.count(),
    prisma.user.count({ where: { role: "TRAINEE" } }),
    prisma.booking.count(),
    prisma.booking.groupBy({ by: ["status"], _count: { _all: true } }),
    prisma.booking.findMany({
      orderBy: { createdAt: "desc" },
      take: 8,
      include: {
        course: { select: { title: true } },
        trainee: { select: { name: true, email: true } },
      },
    }),
  ]);
  return {
    counts: { courses, trainees, bookings },
    byStatus: byStatus.map((g) => ({ status: g.status, count: g._count._all })),
    recent,
  };
}

async function getTrainerStats(trainerId) {
  const [myCoursesCount, bookingsCount, upcomingSessions, myCourses] = await Promise.all([
    prisma.course.count({ where: { trainerId } }),
    prisma.booking.count({ where: { course: { trainerId } } }),
    prisma.session.findMany({
      where: { course: { trainerId }, date: { gte: new Date() } },
      orderBy: { date: "asc" },
      take: 5,
      include: { course: { select: { id: true, title: true } } },
    }),
    prisma.course.findMany({
      where: { trainerId },
      orderBy: { createdAt: "desc" },
      take: 5,
      select: { id: true, title: true, price: true, _count: { select: { bookings: true, sessions: true } } },
    }),
  ]);
  return { counts: { myCoursesCount, bookingsCount }, upcomingSessions, myCourses };
}

async function getTraineeStats(traineeId) {
  const [bookingsCount, bookings, attendanceRows] = await Promise.all([
    prisma.booking.count({ where: { traineeId } }),
    prisma.booking.findMany({
      where: { traineeId },
      orderBy: { createdAt: "desc" },
      take: 5,
      include: { course: { select: { id: true, title: true } } },
    }),
    prisma.attendance.findMany({ where: { traineeId }, select: { status: true } }),
  ]);
  const present = attendanceRows.filter((a) => a.status === "PRESENT").length;
  const absent = attendanceRows.length - present;
  return { counts: { bookingsCount }, bookings, present, absent };
}

module.exports = { getAdminStats, getTrainerStats, getTraineeStats };
