export {
  registerPlugin, disablePlugin, isRegistered, setConfig, getConfig,
  downloadStream, cancelDownload, cancelAllDownloads, pauseDownload, resumeDownload,
  getDownloadStatus, getDownloadsStatus, getAvailableTracks, getDownloadedAssets,
  getDownloadedAsset, deleteDownloadedAsset, deleteAllDownloadedAssets,
  deleteQueuedItem, deleteAllQueuedItems, expireDownloadedAssetAt,
  getDRMLicenseStatus, renewDRMLicense,
} from './api';
export { useEvent } from './events/useEvent';
export type {
  Config, DownloadOptions, DownloadStatus, DownloadedAsset, DRMConfig, Metadata,
  TrackType, AudioTrack, TextTrack, VideoTrack, AvailableTracksByType,
  RetryPolicy, DRMLicenseStatus, DRMLicenseStatusOptions,
} from './types';
