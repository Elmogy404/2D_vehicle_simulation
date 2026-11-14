// Courses controller (admin CRUD, role-aware listing/details).
const courseService = require("../services/courseService");
const bookingService = require("../services/bookingService");
const userService = require("../services/userService");
const prisma = require("../db");
const { parse, schemas } = require("../validators");
const t = require("../locales/ar");

function pageParams(req) {
  const parsed = parse(schemas.listQuery, { page: req.query.page, search: req.query.search });
  return { page: parsed.page || 1, search: parsed.search || "" };
}

async function list(req, res, next) {
  try {
    const { page, search } = pageParams(req);
    let data;
    if (req.currentUser.role === "TRAINER") {
      data = await courseService.listOwnCourses(req.currentUser.id, { page });
    } else {
      if (search) {
        // keep search for admin/trainee only
        const found = await courseService.listAll({ page: 1, pageSize: 1000 });
        data = { ...found, items: found.items.filter((c) => c.title.includes(search)) };
      } else {
        data = await courseService.listAll({ page });
      }
    }
    const base = `/courses?${new URLSearchParams({ ...(search ? { search } : {}) }).toString()}&`;
    return res.render("courses/list", {
      title: t.courses.listTitle,
      courses: data.items,
      pageCtx: { page: data.page, pageCount: data.pageCount, total: data.total, base },
      search,
    });
  } catch (err) {
    return next(err);
  }
}

async function show(req, res, next) {
  try {
    const courseId = Number(req.params.courseId);
    if (!Number.isInteger(courseId) || courseId <= 0) return next();
    const course = await courseService.getForCoursePage(req.currentUser, courseId);
    let myBooking = null;
    if (req.currentUser.role === "TRAINEE") {
      myBooking = await prisma.booking.findUnique({
        where: { courseId_traineeId: { courseId, traineeId: req.currentUser.id } },
        select: { id: true, status: true },
      });
    }
    return res.render("courses/details", { title: course.title, course, myBooking });
  } catch (err) {
    return next(err);
  }
}

async function listTrainersForForm(actor) {
  const { items } = await userService.list(actor, { role: "TRAINER", pageSize: 1000, page: 1 });
  return items;
}

async function newForm(req, res) {
  const trainers = await listTrainersForForm(req.currentUser);
  res.render("courses/form", {
    title: t.courses.newCourse,
    course: {},
    trainers,
    fieldErrors: {},
    formAction: "/courses",
    isEdit: false,
  });
}

async function create(req, res, next) {
  try {
    let data;
    try {
      data = parse(schemas.courseForm, req.body);
    } catch (err) {
      if (err.fieldErrors) {
        const trainers = await listTrainersForForm(req.currentUser);
        return res.status(422).render("courses/form", {
          title: t.courses.newCourse,
          course: req.body,
          trainers,
          fieldErrors: err.fieldErrors,
          formAction: "/courses",
          isEdit: false,
        });
      }
      throw err;
    }
    await courseService.create(req.currentUser, data);
    req.flash("success", t.courses.messages.created);
    return res.redirect("/courses");
  } catch (err) {
    return next(err);
  }
}

async function editForm(req, res, next) {
  try {
    const courseId = Number(req.params.courseId);
    if (!Number.isInteger(courseId) || courseId <= 0) return next();
    const course = await courseService.getByIdForEdit(req.currentUser, courseId);
    const trainers = await listTrainersForForm(req.currentUser);
    return res.render("courses/form", {
      title: t.courses.editCourse,
      course: {
        id: course.id,
        title: course.title,
        description: course.description,
        price: course.price.toFixed ? course.price.toFixed(2) : String(course.price),
        trainerId: course.trainerId,
      },
      trainers,
      fieldErrors: {},
      formAction: `/courses/${courseId}`,
      isEdit: true,
    });
  } catch (err) {
    return next(err);
  }
}

async function update(req, res, next) {
  try {
    const courseId = Number(req.params.courseId);
    if (!Number.isInteger(courseId) || courseId <= 0) return next();
    let data;
    try {
      data = parse(schemas.courseForm, req.body);
    } catch (err) {
      if (err.fieldErrors) {
        const trainers = await listTrainersForForm(req.currentUser);
        return res.status(422).render("courses/form", {
          title: t.courses.editCourse,
          course: { id: courseId, ...req.body },
          trainers,
          fieldErrors: err.fieldErrors,
          formAction: `/courses/${courseId}`,
          isEdit: true,
        });
      }
      throw err;
    }
    await courseService.update(req.currentUser, courseId, data);
    req.flash("success", t.courses.messages.updated);
    return res.redirect(`/courses/${courseId}`);
  } catch (err) {
    return next(err);
  }
}

async function remove(req, res, next) {
  try {
    const courseId = Number(req.params.courseId);
    if (!Number.isInteger(courseId) || courseId <= 0) return next();
    await courseService.remove(req.currentUser, courseId);
    req.flash("success", t.courses.messages.deleted);
    return res.redirect("/courses");
  } catch (err) {
    // Conflict (bookings exist) -> back to list with a clear flash message
    if (err && err.status === 409) {
      req.flash("error", err.message);
      return res.redirect("/courses");
    }
    return next(err);
  }
}

module.exports = { list, show, newForm, create, editForm, update, remove };
