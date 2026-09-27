import type { AvailableTracksByType, Config, DownloadedAsset, DownloadOptions, DownloadStatus, DRMConfig, DRMLicenseStatus, DRMLicenseStatusOptions } from '../types';
import * as decode from '../internal/decode';
import * as v from '../internal/validation';
import { DownloaderError } from '../internal/errors';
import { licenses } from '../internal/events';
import { platform } from '../internal/native';
import { call, isReady, registration } from '../internal/runtime';

/** Local native initialization. Accepts no arguments. */
export function registerPlugin(): Promise<boolean> {
  if (arguments.length !== 0) {
    return Promise.reject(new DownloaderError('E_INVALID_ARGUMENT', 'registerPlugin() does not accept arguments.', 'registerPlugin'));
  }
  return registration(true);
}
export function disablePlugin(): Promise<boolean> { return registration(false); }
export function isRegistered(): boolean { return isReady(); }
export function setConfig(config: Config): Promise<void> { return call('setConfig', () => ({ config: v.config(config) }), decode.nothing, false); }
export function getConfig(): Promise<Config> { return call('getConfig', () => ({}), decode.config, false); }

export async function getDRMLicenseStatus(id: string, options?: DRMLicenseStatusOptions): Promise<DRMLicenseStatus | null> {
  const result = await call('getDRMLicenseStatus', () => {
    if (options !== undefined) {
      const input = v.object(options, 'license status options');
      if (Object.keys(input).some(key => key !== 'getExpirationDate') || (input.getExpirationDate !== undefined && typeof input.getExpirationDate !== 'function')) {
        throw new DownloaderError('E_INVALID_ARGUMENT', 'Expected a getExpirationDate callback.');
      }
    }
    return { id: v.string(id, 'id', true) };
  }, value => value === null ? null : decode.licenseStatus(value));
  if (result?.scheme === 'fairplay' && result.expirationTokens?.length && options?.getExpirationDate) {
    let expiresAt: number | null;
    try { expiresAt = await options.getExpirationDate([...result.expirationTokens]); }
    catch { throw new DownloaderError('E_DRM_STATUS', 'The provider expiration check failed.', 'getDRMLicenseStatus'); }
    if (expiresAt !== null) {
      const timestamp = v.integer(expiresAt, 'license expiration date');
      return { ...result, expiresAt: timestamp, checkedAt: Date.now(), state: timestamp <= Date.now() ? 'expired' : 'valid' };
    }
  }
  return result;
}

export async function renewDRMLicense(id: string, drm?: DRMConfig): Promise<DRMLicenseStatus> {
  let lease: ReturnType<typeof licenses.acquire> | undefined;
  try {
    return await call('renewDRMLicense', () => {
      const assetId = v.string(id, 'id', true);
      if (drm === undefined) return { id: assetId };
      const { getLicense, ...configuration } = v.drm(drm, platform);
      if (getLicense) lease = licenses.acquire(getLicense);
      return { id: assetId, drm: { ...configuration, ...(lease ? { callbackRef: lease.ref } : {}) } };
    }, decode.licenseStatus);
  } finally { lease?.bind(); }
}

export async function downloadStream(url: string, options?: DownloadOptions): Promise<DownloadStatus> {
  let lease: ReturnType<typeof licenses.acquire> | undefined;
  try {
    const status = await call('downloadStream', () => {
      const normalizedURL = v.url(url);
      const normalized = v.options(options, platform);
      const { drm, ...rest } = normalized;
      if (!drm) return { url: normalizedURL, options: rest };
      const { getLicense, ...wireDRM } = drm;
      if (getLicense) lease = licenses.acquire(getLicense);
      return { url: normalizedURL, options: { ...rest, drm: { ...wireDRM, ...(lease ? { callbackRef: lease.ref } : {}) } } };
    }, decode.status);
    if (status.status === 'completed' || status.status === 'failed' || status.status === 'removed') lease?.bind();
    else lease?.bind(status.id);
    return status;
  } catch (error) { lease?.bind(); throw error; }
}

function withId(operation: string, id: string): Promise<void> {
  return call(operation, () => ({ id: v.string(id, 'id', true) }), decode.nothing);
}
function withoutId(operation: string): Promise<void> { return call(operation, () => ({}), decode.nothing); }

export function cancelDownload(id: string): Promise<void> { return withId('cancelDownload', id); }
export function cancelAllDownloads(): Promise<void> { return withoutId('cancelAllDownloads'); }
export function pauseDownload(id: string): Promise<void> { return withId('pauseDownload', id); }
export function resumeDownload(id: string): Promise<void> { return withId('resumeDownload', id); }
export function getDownloadStatus(id: string): Promise<DownloadStatus | null> {
  return call('getDownloadStatus', () => ({ id: v.string(id, 'id', true) }), value => value === null ? null : decode.status(value));
}
export function getDownloadsStatus(): Promise<DownloadStatus[]> { return call('getDownloadsStatus', () => ({}), value => decode.array(value, decode.status)); }
export function getAvailableTracks(url: string): Promise<AvailableTracksByType> { return call('getAvailableTracks', () => ({ url: v.url(url) }), decode.tracks); }
export function getDownloadedAssets(): Promise<DownloadedAsset[]> { return call('getDownloadedAssets', () => ({}), value => decode.array(value, decode.asset)); }
export function getDownloadedAsset(id: string): Promise<DownloadedAsset | null> {
  return call('getDownloadedAsset', () => ({ id: v.string(id, 'id', true) }), value => value === null ? null : decode.asset(value));
}
export function deleteDownloadedAsset(id: string): Promise<void> { return withId('deleteDownloadedAsset', id); }
export function deleteAllDownloadedAssets(): Promise<void> { return withoutId('deleteAllDownloadedAssets'); }
export function deleteQueuedItem(id: string): Promise<void> { return withId('deleteQueuedItem', id); }
export function deleteAllQueuedItems(): Promise<void> { return withoutId('deleteAllQueuedItems'); }
export function expireDownloadedAssetAt(id: string, timestamp: number): Promise<void> {
  return call('expireDownloadedAssetAt', () => ({ id: v.string(id, 'id', true), timestamp: v.integer(timestamp, 'timestamp') }), decode.nothing);
}
