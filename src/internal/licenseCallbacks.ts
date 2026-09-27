import type { DRMConfig } from '../types';
import { native, runtimeId } from './native';
import * as v from './validation';

type Callback = NonNullable<DRMConfig['getLicense']>;
interface Entry { callback: Callback; pending: number; assets: Set<string> }
interface Request { assetId: string; finish: (result?: Record<string, unknown>) => void }

function validCKC(value: unknown): value is string {
  if (typeof value !== 'string' || value.length === 0 || value.length > 16 * 1024 * 1024 || value.length % 4 !== 0) return false;
  const padding = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0;
  // A repeated four-character regex group can exhaust the JS engine's stack
  // for large licenses. Scan only the alphabet, then allow terminal padding.
  return !/[^A-Za-z0-9+/]/.test(value.slice(0, value.length - padding));
}

export class LicenseCallbacks {
  private readonly identities = new WeakMap<Callback, string>();
  private readonly entries = new Map<string, Entry>();
  private readonly requests = new Map<string, Request>();
  private lastSequence = 0;
  private readonly earlyTerminals = new Set<string>();
  private nextId = 0;

  constructor(private readonly report: (message: string) => void) {}

  acquire(callback: Callback): { ref: string; bind: (assetId?: string) => void } {
    let ref = this.identities.get(callback);
    if (!ref) { ref = `${runtimeId}:callback:${++this.nextId}`; this.identities.set(callback, ref); }
    const key = ref;
    const entry = this.entries.get(key) ?? { callback, pending: 0, assets: new Set<string>() };
    this.entries.set(key, entry);
    entry.pending++;
    let bound = false;
    return { ref: key, bind: assetId => {
      if (bound) return;
      bound = true;
      entry.pending--;
      if (assetId && !this.earlyTerminals.has(assetId)) entry.assets.add(assetId);
      this.collect(key, entry);
      if (![...this.entries.values()].some(e => e.pending > 0)) this.earlyTerminals.clear();
    } };
  }

  terminal(assetId: string): void {
    if ([...this.entries.values()].some(e => e.pending > 0)) this.earlyTerminals.add(assetId);
    for (const [key, entry] of this.entries) { entry.assets.delete(assetId); this.collect(key, entry); }
    for (const request of this.requests.values()) if (request.assetId === assetId) request.finish();
  }

  clear(): void {
    for (const request of this.requests.values()) request.finish();
    this.entries.clear();
    this.earlyTerminals.clear();
    // The native runtime sequence remains monotonic across disable/register.
  }

  private collect(key: string, entry: Entry): void {
    if (entry.pending === 0 && entry.assets.size === 0 && this.entries.get(key) === entry) this.entries.delete(key);
  }

  handle(value: unknown): void {
    let request: Record<string, unknown>;
    try {
      request = v.object(value, 'license request');
      if (request.runtimeId !== runtimeId) return;
      v.integer(request.sequence, 'license sequence', 1);
      for (const field of ['requestId', 'callbackRef', 'assetId', 'spcString', 'contentId', 'licenseUrl', 'loadedLicenseUrl']) {
        v.string(request[field], field, !['licenseUrl', 'contentId', 'loadedLicenseUrl'].includes(field));
      }
    } catch { this.report('Invalid native license request.'); return; }
    const requestId = request.requestId as string;
    if ((request.sequence as number) <= this.lastSequence) return;
    this.lastSequence = request.sequence as number;
    const entry = this.entries.get(request.callbackRef as string);
    let settled = false;
    const finish = (result?: Record<string, unknown>): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      this.requests.delete(requestId);
      if (result) {
        try {
          void native().completeLicenseRequest({ runtimeId, requestId, ...result }).catch(() => this.report('Could not deliver the DRM callback response to native code.'));
        } catch { this.report('Could not deliver the DRM callback response to native code.'); }
      }
    };
    const timer = setTimeout(() => finish({ error: { code: 'E_DRM_TIMEOUT', message: 'DRM callback timed out.' } }), 60000);
    this.requests.set(requestId, { assetId: request.assetId as string, finish });
    if (!entry) { finish({ error: { code: 'E_DRM_CALLBACK_UNAVAILABLE', message: 'DRM callback is no longer available.' } }); return; }
    // Promise.resolve().then also contains synchronous application exceptions.
    void Promise.resolve().then(() => {
      if (settled) return undefined;
      return entry.callback(request.spcString as string, request.contentId as string, request.licenseUrl as string, request.loadedLicenseUrl as string);
    }).then(result => {
      if (settled) return;
      // Canonical padded Base64; native decodes the CKC exactly once.
      if (!validCKC(result)) {
        finish({ error: { code: 'E_DRM_LICENSE', message: 'getLicense must return a Base64 CKC string.' } });
      } else finish({ ckcBase64: result });
    }, () => finish({ error: { code: 'E_DRM_LICENSE', message: 'The application DRM callback failed.' } }));
  }
}
