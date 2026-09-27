import type { DownloadStatus } from '../types';
import * as decode from './decode';
import * as v from './validation';
import { listen, native, runtimeId } from './native';
import { LicenseCallbacks } from './licenseCallbacks';

export interface EventMap {
  onError: string;
  onDownloadProgress: DownloadStatus[];
  onDownloadEnd: DownloadStatus;
}
export type EventName = keyof EventMap;
type Listener = (payload: never) => void;
const listeners: Record<EventName, Set<Listener>> = {
  onError: new Set(), onDownloadProgress: new Set(), onDownloadEnd: new Set(),
};
let connected = false;
let lastSequence = 0;
export const licenses = new LicenseCallbacks(message => dispatch('onError', message));

function dispatch<K extends EventName>(event: K, payload: EventMap[K]): void {
  for (const callback of [...listeners[event]]) {
    try { callback(payload as never); }
    catch (error) {
      // Application listener exceptions must not prevent other listeners or
      // internal cleanup. Preserve the exception for React Native's handler.
      setTimeout(() => { throw error; }, 0);
    }
  }
}

function receive(value: unknown): void {
  let event: EventName;
  let payload: EventMap[EventName];
  try {
    const envelope = v.object(value, 'event envelope');
    if (envelope.runtimeId !== runtimeId) return;
    const sequence = v.integer(envelope.sequence, 'event sequence', 1);
    if (sequence <= lastSequence) return;
    if (envelope.event !== 'onError' && envelope.event !== 'onDownloadProgress' && envelope.event !== 'onDownloadEnd') throw new Error('Unknown native event.');
    event = envelope.event;
    payload = event === 'onError' ? v.string(envelope.payload, 'error event')
      : event === 'onDownloadProgress' ? decode.array(envelope.payload, decode.status) : decode.status(envelope.payload);
    lastSequence = sequence;
  } catch { dispatch('onError', 'Invalid StreamDownloader native event.'); return; }
  if (event === 'onDownloadEnd') licenses.terminal((payload as DownloadStatus).id);
  dispatch(event, payload);
}

export function connect(): void {
  if (connected) return;
  const subscription = listen('StreamDownloaderEvent', receive);
  try { listen('StreamDownloaderLicenseRequest', value => licenses.handle(value)); }
  catch (error) { subscription.remove(); throw error; }
  connected = true;
  // These two process-lifetime subscriptions also release DRM callback leases
  // when the application has no public event hooks mounted.
  native().setProgressEnabled(runtimeId, listeners.onDownloadProgress.size > 0);
}

export function subscribe<K extends EventName>(event: K, callback: (payload: EventMap[K]) => void): () => void {
  connect();
  const listener = callback as Listener;
  listeners[event].add(listener);
  if (event === 'onDownloadProgress' && listeners[event].size === 1) native().setProgressEnabled(runtimeId, true);
  return () => {
    const deleted = listeners[event].delete(listener);
    if (deleted && event === 'onDownloadProgress' && listeners[event].size === 0) native().setProgressEnabled(runtimeId, false);
  };
}
