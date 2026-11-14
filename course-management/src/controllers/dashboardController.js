// Dashboard (role-aware home pages).
const dashboardService = require("../services/dashboardService");
const attendanceService = require("../services/attendanceService");
const t = require("../locales/ar");

const getDashboard = async (req, res, next) => {
  try {
    const user = req.currentUser;
    if (user.role === "ADMIN") {
      const stats = await dashboardService.getAdminStats();
      return res.render("dashboard/admin", { title: t.dashboard.title, stats });
    }
    if (user.role === "TRAINER") {
      const stats = await dashboardService.getTrainerStats(user.id);
      return res.render("dashboard/trainer", { title: t.dashboard.title, stats });
    }
    const stats = await dashboardService.getTraineeStats(user.id);
    return res.render("dashboard/trainee", { title: t.dashboard.title, stats });
  } catch (err) {
    return next(err);
  }
};

module.exports = { getDashboard };
