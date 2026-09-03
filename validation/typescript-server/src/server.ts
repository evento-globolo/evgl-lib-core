import { z } from "zod";
import { RequestMetaSchema } from "@evento-globolo/evgl-validation";

const token = z.string().trim().min(1).max(128);

export const TrustedActorSchema = z.object({
  userId: token,
  tenantId: token.optional(),
  roles: z.array(token).max(64),
}).strict();

export const ServerRequestContextSchema = RequestMetaSchema.extend({
  actor: TrustedActorSchema,
  sourceIp: z.union([z.ipv4(), z.ipv6()]).optional(),
}).strict();

export const InternalCommandSchema = z.object({
  operationId: z.string().trim().min(1).max(256),
  idempotencyKey: token.optional(),
  context: ServerRequestContextSchema,
  payload: z.unknown(),
}).strict();

export type TrustedActor = z.infer<typeof TrustedActorSchema>;
export type ServerRequestContext = z.infer<typeof ServerRequestContextSchema>;
export type InternalCommand = z.infer<typeof InternalCommandSchema>;
