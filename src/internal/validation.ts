import type { AvailableTracksOptions, Config, DownloadOptions, DRMConfig, Metadata } from '../types';
import { DownloaderError } from './errors';

export function object(value: unknown, label: string): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new DownloaderError('E_INVALID_ARGUMENT', `${label} must be an object.`);
  }
  return value as Record<string, unknown>;
}

export function string(value: unknown, label: string, nonempty = false): string {
  if (typeof value !== 'string' || (nonempty && value.length === 0)) {
    throw new DownloaderError('E_INVALID_ARGUMENT', `${label} must be ${nonempty ? 'a nonempty ' : 'a '}string.`);
  }
  return value;
}

export function number(value: unknown, label: string, min = 0, max = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) {
    throw new DownloaderError('E_INVALID_ARGUMENT', `${label} is outside its supported numeric range.`);
  }
  return value;
}

export function integer(value: unknown, label: string, min = 0, max = Number.MAX_SAFE_INTEGER): number {
  const result = number(value, label, min, max);
  if (!Number.isInteger(result)) throw new DownloaderError('E_INVALID_ARGUMENT', `${label} must be an integer.`);
  return result;
}

export function boolean(value: unknown, label: string): boolean {
  if (typeof value !== 'boolean') throw new DownloaderError('E_INVALID_ARGUMENT', `${label} must be boolean.`);
  return value;
}

function keys(value: Record<string, unknown>, allowed: readonly string[], label: string): void {
  if (Object.keys(value).some(key => !allowed.includes(key))) {
    throw new DownloaderError('E_INVALID_ARGUMENT', `${label} contains an unsupported property.`);
  }
}

export function url(value: unknown, label = 'url'): string {
  const result = string(value, label, true);
  // RN 0.74's built-in URL implementation is incomplete. Native engines perform
  // final URI parsing; this preflight never rewrites signed URLs.
  if (!/^https?:\/\/[^/?#\s]+(?:[/?#][^\s]*)?$/i.test(result) || /[\u0000-\u0020\u007f]/.test(result) || /%(?![a-f\d]{2})/i.test(result)) {
    throw new DownloaderError('E_INVALID_URL', `${label} must be a valid HTTP or HTTPS URL.`);
  }
  const authority = result.match(/^https?:\/\/([^/?#]+)/i)?.[1];
  if (!authority || authority.includes('@')) throw new DownloaderError('E_INVALID_URL', `${label} must have a host without embedded credentials.`);
  const hostPort = authority.startsWith('[')
    ? authority.match(/^\[[a-f\d:.]+\](?::(\d+))?$/i)
    : authority.match(/^[^:\[\]\\]+(?::(\d+))?$/);
  if (!hostPort || (hostPort[1] !== undefined && (Number(hostPort[1]) < 1 || Number(hostPort[1]) > 65535))) {
    throw new DownloaderError('E_INVALID_URL', `${label} has an invalid host or port.`);
  }
  return result;
}

export function config(value: unknown): Config {
  const input = object(value, 'config');
  keys(input, ['updateFrequencyMS', 'maxParallelDownloads', 'wifiOnly', 'retry'], 'config');
  const result: Config = {};
  for (const key of ['updateFrequencyMS', 'maxParallelDownloads'] as const) {
    if (input[key] !== undefined) result[key] = integer(input[key], key, 1, 2147483647);
  }
  if (input.wifiOnly !== undefined) result.wifiOnly = boolean(input.wifiOnly, 'wifiOnly');
  if (input.retry !== undefined) {
    const retry = object(input.retry, 'retry');
    keys(retry, ['maxRetries', 'initialDelayMS', 'maxDelayMS'], 'retry');
    result.retry = {};
    if (retry.maxRetries !== undefined) result.retry.maxRetries = integer(retry.maxRetries, 'maxRetries', 0, 10);
    for (const key of ['initialDelayMS', 'maxDelayMS'] as const) {
      if (retry[key] !== undefined) result.retry[key] = integer(retry[key], key, 1, 86400000);
    }
    if (result.retry.initialDelayMS !== undefined && result.retry.maxDelayMS !== undefined && result.retry.initialDelayMS > result.retry.maxDelayMS) {
      throw new DownloaderError('E_INVALID_ARGUMENT', 'initialDelayMS must not exceed maxDelayMS.');
    }
  }
  return result;
}

type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };

export function metadata(value: unknown): Metadata {
  const input = object(value, 'metadata');
  const visiting = new Set<object>();
  let budget = 1024 * 1024;
  const charge = (text: string): void => {
    // UTF-8 bytes without relying on TextEncoder being installed in RN.
    for (const char of text) {
      const point = char.codePointAt(0) ?? 0;
      budget -= point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
      if (budget < 0) throw new DownloaderError('E_INVALID_METADATA', 'Metadata exceeds 1 MiB.');
    }
  };
  const visit = (entry: unknown, depth: number): JSONValue => {
    if (depth > 64) throw new DownloaderError('E_INVALID_METADATA', 'Metadata nesting exceeds 64 levels.');
    if (entry === null || typeof entry === 'boolean') { charge(String(entry)); return entry; }
    if (typeof entry === 'string') { charge(JSON.stringify(entry)); return entry; }
    if (typeof entry === 'number' && Number.isFinite(entry)) { charge(String(entry)); return entry; }
    if (typeof entry !== 'object' || entry === null) throw new DownloaderError('E_INVALID_METADATA', 'Metadata must contain JSON-compatible values.');
    if (visiting.has(entry)) throw new DownloaderError('E_INVALID_METADATA', 'Metadata must not contain cycles.');
    const proto: unknown = Object.getPrototypeOf(entry);
    if (!Array.isArray(entry) && proto !== Object.prototype && proto !== null) {
      throw new DownloaderError('E_INVALID_METADATA', 'Metadata must contain plain objects; class instances are unsupported.');
    }
    visiting.add(entry);
    charge('[]');
    let result: JSONValue;
    if (Array.isArray(entry)) {
      result = Array.from({ length: entry.length }, (_, index) => {
        const descriptor = Object.getOwnPropertyDescriptor(entry, String(index));
        if (!descriptor || !('value' in descriptor)) throw new DownloaderError('E_INVALID_METADATA', 'Metadata arrays must not contain holes or accessors.');
        if (index > 0) charge(',');
        return visit(descriptor.value as unknown, depth + 1);
      });
    } else {
      const output: { [key: string]: JSONValue } = Object.create(null) as { [key: string]: JSONValue };
      let count = 0;
      for (const [key, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(entry))) {
        if (!descriptor.enumerable) continue;
        if (!('value' in descriptor)) throw new DownloaderError('E_INVALID_METADATA', 'Metadata accessors are unsupported.');
        const child: unknown = descriptor.value;
        if (child === undefined) continue;
        if (count++ > 0) charge(',');
        charge(`${JSON.stringify(key)}:`);
        output[key] = visit(child, depth + 1);
      }
      result = output;
    }
    visiting.delete(entry);
    return result;
  };
  const result = visit(input, 0) as Metadata;
  if (result.title !== undefined) string(result.title, 'metadata.title');
  return result;
}

// The transport owns these; a caller-supplied Range would corrupt segmented
// transfers and resume, and the others describe the connection itself.
const reservedHeaders = ['host', 'range', 'content-length', 'transfer-encoding', 'connection'];

function headers(value: unknown, label: string, code: string): Record<string, string> {
  const input = object(value, label);
  const result = Object.create(null) as Record<string, string>;
  const seen = new Set<string>();
  for (const [key, entry] of Object.entries(input)) {
    const header = string(entry, `${label} value`);
    const name = key.toLowerCase();
    if (!/^[!#$%&'*+.^_`|~\da-z-]+$/i.test(key) || /[\r\n\u0000]/.test(header)) {
      throw new DownloaderError(code, `${label} contain invalid characters.`);
    }
    if (seen.has(name)) throw new DownloaderError(code, `${label} repeat the ${key} header.`);
    seen.add(name);
    result[key] = header;
  }
  return result;
}

function mediaHeaders(value: unknown, label: string): Record<string, string> {
  const result = headers(value, label, 'E_INVALID_ARGUMENT');
  const reserved = Object.keys(result).find(key => reservedHeaders.includes(key.toLowerCase()));
  if (reserved) throw new DownloaderError('E_INVALID_ARGUMENT', `${label} cannot set ${reserved}; the downloader manages it.`);
  return result;
}

export function drm(value: unknown, platform: string): DRMConfig {
  const input = object(value, 'drm');
  keys(input, ['licenseServer', 'certificateUrl', 'headers', 'getLicense'], 'drm');
  const result: DRMConfig = {};
  if (input.licenseServer !== undefined) result.licenseServer = url(input.licenseServer, 'drm.licenseServer');
  if (input.certificateUrl !== undefined) result.certificateUrl = url(input.certificateUrl, 'drm.certificateUrl');
  if (input.getLicense !== undefined) {
    if (platform !== 'ios') throw new DownloaderError('E_UNSUPPORTED_CAPABILITY', 'getLicense is only supported on iOS.');
    if (typeof input.getLicense !== 'function') throw new DownloaderError('E_INVALID_DRM', 'getLicense must be a function.');
    result.getLicense = input.getLicense as NonNullable<DRMConfig['getLicense']>;
  }
  if (platform === 'ios' && !result.certificateUrl) throw new DownloaderError('E_INVALID_DRM', 'FairPlay requires certificateUrl.');
  if (!result.licenseServer && !result.getLicense) throw new DownloaderError('E_INVALID_DRM', 'DRM requires licenseServer or an iOS getLicense callback.');
  if (input.headers !== undefined) result.headers = headers(input.headers, 'drm.headers', 'E_INVALID_DRM');
  return result;
}

export function trackOptions(value: unknown): AvailableTracksOptions {
  if (value === undefined) return {};
  const input = object(value, 'options');
  keys(input, ['headers'], 'options');
  return input.headers === undefined ? {} : { headers: mediaHeaders(input.headers, 'headers') };
}

export function options(value: unknown, platform: string): DownloadOptions {
  if (value === undefined) return {};
  const input = object(value, 'options');
  keys(input, ['checkStorageBeforeDownload', 'expiresAt', 'includeAllTracks', 'tracks', 'drm', 'metadata', 'headers'], 'options');
  const result: DownloadOptions = {};
  for (const key of ['checkStorageBeforeDownload', 'includeAllTracks'] as const) {
    if (input[key] !== undefined) result[key] = boolean(input[key], key);
  }
  if (input.expiresAt !== undefined) result.expiresAt = integer(input.expiresAt, 'expiresAt');
  if (input.metadata !== undefined) result.metadata = metadata(input.metadata);
  if (input.drm !== undefined) result.drm = drm(input.drm, platform);
  if (input.headers !== undefined) result.headers = mediaHeaders(input.headers, 'headers');
  if (input.tracks !== undefined) {
    const tracks = object(input.tracks, 'tracks');
    keys(tracks, ['video', 'audio', 'text'], 'tracks');
    result.tracks = {};
    for (const key of ['video', 'audio', 'text'] as const) {
      const ids = tracks[key];
      if (ids !== undefined) {
        if (!Array.isArray(ids)) throw new DownloaderError('E_INVALID_TRACKS', 'Track selections must be arrays.');
        result.tracks[key] = [...new Set(ids.map(id => string(id, `tracks.${key} ID`, true)))];
      }
    }
    if (['video', 'audio', 'text'].every(key => Array.isArray(tracks[key]) && tracks[key].length === 0)) {
      throw new DownloaderError('E_INVALID_TRACKS', 'At least one media track must be selected.');
    }
  }
  return result;
}
