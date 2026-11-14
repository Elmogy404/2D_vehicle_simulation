# إدارة الدورات — Course Management Web App

A complete, simple course management web application:
server-rendered MVC with **Node.js (LTS), Express 5, EJS, Bootstrap 5 (RTL), PostgreSQL + Prisma**, role-based auth (express-session + connect-pg-simple + bcrypt), input validation with **zod**, security hardening (helmet, rate limits, CSRF with `csrf-csrf`), Arabic RTL UI, and a **Jest + Supertest** suite running against a separate test database.

---

## Requirements

- Node.js 20+ (developed on Node 24 LTS)
- PostgreSQL 14+ (local Docker via `docker-compose.yml`, or any managed Postgres)

## Quick start (local, Docker)

```bash
cp .env.example .env          # then edit values (see "Environment variables")
docker compose up -d          # starts Postgres with two DBs: courses_dev + courses_test
npm install
npm run db:migrate            # prisma migrate dev -> creates schema on courses_dev
npm run db:seed               # seed development demo data
npm run dev                   # http://localhost:3000
```

> This repo was developed against a cloud Postgres (Neon) — same `.env` shape; `DATABASE_URL`/`TEST_DATABASE_URL` just point there instead of localhost.

## Environment variables

Copy `.env.example` → `.env` (never commit `.env`):

| Variable | Used by | Notes |
|---|---|---|
| `NODE_ENV` | app | `development` / `production` |
| `PORT` | app | default `3000` |
| `SESSION_SECRET` | session cookie signing | random 64-hex, required |
| `CSRF_SECRET` | CSRF token HMAC secret | falls back to `SESSION_SECRET` |
| `DATABASE_URL` | runtime DB (web + session store) | pooled URL is fine |
| `DIRECT_URL` | Prisma migrations | non-pooled Postgres URL |
| `TEST_DATABASE_URL` | `npm test` (Jest) | separate test DB |
| `TEST_DIRECT_URL` | test migrations | direct/non-pooled URL for the test DB |
| `LOGIN_RATE_LIMIT_MAX` / `LOGIN_RATE_LIMIT_WINDOW_MS` | rate limiting | defaults: `10` / 15 min |

## Database & migrations

- `npm run db:migrate` — create/apply a development migration (`prisma migrate dev`)
- `npm run db:deploy` — apply migrations without prompts (`prisma migrate deploy`)
- `npm run db:seed` — seed demo data (idempotent upserts)
- `npm test` — runs migrations on the **test** DB automatically (Jest globalSetup), then the suite

Schema (see `prisma/schema.prisma`): `User` (role enum ADMIN/TRAINER/TRAINEE), `Course` (Decimal price ≥ 0, trainer FK), `Booking` (unique per course+trainee, status enum), `Session` (course class date), `Attendance` (unique per session+trainee, markedById). FKs cascade for bookings/attendance; course→trainer is `Restrict` (never silently delete a trainer with courses).

## Seeded accounts (development only)

All passwords: `Passw0rd!`

| Role | Email |
|---|---|
| Admin | `admin@academy.test` |
| Trainer | `trainer1@academy.test`, `trainer2@academy.test` |
| Trainee | `trainee1@academy.test` … `trainee5@academy.test` |

**Never use these credentials in production** — the seed script is for development/demo only.

## Scripts

| Script | What it does |
|---|---|
| `npm run dev` | dev server with watch/restart (`node --watch`) |
| `npm start` | production-style start (`node src/server.js`) |
| `npm test` | Jest + Supertest against the TEST database |
| `npm run db:migrate` | `prisma migrate dev` |
| `npm run db:deploy` | `prisma migrate deploy` |
| `npm run db:seed` | seed demo data |
| `npm run db:generate` | regenerate the Prisma client |

## Route map

| Method | Path | Role(s) | Purpose |
|---|---|---|---|
| GET | `/login` | public | login page |
| POST | `/login` | public (rate limited) | authenticate |
| GET | `/register` | public | trainee self-registration |
| POST | `/register` | public (rate limited) | create TRAINEE account |
| POST | `/logout` | any | destroy session |
| GET | `/` | any → `/dashboard` | alias |
| GET | `/dashboard` | any (role-scoped view) | per-role home |
| GET | `/users` | ADMIN | list/search users (paginated) |
| GET | `/users/new` | ADMIN | create trainer/admin form |
| POST | `/users` | ADMIN | create trainer/admin |
| GET | `/users/:uid/edit` | ADMIN | edit user form |
| PUT | `/users/:uid` | ADMIN | update user |
| DELETE | `/users/:uid` | ADMIN | delete user (blocked when referenced/self) |
| GET | `/courses` | ADMIN/TRAINEE all, TRAINER own | list courses (paginated) |
| GET | `/courses/new` | ADMIN | new course form |
| POST | `/courses` | ADMIN | create course |
| GET | `/courses/:id` | all (trainer-own only for trainers) | course details |
| GET | `/courses/:id/edit` | ADMIN | edit form |
| PUT | `/courses/:id` | ADMIN | update course |
| DELETE | `/courses/:id` | ADMIN | delete (blocked while bookings exist) |
| GET | `/bookings` | ADMIN | all bookings, filters by course/status, paginated |
| GET | `/bookings/mine` | TRAINEE | own bookings |
| POST | `/bookings` | TRAINEE | book a course (duplicates blocked; cancel→re-book allowed) |
| PUT | `/bookings/:id/confirm` | ADMIN | PENDING → CONFIRMED |
| PUT | `/bookings/:id/cancel` | ADMIN any, TRAINEE own PENDING | cancel booking |
| GET | `/courses/:id/sessions` | ADMIN, TRAINER(own) | sessions list + create form |
| POST | `/courses/:id/sessions` | ADMIN, TRAINER(own) | create class session |
| GET | `/courses/:id/attendance` | ADMIN | read-only attendance overview |
| GET | `/sessions/:id` | ADMIN (read-only), TRAINER(own) | attendance sheet |
| POST | `/sessions/:id/attendance` | TRAINER(own) | mark each CONFIRMED trainee present/absent (editable) |
| GET | `/my-attendance` | TRAINEE | own per-course attendance + summary |

## Project structure

```
course-management/
├── prisma/            schema.prisma, migrations/, seed.js
├── src/
│   ├── app.js         express app factory (also used by tests)
│   ├── server.js      HTTP entry, graceful shutdown
│   ├── config/        env loading + fail-fast validation
│   ├── db.js          Prisma client singleton (test-DB aware)
│   ├── locales/ar.js  all Arabic UI strings (single locale file)
│   ├── errors.js      AppError / ValidationError / NotFound / Forbidden / Conflict
│   ├── routes/        route definitions only
│   ├── controllers/   request/response handling only
│   ├── services/      business logic + DB access + ownership checks
│   ├── middleware/    auth, roles, csrf, error handler, auth context
│   └── views/         EJS partials + one folder per module
├── tests/             Jest global setup + supertest suites (test DB)
├── docker/            pg init script (creates courses_test)
├── docker-compose.yml local Postgres (courses_dev + courses_test)
└── .env.example
```

Authorization is enforced twice: role middleware on routes **and** ownership checks inside services (IDOR-safe: foreign resources respond 404, wrong role 403).

## Testing

`npm test`:

1. jest globalSetup applies migrations to `TEST_DATABASE_URL`,
2. every suite truncates app tables and boots a fresh app via the same `createApp()` the server uses,
3. auth flows use real forms (CSRF token, cookies) via supertest agent.

Suites: **auth** (register/login/wrong-password/rate limit), **authorization matrix** (role gates + IDOR), **bookings** (duplicate blocked, status transitions, filters), **attendance** (own-course only, editable marks, trainee isolation).

## Assumptions (decisions taken for simplicity)

- Deleting a course with bookings is **blocked** with a clear message; deleting with no bookings cascades sessions/attendance (documented FK rules in schema).
- Re-booking after cancelling a booking **re-activates** it as PENDING (CANCELLED is not a dead end); a CANCELLED booking cannot be confirmed by admin.
- Trainees may only cancel **PENDING** bookings; admins may cancel any non-cancelled booking.
- Admin attendance access is read-only (no marking).
- Public registration always creates TRAINEE; admins create TRAINEE/TRAINER/ADMIN accounts.
- Deleting users is blocked while any related records exist; also you cannot delete your own account.
- Routes/role mismatches return **403**; foreign-but-existing resources return **404** (existence of other trainers'/trainees' data is not leaked).
- UI text is Arabic (RTL) and centralised in `src/locales/ar.js`.

## Incomplete / limitations

- No file uploads, course images, or email flows (out of scope).
- Password reset flow not implemented (admin can reset passwords).
- Sessions table cleanup relies on connect-pg-simple defaults (`pruneSession` interval).
- The seed uses fixed demo emails; re-running is idempotent.
