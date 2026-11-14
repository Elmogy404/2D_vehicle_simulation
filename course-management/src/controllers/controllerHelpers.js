// Small helpers shared by controllers.
const { ValidationError } = require("./errors");

/**
 * Renders a page or re-renders on ValidationError with field errors + entered values.
 * @returns {Promise<void>} rejects with unknown errors
 */
async function renderOr422(req, res, view, renderData, parseFn) {
  try {
    const data = parseFn();
    return { data, responded: false };
  } catch (err) {
    if (err && err.fieldErrors) {
      res.status(422);
      res.render(view, {
        ...renderData,
        fieldErrors: err.fieldErrors,
        values: renderData.values,
      });
      return { responded: true };
    }
    throw err;
  }
}

module.exports = { renderOr422 };
