// Sessions & attendance routes.
const express = require("express");
const attendanceController = require("../controllers/attendanceController");
const { requireAuth, requireRole } = require("../middleware/auth");

const router = express.Router();

// course + sessions (admin or trainer owner; ownership inside the service)
router.get("/courses/:courseId/sessions", requireRole("ADMIN", "TRAINER"), attendanceController.sessionsPage);
router.post("/courses/:courseId/sessions", requireRole("ADMIN", "TRAINER"), attendanceController.createSession);

// trainee's own record (strictly own in the service)
router.get("/my-attendance", requireRole("TRAINEE"), attendanceController.myAttendance);

// admin route
router.get("/courses/:courseId/attendance", requireRole("ADMIN"), attendanceController.courseOverview);

// marking routes
router.get("/sessions/:sessionId", requireRole("ADMIN", "TRAINER"), attendanceController.markPage);
router.post("/sessions/:sessionId/attendance", requireRole("TRAINER"), attendanceController.markSave);

module.exports = router;
