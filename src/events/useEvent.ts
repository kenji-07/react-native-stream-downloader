import { useEffect, useRef } from 'react';
import type { DownloadStatus } from '../types';
import { subscribe } from '../internal/events';
import type { EventMap, EventName } from '../internal/events';
import { DownloaderError } from '../internal/errors';

export function useEvent(event: 'onError', callback: (error: string) => void): void;
export function useEvent(event: 'onDownloadProgress', callback: (statuses: DownloadStatus[]) => void): void;
export function useEvent(event: 'onDownloadEnd', callback: (status: DownloadStatus) => void): void;
export function useEvent<K extends EventName>(event: K, callback: (payload: EventMap[K]) => void): void {
  if (!['onError', 'onDownloadProgress', 'onDownloadEnd'].includes(event) || typeof callback !== 'function') {
    throw new DownloaderError('E_INVALID_ARGUMENT', 'useEvent requires a documented event name and callback.');
  }
  const current = useRef(callback);
  useEffect(() => { current.current = callback; }, [callback]);
  useEffect(() => subscribe(event, payload => current.current(payload)), [event]);
}
