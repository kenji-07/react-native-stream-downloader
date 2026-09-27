import { asError, DownloaderError } from './errors';
import { connect, licenses } from './events';
import { execute } from './native';
import * as decode from './decode';

let registered = false;
let accepting = false;
let lifecycle: Promise<unknown> = Promise.resolve();
let latestTicket = 0;

export function isReady(): boolean { return registered; }

export function registration(enable: boolean): Promise<boolean> {
  const ticket = ++latestTicket;
  accepting = false;
  const operation = enable ? 'registerPlugin' : 'disablePlugin';
  const run = lifecycle.then(async () => {
    try {
      connect();
      const result = decode.bool(await execute(operation));
      registered = enable && result;
      accepting = registered && ticket === latestTicket;
      if (!enable || !result) licenses.clear();
      return result;
    } catch (error) {
      registered = false;
      accepting = false;
      licenses.clear();
      throw asError(error, operation);
    }
  });
  // A rejected lifecycle operation must not poison subsequent registration.
  lifecycle = run.catch(() => undefined);
  return run;
}

export async function call<T>(operation: string, prepare: () => Record<string, unknown>, decodeResult: (value: unknown) => T, requiresRegistration = true): Promise<T> {
  try {
    if (requiresRegistration && (!registered || !accepting)) throw new DownloaderError('E_NOT_REGISTERED', 'Call and await registerPlugin() before using Stream Downloader.', operation);
    const result = await execute(operation, prepare());
    try { return decodeResult(result); }
    catch { throw new DownloaderError('E_BRIDGE', `Native ${operation} returned an invalid response.`, operation); }
  } catch (error) { throw asError(error, operation); }
}
