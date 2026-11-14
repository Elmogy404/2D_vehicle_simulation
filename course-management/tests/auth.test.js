// Authentication: register, login, wrong password, rate limiting.
const { makeApp, makeUser, resetDb, prisma, login } = require("./helpers");

const CSRF = (page) => /name="_csrf" value="([^"]+)"/.exec(page.text)[1];

describe("auth", () => {
  let ctx;

  beforeEach(async () => {
    await resetDb();
    ctx = makeApp();
  });

  test("GET /login renders the login page (with CSRF)", async () => {
    const res = await ctx.agent.get("/login").expect(200);
    expect(res.text).toContain("تسجيل الدخول");
    expect(res.text).toMatch(/name="_csrf"/);
  });

  test("public registration creates a TRAINEE account", async () => {
    const page = await ctx.agent.get("/register").expect(200);
    const res = await ctx.agent
      .post("/register")
      .type("form")
      .send({ _csrf: CSRF(page), name: "متدرب جديد", email: "new-trainee@test.local", password: "Str0ngPass!", confirmPassword: "Str0ngPass!" })
      .expect(302);

    expect(res.headers.location).toBe("/dashboard");
    const user = await prisma.user.findUnique({ where: { email: "new-trainee@test.local" } });
    expect(user).toBeTruthy();
    expect(user.role).toBe("TRAINEE");
  });

  test("duplicate email registration is rejected", async () => {
    await makeUser("TRAINEE", { email: "dup@test.local" });
    const page = await ctx.agent.get("/register").expect(200);
    const res = await ctx.agent
      .post("/register")
      .type("form")
      .send({ _csrf: CSRF(page), name: "مكرر", email: "dup@test.local", password: "Str0ngPass!", confirmPassword: "Str0ngPass!" })
      .expect(422);
    expect(res.text).toContain("مستخدم بالفعل");
  });

  test("register with mismatched password is rejected", async () => {
    const page = await ctx.agent.get("/register").expect(200);
    const res = await ctx.agent
      .post("/register")
      .type("form")
      .send({ _csrf: CSRF(page), name: "متدرب", email: "x1@test.local", password: "Str0ngPass!", confirmPassword: "different1" })
      .expect(422);
    expect(res.text).toContain("غير متطابقتين");
  });

  test("login with wrong password fails with a generic message", async () => {
    const admin = await makeUser("ADMIN");
    const res = await ctx.agent
      .post("/login")
      .type("form")
      .send({ _csrf: CSRF(await ctx.agent.get("/login")), email: admin.email, password: "totally-wrong" })
      .expect(401);
    expect(res.text).toContain("البريد الإلكتروني أو كلمة المرور غير صحيحة");
  });

  test("successful login redirects to dashboard and shows the role page", async () => {
    const admin = await makeUser("ADMIN");
    const { agent } = ctx;
    const res = await login(agent, admin.email, admin.rawPassword);
    expect(res.headers.location).toBe("/dashboard");
    const dash = await agent.get("/dashboard").expect(200);
    expect(dash.text).toContain("المدير");
  });

  test("login as unregistered email fails", async () => {
    const res = await ctx.agent
      .post("/login")
      .type("form")
      .send({ _csrf: CSRF(await ctx.agent.get("/login")), email: "ghost@test.local", password: "whatever-9" })
      .expect(401);
    expect(res.text).toContain("البريد الإلكتروني أو كلمة المرور غير صحيحة");
  });

  test("logout clears the session", async () => {
    const admin = await makeUser("ADMIN");
    const { agent } = ctx;
    await login(agent, admin.email, admin.rawPassword);
    await agent.get("/dashboard").expect(200);

    const res = await agent
      .post("/logout")
      .type("form")
      .send({ _csrf: CSRF(await agent.get("/dashboard")) })
      .expect(302);
    expect(res.headers.location).toBe("/login?loggedout=1");
    await agent.get("/dashboard").expect(302).expect("Location", /\/login/);
  });

  test("rate limiting blocks rapid login attempts", async () => {
    await resetDb();
    const user = await makeUser("TRAINEE", { email: "limited@test.local" });
    const { agent } = makeApp({ loginRateLimitMax: 2, loginRateLimitWindowMs: 60_000 });
    const token = CSRF(await agent.get("/login"));

    await agent.post("/login").type("form").send({ _csrf: token, email: user.email, password: "wrong-1" }).expect(401);
    await agent.post("/login").type("form").send({ _csrf: token, email: user.email, password: "wrong-2" }).expect(401);
    const blocked = await agent
      .post("/login")
      .type("form")
      .redirects(0)
      .send({ _csrf: token, email: user.email, password: "wrong-3" });
    expect(blocked.status).toBe(429);
  });
});
