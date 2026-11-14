// Admin user-management routes (all ADMIN-only).
const express = require("express");
const userController = require("../controllers/userController");
const { requireRole } = require("../middleware/auth");

const router = express.Router();
const adminOnly = requireRole("ADMIN");

router.get("/", adminOnly, userController.list);
router.get("/new", adminOnly, userController.newForm);
router.post("/", adminOnly, userController.create);
router.get("/:userId/edit", adminOnly, userController.editForm);
router.put("/:userId", adminOnly, userController.update);
router.delete("/:userId", adminOnly, userController.remove);

module.exports = router;
