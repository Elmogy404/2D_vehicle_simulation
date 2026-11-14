// Bookings controller (admin list/confirm/cancel; trainee book/myBookings/cancel).
const bookingService = require("../services/bookingService");
const { parse, schemas } = require("../validators");
const t = require("../locales/ar");

async function adminList(req, res, next) {
  try {
    const q = parse(schemas.listQuery, { page: req.query.page, courseId: req.query.courseId, status: req.query.status });
    const { page = 1, courseId, status } = q;
    const data = await bookingService.listForAdmin({ page, courseId, status });
    const [courses] = await Promise.all([require("../db").course.findMany({ orderBy: { createdAt: "desc" }, select: { id: true, title: true } })]);
    const base = `/bookings?${new URLSearchParams({ ...(courseId ? { courseId: String(courseId) } : {}), ...(status ? { status } : {}) }).toString()}&`;
    return res.render("bookings/index", {
      title: t.bookings.adminTitle,
      bookings: data.items,
      courses,
      filters: { courseId: courseId || "", status: status || "" },
      pageCtx: { page: data.page, pageCount: data.pageCount, total: data.total, base },
    });
  } catch (err) {
    return next(err);
  }
}

async function mineList(req, res, next) {
  try {
    const q = parse(schemas.listQuery, { page: req.query.page });
    const data = await bookingService.listForTrainee(req.currentUser.id, { page: q.page || 1 });
    return res.render("bookings/mine", {
      title: t.bookings.myBookings,
      bookings: data.items,
      pageCtx: { page: data.page, pageCount: data.pageCount, total: data.total, base: "/bookings/mine?" },
    });
  } catch (err) {
    return next(err);
  }
}

async function create(req, res, next) {
  try {
    const { courseId } = parse(schemas.bookingCreate, req.body);
    await bookingService.create(req.currentUser, courseId);
    req.flash("success", t.courses.messages.booked);
    return res.redirect("/bookings/mine");
  } catch (err) {
    if (err && err.status === 409) {
      req.flash("error", err.message);
      return res.redirect("/bookings/mine");
    }
    return next(err);
  }
}

async function confirm(req, res, next) {
  try {
    const bookingId = Number(req.params.bookingId);
    if (!Number.isInteger(bookingId) || bookingId <= 0) return next();
    await bookingService.confirm(req.currentUser, bookingId);
    req.flash("success", t.bookings.messages.confirmed);
    return res.redirect("back");
  } catch (err) {
    return next(err);
  }
}

async function cancel(req, res, next) {
  try {
    const bookingId = Number(req.params.bookingId);
    if (!Number.isInteger(bookingId) || bookingId <= 0) return next();
    await bookingService.cancel(req.currentUser, bookingId);
    req.flash("success", t.bookings.messages.cancelled);
    return res.redirect("back");
  } catch (err) {
    return next(err);
  }
}

module.exports = { adminList, mineList, create, confirm, cancel };
