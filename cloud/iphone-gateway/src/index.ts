// Entry module. workerd validates every named export of the main module as a
// handler or class, so this file deliberately exports only the fetch handler.
// All constants, types, and factories live in gateway.ts.
import { defaultRuntime, handleRequest } from "./gateway";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, defaultRuntime(env));
  },
} satisfies ExportedHandler<Env>;
