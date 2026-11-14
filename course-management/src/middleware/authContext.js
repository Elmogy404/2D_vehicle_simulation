// Loads the authenticated user from the session into req.currentUser / res.locals.
// Runs after the session middleware and before the route handlers.
const prisma = require("../db");

module.exports = async function authContext(req, res, next) {
  try {
    const userId = req.session && req.session.userId;
    if (userId) {
      const user = await prisma.user.findUnique({ where: { id: Number(userId) } });
      if (user) {
        req.currentUser = { id: user.id, name: user.name, email: user.email, role: user.role };
        res.locals.currentUser = req.currentUser;
      } else {
        delete req.session.userId;
      }
    }
    return next();
  } catch (err) {
    return next(err);
  }
};
