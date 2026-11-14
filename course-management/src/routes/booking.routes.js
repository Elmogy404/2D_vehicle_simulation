// Bookings routes.
const express = require("express");
const bookingController = require("../controllers/bookingController");
const { requireAuth, requireRole } = require("../middleware/auth");

const router = express.Router();

router.get("/mine", requireRole("TRAINEE"), bookingController.mineList); // static before /:bookingId
router.get("/", requireRole("ADMIN"), bookingController.adminList);

router.post("/", requireRole("TRAINEE"), bookingController.create);
router.put("/:bookingId/confirm", requireRole("ADMIN"), bookingController.confirm);
router.put("/:bookingId/cancel", requireAuth, bookingController.cancel); // trainee-own or admin (service checks)

module.exports = router;
