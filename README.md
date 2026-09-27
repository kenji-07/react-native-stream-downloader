# react-native-stream-downloader

Offline HLS, DASH and MP4 downloads for React Native, with track selection, a persistent download queue, DRM support and integration with `react-native-video`.

This Apache-2.0 package is an independent, clean-room implementation informed by the public Offline Video SDK documentation.

```sh
npm install react-native-stream-downloader 'react-native-video@^6.15.0'
cd ios
pod install
```

Requires React Native 0.74+, React 18.2+, react-native-video 6.15–6.x, Android API 23+ or iOS 15+. Expo apps require a native development build; this native module is not included in Expo Go. Rebuild the native app after installation.

## Usage

```ts
import {
  registerPlugin,
  setConfig,
  downloadStream,
  getDownloadsStatus,
  getDownloadedAssets,
} from 'react-native-stream-downloader';

await registerPlugin();
await setConfig({ maxParallelDownloads: 2, updateFrequencyMS: 1000 });
const download = await downloadStream(
  'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
  { metadata: { title: 'Big Buck Bunny' } },
);
// download.id is used by pauseDownload, resumeDownload and cancelDownload.
// Admission is asynchronous; it does not mean the download has completed.
const statuses = await getDownloadsStatus();
const completedAssets = await getDownloadedAssets();
```

Subscribe from a React component to receive updates:

```tsx
import { useEvent } from 'react-native-stream-downloader';

function DownloadEvents() {
  useEvent('onDownloadProgress', statuses => console.log(statuses));
  useEvent('onDownloadEnd', status => console.log(status.id, status.status));
  useEvent('onError', message => console.warn(message));
  return null;
}
```

Pass a completed asset's local path to the existing player:

```tsx
import Video from 'react-native-video';
import type { DownloadedAsset } from 'react-native-stream-downloader';

function OfflineVideo({ asset }: { asset: DownloadedAsset }) {
  return <Video source={{ uri: asset.pathToFile }} controls style={{ height: 240 }} />;
}
```

Use `getAvailableTracks(url)` for selection IDs and pass them through `DownloadOptions.tracks`. DRM options accept your own `licenseServer`, `certificateUrl` (FairPlay), headers or FairPlay `getLicense` callback. The application must have an entitlement that permits persistent licenses.

## Supported implementation paths

- Android: Media3 HLS, static DASH and MP4 downloads; real native track selection; clear MP4 selected-track remux; cache-only playback through unmodified react-native-video; Widevine offline rights and capability-gated Android TV PlayReady.
- iOS: finite HLS through AVAssetDownloadURLSession and progressive MP4 through a background URLSession; clear MP4 selected-track export; owned local-asset playback through react-native-video; persistent FairPlay keys through AVContentKeySession.
- Both: durable queue/metadata, pause/resume/cancel, deletion journals, playback reader leases, native completion checks and protected DRM storage. Background execution remains subject to operating-system limits.

This list describes implemented paths, not verified support for every stream or provider. iOS DASH, live adaptive downloads and encrypted MP4 remux are unsupported. In-band HLS audio cannot be independently removed from shared segments. Intrinsic CEA-608/708 captions remain inside retained video samples even when `tracks.text` selects a separate subtitle rendition or is empty; independently downloadable subtitle renditions follow the requested selection.

Persistent DRM depends on the provider granting offline rights. Android PlayReady is limited to supported Android TV devices and content; multiple independent Android offline key sets cannot be combined for one playback. FairPlay callbacks cannot be recreated after the JavaScript runtime disappears, and automatic provider-specific license renewal/release receipts are not implemented. License expiry is enforced by the platform DRM system.

## Public contract

Only the audited twenty functions, `useEvent`, and eleven named TypeScript types are exported. Defaults are `maxParallelDownloads: 5` and `updateFrequencyMS: 1000`; the conflicting documented parallel default is explained in the audit. Getters return promises except synchronous `isRegistered()`. Configuration can be read or merged before registration without starting downloads.

`downloadStream` resolves admission to the native queue. Completion arrives through `onDownloadEnd`. Progress is a fraction from 0 to 1; only committed completion reports 1. Events are `onError` (string), `onDownloadProgress` (status array), and `onDownloadEnd` (status).

Native inspected IDs control selected media. An omitted category selects compatible tracks; an empty array excludes separately selectable tracks in that category. For HLS, passing every inspected audio or text ID also means all compatible renditions for the chosen variants. A smaller incompatible explicit selection still rejects. Track identity ignores non-playback comments/session analytics and narrowly recognizes renewable Mux rendition signatures; media request URLs and DRM identifiers are preserved.

Metadata must be JSON-compatible and at most 1 MiB encoded. `metadata.title` remains the display title and supplies a sanitized MP4 filename; storage ownership still uses the asset UUID. iOS HLS packages stay at AVFoundation's managed destination. Expiry values use epoch milliseconds; zero/omission means no expiry. Android removes expired completed assets during startup. iOS retains expiry as metadata. Download expiry does not renew or extend DRM rights.

## license

Licensed under [Apache-2.0](LICENSE). Third-party dependencies and the Expo template retain their own notices; see [NOTICE](NOTICE).
