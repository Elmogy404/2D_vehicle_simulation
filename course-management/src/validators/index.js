// Zod schema definitions + parse helper for every form input.
const { z } = require("zod");
const t = require("../locales/ar");

const email = z
  .string({ message: t.validation.required })
  .trim()
  .min(1, t.validation.required)
  .email(t.validation.email);

const password = z
  .string({ message: t.validation.required })
  .min(8, t.validation.passwordShort);

const isoDate = z
  .string({ message: t.validation.invalidDate })
  .trim()
  .regex(/^\d{4}-\d{2}-\d{2}$/, t.validation.invalidDate)
  .transform((value) => new Date(`${value}T00:00:00.000Z`));

const schemas = {
  login: z.object({
    email,
    password: z.string({ message: t.validation.required }).min(1, t.validation.required),
  }),

  register: z.object({
    name: z.string({ message: t.validation.required }).trim().min(2, t.validation.titleShort),
    email,
    password,
    confirmPassword: z.string({ message: t.validation.required }).min(1, t.validation.required),
  }),

  courseForm: z.object({
    title: z.string({ message: t.validation.required }).trim().min(3, t.validation.titleShort),
    description: z
      .string({ message: t.validation.required })
      .trim()
      .min(10, t.validation.descriptionShort),
    price: z.coerce
      .number({ message: t.validation.price })
      .refine((v) => Number.isFinite(v) && Number.isInteger(v * 100), t.validation.price)
      .refine((v) => v >= 0, t.validation.price),
    trainerId: z.coerce.number({ message: t.validation.selectTrainer }).int().positive(t.validation.selectTrainer),
  }),

  bookingCreate: z.object({
    courseId: z.coerce.number({ message: t.validation.required }).int().positive(t.validation.notFound),
  }),

  sessionForm: z.object({
    date: isoDate,
    title: z.string({ message: t.validation.required }).trim().optional().default(""),
  }),

  attendanceMark: z.object({
    traineeId: z.coerce.number({ message: t.validation.required }).int().positive(),
    status: z.enum(["PRESENT", "ABSENT"], { message: t.validation.selectAttendance }),
  }),

  userCreate: z.object({
    name: z.string({ message: t.validation.required }).trim().min(2, t.validation.titleShort),
    email,
    password,
    role: z.enum(["ADMIN", "TRAINER"], { message: t.validation.selectRole }),
  }),

  userUpdate: z.object({
    name: z.string({ message: t.validation.required }).trim().min(2, t.validation.titleShort),
    email,
    password: z
      .string()
      .optional()
      .transform((v) => v || "")
      .refine((v) => v.length === 0 || v.length >= 8, t.validation.passwordShort),
  }),

  listQuery: z.object({
    page: z.coerce.number({ message: t.validation.invalidNumber }).int().min(1, t.validation.invalidNumber).optional().catch(undefined),
    search: z.string().trim().max(100).optional().catch(undefined),
    role: z.enum(["ADMIN", "TRAINER", "TRAINEE"]).optional().catch(undefined),
    status: z.enum(["PENDING", "CONFIRMED", "CANCELLED"]).optional().catch(undefined),
    courseId: z.coerce.number({ message: t.validation.invalidNumber }).int().positive(t.validation.notFound).optional().catch(undefined),
  }),
};

// safeParse -> fieldError map; throws ValidationError when invalid.
function parse(schema, payload) {
  const result = schema.safeParse(payload ?? {});
  if (result.success) return result.data;
  const fieldErrors = {};
  for (const issue of result.error.issues) {
    const key = issue.path.join(".") || "_form";
    (fieldErrors[key] = fieldErrors[key] || []).push(issue.message);
  }
  const err = new Error("Validation failed");
  err.fieldErrors = fieldErrors;
  throw err;
}

module.exports = { parse, schemas };
