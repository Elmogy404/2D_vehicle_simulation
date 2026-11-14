// Centralised error types + rendering helpers for MVC routes.
class AppError extends Error {
  /**
   * @param {string} message user-facing (Arabic) message
   * @param {number} status HTTP status
   * @param {boolean} show whether message is safe to show to the user
   */
  constructor(message, status = 500, options = {}) {
    super(message);
    this.name = "AppError";
    this.status = status;
    this.show = options.show !== false && status < 500;
    this.fieldErrors = options.fieldErrors || null;
    this.redirectTo = options.redirectTo || null;
  }
}

class ValidationError extends Error {
  constructor(fieldErrors, message = "Validation failed") {
    super(message);
    this.name = "ValidationError";
    this.status = 422;
    this.fieldErrors = fieldErrors;
  }
}

class NotFoundError extends AppError {
  constructor(message = "Not found") {
    super(message, 404);
  }
}

class ForbiddenError extends AppError {
  constructor(message = "Forbidden") {
    super(message, 403);
  }
}

class ConflictError extends AppError {
  constructor(message) {
    super(message, 409);
  }
}

module.exports = { AppError, ValidationError, NotFoundError, ForbiddenError, ConflictError };
