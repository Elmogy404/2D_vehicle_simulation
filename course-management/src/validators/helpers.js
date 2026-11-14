// Validation helpers shared by zod schema modules.
const { ValidationError } = require("../errors");

function buildValidationError(fieldErrors, message) {
  return new ValidationError({ ...fieldErrors }, message || "الحقول المدخلة فيها أخطاء");
}

module.exports = { buildValidationError };
