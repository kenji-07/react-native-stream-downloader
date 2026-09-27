export interface Config {
  updateFrequencyMS?: number;
  maxParallelDownloads?: number;
  wifiOnly?: boolean;
  retry?: RetryPolicy;
}

export interface RetryPolicy {
  /** Additional attempts after a transient failure; default 0, maximum 10. */
  maxRetries?: number;
  initialDelayMS?: number;
  maxDelayMS?: number;
}

export interface DRMLicenseStatus {
  id: string;
  scheme: 'widevine' | 'playready' | 'fairplay';
  state: 'valid' | 'expired' | 'unknown' | 'missing';
  checkedAt: number;
  licenseDurationRemainingSeconds?: number;
  playbackDurationRemainingSeconds?: number;
  expiresAt?: number;
  /** FairPlay secure expiration SPCs, for the provider's expiration endpoint. */
  expirationTokens?: string[];
}

export interface DRMLicenseStatusOptions {
  /** iOS: resolve all expiration SPCs through your provider; return the earliest Unix timestamp in milliseconds, or null if unknown. */
  getExpirationDate?: (expirationTokens: string[]) => Promise<number | null> | number | null;
}

export interface DownloadOptions {
  checkStorageBeforeDownload?: boolean;
  expiresAt?: number;
  includeAllTracks?: boolean;
  tracks?: { video?: string[]; audio?: string[]; text?: string[] };
  drm?: DRMConfig;
  metadata?: Metadata;
  /**
   * HTTP headers sent with every media request of this download: manifests and
   * playlists, segments, HLS AES-128 key URIs and progressive MP4 bytes. They are
   * stored with the queued download so background resume keeps authenticating.
   * DRM license requests use `drm.headers` instead.
   */
  headers?: { [key: string]: string };
}

export interface AvailableTracksOptions {
  /** HTTP headers sent with manifest and media inspection requests. */
  headers?: { [key: string]: string };
}

export interface DownloadStatus {
  id: string;
  url: string;
  receivedBytes?: number;
  totalBytes?: number;
  progress: number;
  bytesPerSecond?: number;
  estimatedRemainingSeconds?: number;
  retryCount?: number;
  nextRetryAt?: number;
  waitingForNetwork?: boolean;
  status: 'pending' | 'downloading' | 'paused' | 'completed' | 'failed' | 'removed';
  error?: string;
  metadata?: Metadata;
}

export interface DownloadedAsset {
  id: string;
  url: string;
  pathToFile: string;
  title: string;
  duration: number;
  downloadDate: number;
  expiresAt?: number;
  metadata?: Metadata;
}

export interface DRMConfig {
  licenseServer?: string;
  certificateUrl?: string;
  headers?: { [key: string]: string };
  getLicense?: (
    spcString: string,
    contentId: string,
    licenseUrl: string,
    loadedLicenseUrl: string,
  ) => Promise<string> | string;
}

export interface Metadata {
  title?: string;
  [key: string]: unknown;
}

export type TrackType = 'audio' | 'video' | 'text';

export interface AudioTrack {
  id: string;
  type: 'audio';
  groupId: string;
  language?: string;
  name: string;
  isDefault?: boolean;
  autoSelect?: boolean;
  uri: string;
}

export interface TextTrack {
  id: string;
  type: 'text';
  groupId: string;
  name: string;
  isDefault?: boolean;
  autoSelect?: boolean;
  forced?: boolean;
  language?: string;
  uri: string;
}

export interface VideoTrack {
  id: string;
  type: 'video';
  bandwidth: number;
  codecs?: string;
  audioGroupId?: string;
  subtitlesGroupId?: string;
  captionGroupId?: string;
  videoGroupId?: string;
  resolution?: { width: number; height: number };
  uri: string;
  label?: string;
}

export interface AvailableTracksByType {
  audio: AudioTrack[];
  video: VideoTrack[];
  text: TextTrack[];
}
