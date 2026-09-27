import * as api from '../../src';
import type { Config, DownloadOptions, DownloadStatus, DownloadedAsset, AvailableTracksByType, DRMConfig, DRMLicenseStatus, DRMLicenseStatusOptions, Metadata, TrackType, AudioTrack, TextTrack, VideoTrack } from '../../src';

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
type Assert<T extends true> = T;
type Expected = {
  registerPlugin: () => Promise<boolean>;
  getDRMLicenseStatus: (id: string, options?: DRMLicenseStatusOptions) => Promise<DRMLicenseStatus | null>;
  renewDRMLicense: (id: string, drm?: DRMConfig) => Promise<DRMLicenseStatus>;
  disablePlugin: () => Promise<boolean>;
  isRegistered: () => boolean;
  setConfig: (config: Config) => Promise<void>;
  getConfig: () => Promise<Config>;
  downloadStream: (url: string, options?: DownloadOptions) => Promise<DownloadStatus>;
  cancelDownload: (id: string) => Promise<void>;
  cancelAllDownloads: () => Promise<void>;
  pauseDownload: (id: string) => Promise<void>;
  resumeDownload: (id: string) => Promise<void>;
  getDownloadStatus: (id: string) => Promise<DownloadStatus | null>;
  getDownloadsStatus: () => Promise<DownloadStatus[]>;
  getAvailableTracks: (url: string) => Promise<AvailableTracksByType>;
  getDownloadedAssets: () => Promise<DownloadedAsset[]>;
  getDownloadedAsset: (id: string) => Promise<DownloadedAsset | null>;
  deleteDownloadedAsset: (id: string) => Promise<void>;
  deleteAllDownloadedAssets: () => Promise<void>;
  deleteQueuedItem: (id: string) => Promise<void>;
  deleteAllQueuedItems: () => Promise<void>;
  expireDownloadedAssetAt: (id: string, timestamp: number) => Promise<void>;
};
type FunctionsMatch = Assert<Equal<Omit<typeof api, 'useEvent'>, Expected>>;
type RegistrationArgumentsMatch = Assert<Equal<Parameters<typeof api.registerPlugin>, []>>;
type StatesMatch = Assert<Equal<DownloadStatus['status'], 'pending' | 'downloading' | 'paused' | 'completed' | 'failed' | 'removed'>>;
type TracksMatch = Assert<Equal<TrackType, 'audio' | 'video' | 'text'>>;
const drm: DRMConfig = { getLicense: (spc, contentId, url, loadedURL) => Promise.resolve(spc + contentId + url + loadedURL) };
const metadata: Metadata = { arbitrary: { nested: true }, title: 'Typed title' };
const trackTypes: [AudioTrack['type'], TextTrack['type'], VideoTrack['type']] = ['audio', 'text', 'video'];
void [drm, metadata, trackTypes];
api.registerPlugin();
// @ts-expect-error registration accepts no arguments
api.registerPlugin('sdsd');
// @ts-expect-error explicitly passing undefined is still an argument
api.registerPlugin(undefined);
api.useEvent('onError', error => { const value: string = error; void value; });
api.useEvent('onDownloadEnd', status => { const value: DownloadStatus = status; void value; });
api.useEvent('onDownloadProgress', statuses => { const value: DownloadStatus[] = statuses; void value; });
// @ts-expect-error no undocumented events
api.useEvent('onPause', () => {});
// @ts-expect-error progress payload is an array
api.useEvent('onDownloadProgress', (status: DownloadStatus) => { void status; });
// @ts-expect-error expiry is numeric
api.expireDownloadedAssetAt('id', new Date());
// @ts-expect-error status is a type, not a runtime enum
api.DownloadStatus.COMPLETED;
// @ts-expect-error no public custom player
api.OfflineVideo;
// @ts-expect-error metadata title has a documented string type
const badMetadata: Metadata = { title: 3 };
void badMetadata;
