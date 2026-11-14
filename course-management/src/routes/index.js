// Convenience barrel (not used by app.js; helpers for manual import).
module.exports = {
  auth: require("./auth.routes"),
  users: require("./user.routes"),
  courses: require("./course.routes"),
  bookings: require("./booking.routes"),
  attendance: require("./attendance.routes"),
};
