// Auth routes. Rate limiters injected by app.js.
const express = require("express");
const authController = require("../controllers/authController");
const { requireAuth } = require("../middleware/auth");
const dashboardController = require("../controllers/dashboardController");

module.exports = (loginLimiter, registerLimiter) => {
  const router = express.Router();

  router.get("/login", authController.getLogin);
  router.post("/login", authController.postLogin(loginLimiter));
  router.get("/register", authController.getRegister);
  router.post("/register", authController.postRegister(registerLimiter));
  router.post("/logout", requireAuth, authController.postLogout);

  router.get("/", (req, res) => res.redirect("/dashboard"));
  router.get("/dashboard", requireAuth, dashboardController.getDashboard);

  return router;
};
