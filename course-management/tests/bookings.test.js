// Bookings: trainee book/duplicate/cancel transitions, admin confirm/cancel + filters.
const {
  makeApp,
  makeUser,
  makeCourse,
  makeBooking,
  resetDb,
  login,
  prisma,
} = require("./helpers");

const CSRF = (page) => /name="_csrf" value="([^"]+)"/.exec(page.text)[1];

let admin, traineeA, traineeB, trainer;
let course;

beforeEach(async () => {
  await resetDb();
  admin = await makeUser("ADMIN");
  trainer = await makeUser("TRAINER");
  traineeA = await makeUser("TRAINEE");
  traineeB = await makeUser("TRAINEE");
  course = await makeCourse(trainer.id);
});

describe("trainee bookings", () => {
  let agentA;

  beforeEach(async () => {
    const { agent } = makeApp();
    agentA = agent;
    await login(agentA, traineeA.email, traineeA.rawPassword);
  });

  test("booking creates a PENDING record and shows on my bookings", async () => {
    const page = await agentA.get("/courses").expect(200);
    await agentA
      .post("/bookings")
      .type("form")
      .send({ _csrf: CSRF(page), courseId: String(course.id) })
      .expect(302)
      .expect("Location", "/bookings/mine");

    const booking = await prisma.booking.findUnique({
      where: { courseId_traineeId: { courseId: course.id, traineeId: traineeA.id } },
    });
    expect(booking).toBeTruthy();
    expect(booking.status).toBe("PENDING");

    const mine = await agentA.get("/bookings/mine").expect(200);
    expect(mine.text).toContain(course.title);
    expect(mine.text).toContain("قيد الانتظار");
  });

  test("duplicate booking is blocked (single row, friendly message)", async () => {
    const page = await agentA.get("/courses").expect(200);
    const form = { _csrf: CSRF(page), courseId: String(course.id) };
    await agentA.post("/bookings").type("form").send(form).expect(302);
    const res = await agentA.post("/bookings").type("form").redirects(0).send(form).expect(302);
    expect(res.headers.location).toBe("/bookings/mine");

    const rows = await prisma.booking.findMany({ where: { courseId: course.id, traineeId: traineeA.id } });
    expect(rows.length).toBe(1);
  });

  test("trainee cancels their own PENDING booking, then may re-book", async () => {
    const page = await agentA.get("/courses").expect(200);
    const form = { _csrf: CSRF(page), courseId: String(course.id) };
    await agentA.post("/bookings").type("form").send(form).expect(302);
    let booking = await prisma.booking.findUnique({
      where: { courseId_traineeId: { courseId: course.id, traineeId: traineeA.id } },
    });

    const mine = await agentA.get("/bookings/mine").expect(200);
    await agentA
      .post(`/bookings/${booking.id}/cancel`)
      .type("form")
      .send({ _csrf: CSRF(mine), _method: "PUT" })
      .expect(302);

    booking = await prisma.booking.findUnique({
      where: { id: booking.id },
    });
    expect(booking.status).toBe("CANCELLED");

    // re-booking after cancellation reactivates (documented assumption)
    await agentA.post("/bookings").type("form").send(form).expect(302);
    booking = await prisma.booking.findUnique({
      where: { courseId_traineeId: { courseId: course.id, traineeId: traineeA.id } },
    });
    expect(booking.status).toBe("PENDING");
  });

  test("trainee cannot cancel a CONFIRMED booking", async () => {
    const booking = await makeBooking(course.id, traineeA.id, "CONFIRMED");
    const mine = await agentA.get("/bookings/mine").expect(200);
    await agentA
      .post(`/bookings/${booking.id}/cancel`)
      .type("form")
      .redirects(0)
      .send({ _csrf: CSRF(mine), _method: "PUT" })
      .expect(403);
  });
});

describe("admin booking management", () => {
  let agentAdmin;

  beforeEach(async () => {
    const { agent } = makeApp();
    agentAdmin = agent;
    await login(agentAdmin, admin.email, admin.rawPassword);
  });

  test("admin confirms a PENDING booking", async () => {
    const booking = await makeBooking(course.id, traineeA.id, "PENDING");
    const page = await agentAdmin.get("/bookings").expect(200);
    await agentAdmin
      .post(`/bookings/${booking.id}/confirm`)
      .type("form")
      .send({ _csrf: CSRF(page), _method: "PUT" })
      .expect(302);
    const updated = await prisma.booking.findUnique({ where: { id: booking.id } });
    expect(updated.status).toBe("CONFIRMED");
  });

  test("admin cancels a CONFIRMED booking", async () => {
    const booking = await makeBooking(course.id, traineeA.id, "CONFIRMED");
    const page = await agentAdmin.get("/bookings").expect(200);
    await agentAdmin
      .post(`/bookings/${booking.id}/cancel`)
      .type("form")
      .send({ _csrf: CSRF(page), _method: "PUT" })
      .expect(302);
    const updated = await prisma.booking.findUnique({ where: { id: booking.id } });
    expect(updated.status).toBe("CANCELLED");
  });

  test("admin cannot re-confirm a CANCELLED booking", async () => {
    const booking = await makeBooking(course.id, traineeA.id, "CANCELLED");
    const page = await agentAdmin.get("/bookings").expect(200);
    await agentAdmin
      .post(`/bookings/${booking.id}/confirm`)
      .type("form")
      .redirects(0)
      .send({ _csrf: CSRF(page), _method: "PUT" })
      .expect(409);
  });

  test("admin list supports status filter and pagination", async () => {
    await makeBooking(course.id, traineeA.id, "CONFIRMED");
    await makeBooking(course.id, traineeB.id, "CANCELLED");
    const res = await agentAdmin.get("/bookings?status=CONFIRMED").expect(200);
    expect(res.text).toContain("مؤكدة");
    expect(res.text).not.toContain("ملغية");
    const all = await agentAdmin.get("/bookings?page=1").expect(200);
    expect(all.text).toContain("قيد الانتظار");
  });
});
