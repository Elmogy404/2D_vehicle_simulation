// Seed data for the Course Management app (development only).
// Usage: npm run db:seed
const { PrismaClient, Role, BookingStatus, AttendanceStatus } = require("@prisma/client");
const bcrypt = require("bcrypt");

const prisma = new PrismaClient();

const PASSWORD = "Passw0rd!";

async function main() {
  const users = await createUsers();
  const courses = await createCources(users.trainers);
  const bookings = await createBookings(courses, users.trainees);
  const sessions = await createSessions(courses);
  await createAttendance(sessions, bookings, users.admin);

  console.log("\n=== Seeded credentials (development only) ===");
  console.log(`admin   : admin@academy.test / ${PASSWORD}`);
  console.log(`trainers: trainer1@academy.test / ${PASSWORD}`);
  console.log(`          trainer2@academy.test / ${PASSWORD}`);
  console.log(`trainees: trainee1@academy.test / ${PASSWORD}`);
  console.log(`          trainee2@academy.test / ${PASSWORD}`);
  console.log(`          trainee3@academy.test / ${PASSWORD}`);
  console.log(`          trainee4@academy.test / ${PASSWORD}`);
  console.log(`          trainee5@academy.test / ${PASSWORD}`);
  console.log("============================================\n");
}

async function createUsers() {
  const passwordHash = await bcrypt.hash(PASSWORD, 12);

  const [admin] = await Promise.all([
    upsertUser("سارة الأدمن", "admin@academy.test", Role.ADMIN, passwordHash),
    upsertUser("أحمد المدرّب", "trainer1@academy.test", Role.TRAINER, passwordHash),
    upsertUser("ليلى المدرّبة", "trainer2@academy.test", Role.TRAINER, passwordHash),
    upsertUser("محمد المتدرب", "trainee1@academy.test", Role.TRAINEE, passwordHash),
    upsertUser("هند المتدربة", "trainee2@academy.test", Role.TRAINEE, passwordHash),
    upsertUser("خالد المتدرب", "trainee3@academy.test", Role.TRAINEE, passwordHash),
    upsertUser("نورة المتدربة", "trainee4@academy.test", Role.TRAINEE, passwordHash),
    upsertUser("عمر المتدرب", "trainee5@academy.test", Role.TRAINEE, passwordHash),
  ]);

  const trainers = [
    await prisma.user.findUnique({ where: { email: "trainer1@academy.test" } }),
    await prisma.user.findUniqueOrThrow({ where: { email: "trainer2@academy.test" } }),
  ];
  const trainees = (await prisma.user.findMany({ where: { role: Role.TRAINEE }, orderBy: { email: "asc" } }));

  return { admin: await prisma.user.findUniqueOrThrow({ where: { email: "admin@academy.test" } }), trainers, trainees };
}

async function upsertUser(name, email, role, passwordHash) {
  return prisma.user.upsert({
    where: { email },
    update: {},
    create: { name, email, role, passwordHash },
  });
}

async function createCources(trainers) {
  const data = [
    { title: "أساسيات البرمجة بجافاسكربت", description: "مقدمة عملية إلى جافاسكربت: المتغيرات، الدوال، DOM، ومشاريع صغيرة.", price: 250.0, trainerId: trainers[0].id },
    { title: "قواعد البيانات العلائقية", description: "تصميم قواعد البيانات، SQL، الفهارس، والاستعلامات المتقدمة.", price: 400.0, trainerId: trainers[0].id },
    { title: "تطوير واجهات المستخدم", description: "بناء واجهات عصرية بـ HTML و CSS وتجربة مستخدم أفضل.", price: 300.0, trainerId: trainers[1].id },
    { title: "مقدمة في الأمن السيبراني", description: "وصف مفاهيم حماية البيانات، كلمات المرور، والأنظمة الآمنة على الشبكة.", price: 500.0, trainerId: trainers[1].id },
  ];

  for (const item of data) {
    await prisma.course.upsert({
      where: { id: await ensureCourseId(item) },
      update: {},
      create: item,
    });
  }
  return prisma.course.findMany({ orderBy: { id: "asc" } });
}

async function ensureCourseId(item) {
  const existing = await prisma.course.findFirst({ where: { title: item.title }, select: { id: true } });
  if (existing) return existing.id;
  const created = await prisma.course.create({ data: item, select: { id: true } });
  return created.id;
}

async function createBookings(courses, trainees) {
  const pairs = [
    { course: courses[0], trainee: trainees[0], status: BookingStatus.CONFIRMED },
    { course: courses[0], trainee: trainees[1], status: BookingStatus.PENDING },
    { course: courses[1], trainee: trainees[0], status: BookingStatus.PENDING },
    { course: courses[2], trainee: trainees[2], status: BookingStatus.CONFIRMED },
    { course: courses[3], trainee: trainees[3], status: BookingStatus.PENDING },
    { course: courses[3], trainee: trainees[4], status: BookingStatus.CONFIRMED },
  ];

  for (const { course, trainee, status } of pairs) {
    await prisma.booking.upsert({
      where: { courseId_traineeId: { courseId: course.id, traineeId: trainee.id } },
      update: {},
      create: { courseId: course.id, traineeId: trainee.id, status },
    });
  }
  return prisma.booking.findMany({ include: { course: true, trainee: true } });
}

async function createSessions(courses) {
  const today = new Date();
  const isoDay = (offsetDays) => {
    const d = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() + offsetDays));
    return d;
  };

  const plan = [
    { courseId: courses[0].id, date: isoDay(-7) },
    { courseId: courses[0].id, date: isoDay(-3) },
    { courseId: courses[0].id, date: isoDay(3) },
    { courseId: courses[2].id, date: isoDay(-1) },
    { courseId: courses[3].id, date: isoDay(5) },
  ];

  const out = [];
  for (const item of plan) {
    const found = await prisma.session.findFirst({ where: { courseId: item.courseId, date: item.date } });
    out.push(found ?? (await prisma.session.create({ data: item, include: { course: true } })));
  }
  return out;
}

async function createAttendance(sessions, bookings, admin) {
  const course0Bookings = bookings.filter((b) => b.courseId === sessions[0].courseId);
  const marks = [];
  for (const b of course0Bookings) {
    if (b.status === BookingStatus.CONFIRMED) {
      marks.push({ sessionId: sessions[0].id, traineeId: b.traineeId, status: AttendanceStatus.PRESENT, markedById: admin.id });
    }
  }
  for (const m of marks) {
    await prisma.attendance.upsert({
      where: { sessionId_traineeId: { sessionId: m.sessionId, traineeId: m.traineeId } },
      update: {},
      create: m,
    });
  }

  const pastSession = sessions[1];
  const course0Confirmed = await prisma.booking.findMany({
    where: { courseId: pastSession.courseId, status: BookingStatus.CONFIRMED },
  });
  for (const [i, b] of course0Confirmed.entries()) {
    await prisma.attendance.upsert({
      where: { sessionId_traineeId: { sessionId: pastSession.id, traineeId: b.traineeId } },
      update: {},
      create: {
        sessionId: pastSession.id,
        traineeId: b.traineeId,
        status: i % 2 === 0 ? AttendanceStatus.ABSENT : AttendanceStatus.PRESENT,
        markedById: admin.id,
      },
    });
  }
}

main()
  .catch((e) => {
    console.error(e);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect();
  });
