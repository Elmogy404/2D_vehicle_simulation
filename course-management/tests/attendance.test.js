// Attendance: trainer-own sessions only, marking confirmed trainees, trainee sees own records.
const {
  makeApp,
  makeUser,
  makeCourse,
  makeBooking,
  makeSession,
  resetDb,
  login,
  prisma,
} = require("./helpers");

const CSRF = (page) => /name="_csrf" value="([^"]+)"/.exec(page.text)[1];

let admin, trainerA, trainerB, traineeA, traineeB;
let courseA, courseB, sessionA;

beforeEach(async () => {
  await resetDb();
  admin = await makeUser("ADMIN");
  trainerA = await makeUser("TRAINER");
  trainerB = await makeUser("TRAINER");
  traineeA = await makeUser("TRAINEE");
  traineeB = await makeUser("TRAINEE");

  courseA = await makeCourse(trainerA.id, { title: "دورة الشرقي" });
  courseB = await makeCourse(trainerB.id, { title: "دورة الغربي" });
  await makeBooking(courseA.id, traineeA.id, "CONFIRMED");
  await makeBooking(courseA.id, traineeB.id, "PENDING"); // not confirmed -> not markable
  sessionA = await makeSession(courseA.id);
});

describe("trainer sessions", () => {
  let agent;

  beforeEach(async () => {
    const { agent: a } = makeApp();
    agent = a;
    await login(agent, trainerA.email, trainerA.rawPassword);
  });

  test("trainer creates a session on their own course", async () => {
    const page = await agent.get(`/courses/${courseA.id}/sessions`).expect(200);
    await agent
      .post(`/courses/${courseA.id}/sessions`)
      .type("form")
      .send({ _csrf: CSRF(page), date: "2031-01-01", title: "جلسة تجريبية" })
      .expect(302);

    const sessions = await prisma.session.findMany({ where: { courseId: courseA.id } });
    expect(sessions.length).toBe(2);
  });

  test("trainer cannot create a session on another trainer's course", async () => {
    const { agent: agentB } = makeApp();
    await login(agentB, trainerB.email, trainerB.rawPassword);
    const page = await agentB.get(`/courses/${courseB.id}/sessions`).expect(200); // own
    await agentB
      .post(`/courses/${courseA.id}/sessions`)
      .type("form")
      .redirects(0)
      .send({ _csrf: CSRF(page), date: "2031-01-01" })
      .expect(404);
  });
});

describe("marking attendance", () => {
  let agent;

  beforeEach(async () => {
    const { agent: a } = makeApp();
    agent = a;
    await login(agent, trainerA.email, trainerA.rawPassword);
  });

  test("trainer marks a CONFIRMED trainee; unconfirmed trainees are ignored", async () => {
    const page = await agent.get(`/sessions/${sessionA.id}`).expect(200);
    await agent
      .post(`/sessions/${sessionA.id}/attendance`)
      .type("form")
      .send({
        _csrf: CSRF(page),
        [`status_${traineeA.id}`]: "PRESENT",
        [`status_${traineeB.id}`]: "ABSENT", // B is only PENDING -> must be rejected/ignored
      })
      .expect(302);

    const rows = await prisma.attendance.findMany({ where: { sessionId: sessionA.id } });
    expect(rows.length).toBe(1);
    expect(rows[0].traineeId).toBe(traineeA.id);
    expect(rows[0].status).toBe("PRESENT");
    expect(rows[0].markedById).toBe(trainerA.id);
  });

  test("marks are editable (upsert)", async () => {
    const page = await agent.get(`/sessions/${sessionA.id}`).expect(200);
    await agent
      .post(`/sessions/${sessionA.id}/attendance`)
      .type("form")
      .send({ _csrf: CSRF(page), [`status_${traineeA.id}`]: "PRESENT" })
      .expect(302);
    await agent
      .post(`/sessions/${sessionA.id}/attendance`)
      .type("form")
      .send({ _csrf: CSRF(page), [`status_${traineeA.id}`]: "ABSENT" })
      .expect(302);

    const rows = await prisma.attendance.findMany({ where: { sessionId: sessionA.id } });
    expect(rows.length).toBe(1);
    expect(rows[0].status).toBe("ABSENT");
  });

  test("trainer cannot mark on another trainer's course (IDOR)", async () => {
    const sessionB = await makeSession(courseB.id);
    const page = await agent.get(`/courses/${courseA.id}/sessions`).expect(200);
    await agent
      .post(`/sessions/${sessionB.id}/attendance`)
      .type("form")
      .redirects(0)
      .send({ _csrf: CSRF(page), [`status_${traineeA.id}`]: "PRESENT" })
      .expect(404);
    const rows = await prisma.attendance.findMany({ where: { sessionId: sessionB.id } });
    expect(rows.length).toBe(0);
  });

  test("admin sees the read-only sheet (no save button)", async () => {
    const { agent: agentAdmin } = makeApp();
    await login(agentAdmin, admin.email, admin.rawPassword);
    const res = await agentAdmin.get(`/sessions/${sessionA.id}`).expect(200);
    expect(res.text).not.toContain("حفظ الحضور");
    expect(res.text).toContain(traineeA.name);
  });

  test("admin course overview is read-only and visible", async () => {
    await prisma.attendance.create({
      data: { sessionId: sessionA.id, traineeId: traineeA.id, status: "PRESENT", markedById: trainerA.id },
    });
    const { agent: agentAdmin } = makeApp();
    await login(agentAdmin, admin.email, admin.rawPassword);
    const res = await agentAdmin.get(`/courses/${courseA.id}/attendance`).expect(200);
    expect(res.text).toContain(courseA.title);
    expect(res.text).toContain(traineeA.name);
  });
});

describe("trainee my-attendance", () => {
  test("trainee sees only their own rows per course", async () => {
    await prisma.attendance.create({
      data: { sessionId: sessionA.id, traineeId: traineeA.id, status: "PRESENT", markedById: trainerA.id },
    });
    await makeBooking(courseB.id, traineeA.id, "CONFIRMED");
    const sessionB = await makeSession(courseB.id);
    await prisma.attendance.create({
      data: { sessionId: sessionB.id, traineeId: traineeA.id, status: "ABSENT", markedById: trainerB.id },
    });

    const { agent } = makeApp();
    await login(agent, traineeA.email, traineeA.rawPassword);
    const res = await agent.get("/my-attendance").expect(200);
    expect(res.text).toContain(traineeA.name); // self rows rendered
    expect(res.text).toContain("حاضر");
    expect(res.text).toContain("غائب");
    // only own two rows exist, and the other trainer's course shows up once
    expect(res.text).toContain("دورة الشرقي");
    expect(res.text).toContain("دورة الغربي");
  });
});
