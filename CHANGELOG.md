# Changelog

## 0.1.3

- iOS: offline AES-128 HLS. AVFoundation keeps no AES-128 key in a `.movpkg`, so playback re-requested the `https` key without headers (401 → `NSURLErrorDomain -1013`) or failed offline. iOS downloads now send `X-Stream-Downloader-Keys: streamdl-key`; a server that rewrites AES-128 key URIs to `streamdl-key://` for those requests gets each key fetched once with the download headers, stored in the device-bound Keychain and served to the offline player (also to restored transfers and package verification). Deleting the asset removes its keys.
- iOS: offline playback sends the stored download headers with remaining `https` key requests instead of none.
- README: the "key is downloaded with the media" note now applies to Android only.

## 0.1.2

- Add `DownloadOptions.headers` for media requests that require authentication, such as HLS AES-128 key URIs. Headers are sent with manifests, playlists, segments, keys and MP4 bytes, kept in protected storage for background resume, and never sent to DRM license servers.
- Accept the same `headers` in `getAvailableTracks(url, options)`.

## 0.1.1

- Publish the independent package as `react-native-stream-downloader` under Apache-2.0.
- Provide the documented download API, local registration, events, persistent queue, configuration and asset management.
- Add Android HLS/DASH/MP4 and iOS HLS/MP4 downloads, real track selection, offline player integration and persistent DRM mechanisms.
- Correct HLS rendition groups, renewable Mux URL identity, iOS package paths, native audio/subtitle matching and intrinsic caption handling.
- Update the Expo example to import `react-native-stream-downloader`.

Package builds and 107 host/contract tests passed before the publication rename.
The user subsequently reported successful HLS and DRM downloads on a device.
