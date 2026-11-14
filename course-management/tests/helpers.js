// Shared helpers for the supertest suites.
const bcrypt = require("bcrypt");
const supertest = require("supertest");
const prisma = require("../src/db");
const { createApp } = require("../src/app");

const PASSWORD = "Passw0rd!";

// baseline fresh app + cookie jar
function makeApp(overrides = {}) {
  const app = createApp(overrides);
  const agent = supertest.agent(app);
  return { app, agent };
}

async function makeUser(role, overrides = {}) {
  const count = Math.floor(Math.random() * 1e6);
  const email = overrides.email || `${role.toLowerCase()}${count}@test.local`;
  const data = await prisma.user.create({
    data: {
      name: overrides.name || `${role} ${count}`,
      email,
      role,
      passwordHash: await bcrypt.hash(overrides.password || PASSWORD, 4),
    },
  });
  return { ...data, rawPassword: overrides.password || PASSWORD };
}

async function makeCourse(trainerId, overrides = {}) {
  return prisma.course.create({
    data: {
      title: overrides.title || "دورة اختبار " + Date.now(),
      description: overrides.description || "وصف تجريبي كافٍ للاختبار自动化.",
      price: overrides.price != null ? overrides.price : 100,
      trainerId,
    },
  });
}

async function makeBooking(courseId, traineeId, status = "PENDING") {
  return prisma.booking.create({ data: { courseId, traineeId, status } });
}

async function makeSession(courseId, date = new Date()) {
  return prisma.session.create({ data: { courseId, date } });
}

/** Deletes all application rows (order irrelevant thanks to CASCADE). */
async function resetDb() {
  await prisma.$executeRawUnsafe(
    "TRUNCATE TABLE attendance, sessions, bookings, courses, users RESTART IDENTITY CASCADE;"
  );
}

function extractCsrf(html) {
  const m = /name="_csrf" value="([^"]+)"/.exec(html || "");
  return m ? m[1] : null;
}

/** Drives the real page/form flow so CSRF tokens stay in sync with the session. */
async function login(agent, email, password) {
  const page = await agent.get("/login").expect(200);
  const token = extractCsrf(page.text);
  if (!token) throw new Error("no CSRF token on /login");
  return agent
    .post("/login")
    .type("form")
    .send({ _csrf: token, email, password })
    .expect(302);
}

module.exports = {
  PASSWORD,
  makeApp,
  makeUser,
  makeCourse,
  makeBooking,
  makeSession,
  resetDb,
  login,
  extractCsrf,
  prisma,
};
