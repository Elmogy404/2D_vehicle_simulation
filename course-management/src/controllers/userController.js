// Admin users management controller (trainers/admins).
const userService = require("../services/userService");
const { parse, schemas } = require("../validators");
const t = require("../locales/ar");

async function list(req, res, next) {
  try {
    const q = parse(schemas.listQuery, { page: req.query.page, search: req.query.search, role: req.query.role });
    const { page = 1, search = "", role } = q;
    const data = await userService.list(req.currentUser, { page, search, role });
    const params = new URLSearchParams({ ...(search ? { search } : {}), ...(role ? { role } : {}) });
    return res.render("users/list", {
      title: t.users.title,
      users: data.items,
      pageCtx: { page: data.page, pageCount: data.pageCount, total: data.total, base: `/users?${params.toString()}&` },
      search,
      roleFilter: role || "",
    });
  } catch (err) {
    return next(err);
  }
}

async function newForm(req, res) {
  res.render("users/form", {
    title: t.users.newUser,
    user: { role: "TRAINER" },
    fieldErrors: {},
    formAction: `/users`,
    isEdit: false,
  });
}

async function create(req, res, next) {
  try {
    let data;
    try {
      data = parse(schemas.userCreate, req.body);
    } catch (err) {
      if (err.fieldErrors) {
        return res.status(422).render("users/form", {
          title: t.users.newUser,
          user: req.body,
          fieldErrors: err.fieldErrors,
          formAction: `/users`,
          isEdit: false,
        });
      }
      throw err;
    }
    await userService.create(req.currentUser, data);
    req.flash("success", t.users.messages.created);
    return res.redirect("/users");
  } catch (err) {
    if (err && err.fieldErrors) {
      return res.status(422).render("users/form", {
        title: t.users.newUser,
        user: req.body,
        fieldErrors: err.fieldErrors,
        formAction: `/users`,
        isEdit: false,
      });
    }
    return next(err);
  }
}

async function editForm(req, res, next) {
  try {
    const userId = Number(req.params.userId);
    if (!Number.isInteger(userId) || userId <= 0) return next();
    const user = await userService.getById(req.currentUser, userId);
    return res.render("users/form", {
      title: t.users.editUser,
      user,
      fieldErrors: {},
      formAction: `/users/${userId}`,
      isEdit: true,
    });
  } catch (err) {
    return next(err);
  }
}

async function update(req, res, next) {
  try {
    const userId = Number(req.params.userId);
    if (!Number.isInteger(userId) || userId <= 0) return next();
    let data;
    try {
      data = parse(schemas.userUpdate, req.body);
    } catch (err) {
      if (err.fieldErrors) {
        return res.status(422).render("users/form", {
          title: t.users.editUser,
          user: { id: userId, name: req.body.name, email: req.body.email },
          fieldErrors: err.fieldErrors,
          formAction: `/users/${userId}`,
          isEdit: true,
        });
      }
      throw err;
    }
    await userService.update(req.currentUser, userId, data);
    req.flash("success", t.users.messages.updated);
    return res.redirect("/users");
  } catch (err) {
    return next(err);
  }
}

async function remove(req, res, next) {
  try {
    const userId = Number(req.params.userId);
    if (!Number.isInteger(userId) || userId <= 0) return next();
    await userService.remove(req.currentUser, userId);
    req.flash("success", t.users.messages.deleted);
    return res.redirect("/users");
  } catch (err) {
    if (err && (err.status === 409 || err.status === 403)) {
      req.flash("error", err.message);
      return res.redirect("/users");
    }
    return next(err);
  }
}

module.exports = { list, newForm, create, editForm, update, remove };
