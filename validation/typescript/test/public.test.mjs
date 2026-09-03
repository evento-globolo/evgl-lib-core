import assert from "node:assert/strict";
import test from "node:test";
import { parsePublic, safeParsePublic } from "../dist/public.js";

test("accepts shared request metadata", () => {
  assert.deepEqual(parsePublic("request-meta", {requestId: "req-1", traceId: "trace-1"}), {requestId: "req-1", traceId: "trace-1"});
});

test("rejects unknown browser supplied fields", () => {
  assert.equal(safeParsePublic("request-meta", {requestId: "req-1", traceId: "trace-1", userId: "must-be-server-established"}).success, false);
});
