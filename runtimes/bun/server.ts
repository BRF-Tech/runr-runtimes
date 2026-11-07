/**
 * RunR Bun runtime: serves the RunR HTTP contract on $PORT and calls the function's handler for
 * every request, or (RUNR_MODE=schedule) calls it once, prints the result and exits.
 *
 * The handler is the export RUNR_HANDLER (default "handler") of RUNR_FILENAME in /app/code, a
 * TypeScript or JavaScript module (ES or CommonJS; a default export when it is the only
 * function): export async function handler(event, context). event is the request body parsed as
 * JSON, else { body }; context holds method, path and headers (lower-case names). An object
 * result with statusCode / headers / body is a response envelope; anything else is the body
 * (JSON unless it is a string with another Content-Type). Types are stripped, not checked.
 */

const CODE_DIR = '/app/code';
const HANDLER_NAME = process.env.RUNR_HANDLER || 'handler';
const FILENAME = process.env.RUNR_FILENAME || 'main.ts';

type Handler = (event: unknown, context: unknown) => unknown;

const userModule = await import(`${CODE_DIR}/${FILENAME}`);
const handlerFn: Handler | undefined = [
  userModule[HANDLER_NAME],
  userModule.default?.[HANDLER_NAME],
  typeof userModule.default === 'function' ? userModule.default : undefined,
].find((candidate) => typeof candidate === 'function');
if (!handlerFn) {
  console.error(`Error: handler '${HANDLER_NAME}' not found in ${FILENAME}`);
  process.exit(1);
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, PATCH, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Max-Age': '86400',
};

function respond(result: unknown): Response {
  const envelope = result !== null && typeof result === 'object' ? (result as Record<string, unknown>) : undefined;
  const status = typeof envelope?.statusCode === 'number' ? envelope.statusCode : 200;
  const custom = envelope?.headers && typeof envelope.headers === 'object' ? (envelope.headers as Record<string, unknown>) : {};
  const body = envelope && envelope.body !== undefined ? envelope.body : result;

  // user headers override the defaults, whatever their case
  const headers: Record<string, string> = { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' };
  for (const [name, value] of Object.entries(custom)) {
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === name.toLowerCase()) delete headers[key];
    }
    headers[name] = String(value);
  }
  const contentType = Object.entries(headers).find(([k]) => k.toLowerCase() === 'content-type')?.[1] ?? '';
  const text = typeof body === 'string' && !contentType.includes('application/json') ? body : (JSON.stringify(body) ?? 'null');
  const code = status >= 100 && status <= 999 ? status : 500;
  return new Response(code === 204 || code === 304 ? null : text, { status: code, headers });
}

if (process.env.RUNR_MODE === 'schedule') {
  try {
    const result = await handlerFn({ trigger: 'schedule' }, { mode: 'schedule' });
    console.log(result !== null && typeof result === 'object' ? JSON.stringify(result) : String(result));
    process.exit(0);
  } catch (err) {
    console.error(`Error: ${err instanceof Error ? err.stack || err.message : String(err)}`);
    process.exit(1);
  }
}

const port = parseInt(process.env.PORT || '8080', 10);
Bun.serve({
  port,
  hostname: '0.0.0.0',
  // a request may run as long as the function's timeout: no idle limit of Bun's own
  idleTimeout: 0,
  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname + url.search;
    let response: Response;

    if (req.headers.has('k-network-probe') || req.headers.has('k-kubelet-probe')) {
      // Knative probe: not passed to the handler
      response = new Response('ok');
    } else if (req.method === 'OPTIONS') {
      // CORS preflight
      response = new Response(null, { status: 204, headers: CORS });
    } else {
      const body = await req.text();
      let event: unknown;
      try {
        event = body ? JSON.parse(body) : {};
      } catch {
        event = { body };
      }
      const context = { method: req.method, path, headers: Object.fromEntries(req.headers) };
      try {
        response = respond(await handlerFn(event, context));
      } catch (err) {
        console.error(err);
        const error = err instanceof Error ? { error: err.message, stack: err.stack } : { error: String(err) };
        response = Response.json(error, { status: 500, headers: { 'Access-Control-Allow-Origin': '*' } });
      }
    }
    console.log(`[runr] ${req.method} ${path} ${response.status}`);
    return response;
  },
});
console.log(`RunR Bun runtime listening on :${port}`);
