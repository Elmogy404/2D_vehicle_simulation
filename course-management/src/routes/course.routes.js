// Courses routes: role-aware list/details; full CRUD admin-only.
const express = require("express");
const courseController = require("../controllers/courseController");
const { requireAuth, requireRole } = require("../middleware/auth");

const router = express.Router();
const adminOnly = requireRole("ADMIN");

router.get("/", requireAuth, courseController.list);
router.get("/new", adminOnly, courseController.newForm);   // before /:courseId
router.post("/", adminOnly, courseController.create);
router.get("/:courseId/edit", adminOnly, courseController.editForm);
router.put("/:courseId", adminOnly, courseController.update);
router.delete("/:courseId", adminOnly, courseController.remove);
router.get("/:courseId", requireAuth, courseController.show);

module.exports = router;
