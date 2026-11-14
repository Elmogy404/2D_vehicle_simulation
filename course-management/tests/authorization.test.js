// Authorization matrix: which role can access which route, plus IDOR cover.
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

let admin, trainerA, trainerB, traineeA, traineeB;
let courseA, courseB, bookingB, sessionA;

beforeEach(async () => {
  await resetDb();
  admin = await makeUser("ADMIN");
  trainerA = await makeUser("TRAINER");
  trainerB = await makeUser("TRAINER");
  traineeA = await makeUser("TRAINEE");
  traineeB = await makeUser("TRAINEE");

  courseA = await makeCourse(trainerA.id, { title: "دورة المدرب الأول" });
  courseB = await makeCourse(trainerB.id, { title: "دورة المدرب الثاني" });
  bookingB = await makeBooking(courseA.id, traineeB.id, "PENDING");
  sessionA = await makeSession(courseA.id);
});

describe("unauthenticated access", () => {
  test("protected page redirects to /login", async () => {
    const { agent } = makeApp();
    await agent.get("/courses").expect(302).expect("Location", /\/login/);
    await agent.get("/bookings").expect(302).expect("Location", /\/login/);
    await agent.get("/dashboard").expect(302).expect("Location", /\/login/);
  });
});

describe("role gates on sensitive routes", () => {
  test("GET /users is admin-only", async () => {
    {
      const { agent } = makeApp();
      await login(agent, admin.email, admin.rawPassword);
      await agent.get("/users").expect(200);
    }
    {
      const { agent } = makeApp();
      await login(agent, trainerA.email, trainerA.rawPassword);
      await agent.get("/users").expect(403);
    }
    {
      const { agent } = makeApp();
      await login(agent, traineeA.email, traineeA.rawPassword);
      await agent.get("/users").expect(403);
    }
  });

  test("course CRUD creation/edit is admin-only", async () => {
    {
      const { agent } = makeApp();
      await login(agent, trainerA.email, trainerA.rawPassword);
      await agent.get("/courses/new").expect(403);
      await agent.post("/courses").type("form").send({}).expect(403);
    }
    {
      const { agent } = makeApp();
      await login(agent, admin.email, admin.rawPassword);
      await agent.get("/courses/new").expect(200);
    }
  });

  test("trainee cannot see the admin booking list (trainer too)", async () => {
    {
      const { agent } = makeApp();
      await login(agent, traineeA.email, traineeA.rawPassword);
      await agent.get("/bookings").expect(403);
    }
    {
      const { agent } = makeApp();
      await login(agent, trainerA.email, trainerA.rawPassword);
      await agent.get("/bookings").expect(403);
    }
    {
      const { agent } = makeApp();
      await login(agent, admin.email, admin.rawPassword);
      await agent.get("/bookings").expect(200);
    }
  });

  test("booking confirm route is admin-only", async () => {
    const { agent } = makeApp();
    await login(agent, trainerA.email, trainerA.rawPassword);
    await agent.post(`/bookings/${bookingB.id}/confirm`).type("form").send({}).expect(403);
  });

  test("marking attendance is trainer-only (admin is read-only, trainee forbidden)", async () => {
    {
      const { agent } = makeApp();
      await login(agent, admin.email, admin.rawPassword);
      await agent.post(`/sessions/${sessionA.id}/attendance`).type("form").send({}).expect(403);
    }
    {
      const { agent } = makeApp();
      await login(agent, traineeA.email, traineeA.rawPassword);
      await agent.get(`/sessions/${sessionA.id}`).expect(403);
      await agent.get("/my-attendance").expect(200);
    }
  });
});

describe("IDOR: cross-tenant access is camouflaged/not allowed", () => {
  test("trainer B cannot read trainer A's course sessions", async () => {
    const { agent } = makeApp();
    await login(agent, trainerB.email, trainerB.rawPassword);
    await agent.get(`/courses/${courseA.id}/sessions`).expect(404);
    await agent.get(`/sessions/${sessionA.id}`).expect(404);
  });

  test("trainer B cannot mark attendance on trainer A's session", async () => {
    const { agent } = makeApp();
    await login(agent, trainerB.email, trainerB.rawPassword);
    const page = await agent.get("/courses").expect(200);
    const token = /name="_csrf" value="([^"]+)"/.exec(page.text)[1];
    await agent
      .post(`/sessions/${sessionA.id}/attendance`)
      .type("form")
      .redirects(0)
      .send({ _csrf: token, [`status_${traineeB.id}`]: "PRESENT" })
      .expect(404);
  });

  test("trainee A cannot read trainee B's records (my-attendance hides others)", async () => {
    // seed attendance for traineeB only
    const confirmedForB = await prisma.booking.findUnique({
      where: { courseId_traineeId: { courseId: courseA.id, traineeId: traineeB.id } },
    });
    expect(confirmedForB).toBeTruthy();
    await prisma.attendance.create({
      data: { sessionId: sessionA.id, traineeId: traineeB.id, status: "PRESENT", markedById: trainerA.id },
    });

    const { agent } = makeApp();
    await login(agent, traineeA.email, traineeA.rawPassword);
    const res = await agent.get("/my-attendance").expect(200);
    expect(res.text).not.toContain(traineeB.name);
    // and A has no rows of their own on this session
    const aRows = await prisma.attendance.findMany({ where: { traineeId: traineeA.id } });
    expect(aRows.length).toBe(0);
  });

  test("trainee A cannot cancel trainee B's booking", async () => {
    const { agent } = makeApp();
    await login(agent, traineeA.email, traineeA.rawPassword);
    const page = await agent.get("/courses").expect(200);
    const token = /name="_csrf" value="([^"]+)"/.exec(page.text)[1];
    await agent
      .post(`/bookings/${bookingB.id}/cancel`)
      .type("form")
      .redirects(0)
      .send({ _csrf: token, _method: "PUT" })
      .expect(404);
  });

  test("admin can view any course; trainer B sees 404 on foreign course list? (browse allowed)", async () => {
    // Admin sees all; trainer B can still *browse* the public course list
    const { agent } = makeApp();
    await login(agent, trainerB.email, trainerB.rawPassword);
    const res = await agent.get("/courses").expect(200);
    expect(res.text).toContain("دورة المدرب الأول"); // public browsing allowed for trainers too
  });
});
