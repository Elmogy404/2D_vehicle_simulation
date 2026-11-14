// Attendance controller: sessions (admin/trainer-own), marking (trainer), reports.
const attendanceService = require("../services/attendanceService");
const { parse, schemas } = require("../validators");
const prisma = require("../db");
const t = require("../locales/ar");

async function loadCourseName(courseId) {
  const course = await prisma.course.findUnique({ where: { id: courseId }, select: { id: true, title: true } });
  return course;
}

async function sessionsPage(req, res, next) {
  try {
    const courseId = Number(req.params.courseId);
    if (!Number.isInteger(courseId) || courseId <= 0) return next();
    const course = await loadCourseName(courseId);
    if (!course) return next();
    const sessions = await attendanceService.listForCourse(req.currentUser, courseId);
    return res.render("attendance/sessions", {
      title: t.sessions.sessionsTitle,
      course,
      sessions,
      fieldErrors: {},
    });
  } catch (err) {
    return next(err);
  }
}

async function createSession(req, res, next) {
  try {
    const courseId = Number(req.params.courseId);
    if (!Number.isInteger(courseId) || courseId <= 0) return next();
    let data;
    try {
      data = parse(schemas.sessionForm, req.body);
    } catch (err) {
      if (err.fieldErrors) {
        const course = await loadCourseName(courseId);
        if (!course) return next();
        const sessions = await attendanceService.listForCourse(req.currentUser, courseId);
        return res.status(422).render("attendance/sessions", {
          title: t.sessions.sessionsTitle,
          course,
          sessions,
          fieldErrors: err.fieldErrors,
        });
      }
      throw err;
    }
    await attendanceService.createSession(req.currentUser, courseId, data);
    req.flash("success", t.sessions.messages.created);
    return res.redirect(`/courses/${courseId}/sessions`);
  } catch (err) {
    return next(err);
  }
}

async function markPage(req, res, next) {
  try {
    const sessionId = Number(req.params.sessionId);
    if (!Number.isInteger(sessionId) || sessionId <= 0) return next();
    const sheet = await attendanceService.getSessionForAttendance(req.currentUser, sessionId);
    return res.render("attendance/mark", {
      title: t.attendance.title,
      sheet,
    });
  } catch (err) {
    return next(err);
  }
}

// Handles a form with hidden-status inputs; each entry validated with zod.
async function markSave(req, res, next) {
  try {
    const sessionId = Number(req.params.sessionId);
    if (!Number.isInteger(sessionId) || sessionId <= 0) return next();
    const body = req.body || {};
    await Promise.all([
      (async () => {
        for (const [key, value] of Object.entries(body)) {
          if (key.startsWith("status_")) {
            const traineeId = Number(key.slice("status_".length));
            const mark = parse(schemas.attendanceMark, { traineeId, status: value });
            await attendanceService.saveMarks(req.currentUser, sessionId, mark.traineeId, mark.status);
          }
        }
      })(),
    ]);
    req.flash("success", t.attendance.messages.saved);
    return res.redirect(`/sessions/${sessionId}`);
  } catch (err) {
    if (err && (err.status === 403 || err.status === 409 || err.status === 404)) {
      req.flash("error", err.message);
      return res.redirect("back");
    }
    return next(err);
  }
}

async function myAttendance(req, res, next) {
  try {
    const courses = await attendanceService.getMyAttendance(req.currentUser.id);
    return res.render("attendance/mine", { title: t.attendance.myAttendance, courses });
  } catch (err) {
    return next(err);
  }
}

async function courseOverview(req, res, next) {
  try {
    const courseId = Number(req.params.courseId);
    if (!Number.isInteger(courseId) || courseId <= 0) return next();
    const overview = await attendanceService.getCourseOverviewForAdmin(req.currentUser, courseId);
    return res.render("attendance/course-overview", {
      title: t.attendance.title,
      overview,
    });
  } catch (err) {
    return next(err);
  }
}

module.exports = { sessionsPage, createSession, markPage, markSave, myAttendance, courseOverview };
