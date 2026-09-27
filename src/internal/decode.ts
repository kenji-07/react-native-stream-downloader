import type { AvailableTracksByType, AudioTrack, Config, DownloadedAsset, DownloadStatus, DRMLicenseStatus, TextTrack, VideoTrack } from '../types';
import * as v from './validation';
import { DownloaderError } from './errors';

const states = ['pending', 'downloading', 'paused', 'completed', 'failed', 'removed'] as const;

function optional<T>(record: Record<string, unknown>, key: string, decode: (value: unknown, label: string) => T): { [key: string]: T } {
  return record[key] === undefined || record[key] === null ? {} : { [key]: decode(record[key], key) };
}

export function status(value: unknown): DownloadStatus {
  const r = v.object(value, 'native DownloadStatus');
  const state = v.string(r.status, 'status');
  if (!states.some(s => s === state)) throw new DownloaderError('E_BRIDGE', 'Native status is not a documented state.');
  return {
    id: v.string(r.id, 'id', true), url: v.string(r.url, 'url', true),
    progress: v.number(r.progress, 'progress', 0, 1), status: state as DownloadStatus['status'],
    ...optional(r, 'receivedBytes', v.integer), ...optional(r, 'totalBytes', v.integer),
    ...optional(r, 'error', v.string), ...optional(r, 'metadata', v.metadata),
    ...optional(r, 'bytesPerSecond', v.number), ...optional(r, 'estimatedRemainingSeconds', v.number),
    ...optional(r, 'retryCount', v.integer), ...optional(r, 'nextRetryAt', v.integer), ...optional(r, 'waitingForNetwork', v.boolean),
  };
}

export function asset(value: unknown): DownloadedAsset {
  const r = v.object(value, 'native DownloadedAsset');
  return {
    id: v.string(r.id, 'id', true), url: v.string(r.url, 'url', true),
    pathToFile: v.string(r.pathToFile, 'pathToFile', true), title: v.string(r.title, 'title'),
    duration: v.integer(r.duration, 'duration'), downloadDate: v.integer(r.downloadDate, 'downloadDate'),
    ...optional(r, 'expiresAt', v.integer), ...optional(r, 'metadata', v.metadata),
  };
}

export function array<T>(value: unknown, decode: (item: unknown) => T): T[] {
  if (!Array.isArray(value)) throw new DownloaderError('E_BRIDGE', 'Native response must be an array.');
  return value.map(decode);
}

export function config(value: unknown): Config {
  const r = v.object(value, 'native Config');
  return {
    updateFrequencyMS: v.integer(r.updateFrequencyMS, 'updateFrequencyMS', 1, 2147483647),
    maxParallelDownloads: v.integer(r.maxParallelDownloads, 'maxParallelDownloads', 1, 2147483647),
    ...optional(r, 'wifiOnly', v.boolean),
    ...(r.retry == null ? {} : { retry: v.config({ retry: r.retry }).retry! }),
  };
}

export function licenseStatus(value: unknown): DRMLicenseStatus {
  const r = v.object(value, 'native DRMLicenseStatus');
  if (!['widevine', 'playready', 'fairplay'].includes(String(r.scheme)) || !['valid', 'expired', 'unknown', 'missing'].includes(String(r.state))) {
    throw new DownloaderError('E_BRIDGE', 'Invalid native DRM license status.');
  }
  return {
    id: v.string(r.id, 'id', true), scheme: r.scheme as DRMLicenseStatus['scheme'], state: r.state as DRMLicenseStatus['state'],
    checkedAt: v.integer(r.checkedAt, 'checkedAt'),
    ...optional(r, 'licenseDurationRemainingSeconds', v.number), ...optional(r, 'playbackDurationRemainingSeconds', v.number),
    ...optional(r, 'expiresAt', v.integer),
    ...(r.expirationTokens == null ? {} : { expirationTokens: array(r.expirationTokens, token => v.string(token, 'expirationToken', true)) }),
  };
}

function audio(value: unknown): AudioTrack {
  const r = v.object(value, 'native AudioTrack');
  if (r.type !== 'audio') throw new DownloaderError('E_BRIDGE', 'Expected an audio track.');
  return {
    id: v.string(r.id, 'id', true), type: 'audio', groupId: v.string(r.groupId, 'groupId'),
    name: v.string(r.name, 'name'), uri: v.string(r.uri, 'uri', true),
    ...optional(r, 'language', v.string), ...optional(r, 'isDefault', v.boolean), ...optional(r, 'autoSelect', v.boolean),
  };
}

function text(value: unknown): TextTrack {
  const r = v.object(value, 'native TextTrack');
  if (r.type !== 'text') throw new DownloaderError('E_BRIDGE', 'Expected a text track.');
  return {
    id: v.string(r.id, 'id', true), type: 'text', groupId: v.string(r.groupId, 'groupId'),
    name: v.string(r.name, 'name'), uri: v.string(r.uri, 'uri', true),
    ...optional(r, 'language', v.string), ...optional(r, 'isDefault', v.boolean),
    ...optional(r, 'autoSelect', v.boolean), ...optional(r, 'forced', v.boolean),
  };
}

function video(value: unknown): VideoTrack {
  const r = v.object(value, 'native VideoTrack');
  const resolution = r.resolution == null ? undefined : v.object(r.resolution, 'resolution');
  if (r.type !== 'video') throw new DownloaderError('E_BRIDGE', 'Expected a video track.');
  return {
    id: v.string(r.id, 'id', true), type: 'video', bandwidth: v.number(r.bandwidth, 'bandwidth'), uri: v.string(r.uri, 'uri', true),
    ...optional(r, 'codecs', v.string), ...optional(r, 'audioGroupId', v.string),
    ...optional(r, 'subtitlesGroupId', v.string), ...optional(r, 'captionGroupId', v.string),
    ...optional(r, 'videoGroupId', v.string), ...optional(r, 'label', v.string),
    ...(resolution ? { resolution: { width: v.number(resolution.width, 'width'), height: v.number(resolution.height, 'height') } } : {}),
  };
}

export function tracks(value: unknown): AvailableTracksByType {
  const r = v.object(value, 'native AvailableTracksByType');
  return { audio: array(r.audio, audio), video: array(r.video, video), text: array(r.text, text) };
}

export function bool(value: unknown): boolean { return v.boolean(value, 'native result'); }
export function nothing(value: unknown): void {
  if (value !== null && value !== undefined) throw new DownloaderError('E_BRIDGE', 'Native command returned an unexpected value.');
}
