/**
 * Shared toJSON transform: exposes `id` (string), and removes `_id`, `__v`,
 * and any `password` field that may have leaked into a document. Applied to
 * every model so API payloads are consistent and safe.
 *
 * Left as an inferred literal (not annotated as `SchemaOptions`) so it stays
 * structurally assignable when spread into each model-specific `new Schema<T>`.
 */
export const jsonSchemaOptions = {
  toJSON: {
    virtuals: true,
    versionKey: false,
    transform: (_doc: unknown, ret: Record<string, unknown>): Record<string, unknown> => {
      delete ret._id;
      delete ret.password;
      return ret;
    },
  },
};
