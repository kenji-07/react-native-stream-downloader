import { NativeEventEmitter, NativeModules, Platform } from 'react-native';
import { DownloaderError } from './errors';

export interface Command {
  version: 1;
  runtimeId: string;
  operationId: string;
  method: string;
  params: Record<string, unknown>;
}

interface NativeDownloader {
  execute(command: Command): Promise<unknown>;
  completeLicenseRequest(response: Record<string, unknown>): Promise<unknown>;
  setProgressEnabled(runtimeId: string, enabled: boolean): void;
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export const platform = Platform.OS;
// Correlation only. This value is neither an authentication token nor an asset ID.
export const runtimeId = `js-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
let sequence = 0;
let emitter: NativeEventEmitter | undefined;

export function native(): NativeDownloader {
  const candidate: unknown = NativeModules.StreamDownloader;
  if (platform !== 'android' && platform !== 'ios') {
    throw new DownloaderError('E_UNSUPPORTED_CAPABILITY', 'Stream Downloader requires Android or iOS.');
  }
  if (candidate === null || typeof candidate !== 'object' ||
      ['execute', 'completeLicenseRequest', 'setProgressEnabled', 'addListener', 'removeListeners']
        .some(key => typeof (candidate as Record<string, unknown>)[key] !== 'function')) {
    throw new DownloaderError('E_LINKING', 'StreamDownloader native module is unavailable. Install native dependencies and rebuild the application.');
  }
  return candidate as NativeDownloader;
}

export function execute(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
  return native().execute({ version: 1, runtimeId, operationId: `${runtimeId}:${++sequence}`, method, params });
}

export function listen(channel: string, callback: (value: unknown) => void): { remove(): void } {
  emitter ??= new NativeEventEmitter(native());
  return emitter.addListener(channel, callback);
}
