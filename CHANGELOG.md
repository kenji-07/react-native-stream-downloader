# Changelog

## Unreleased

- Add `DownloadOptions.headers` for media requests that require authentication, such as HLS AES-128 key URIs. Headers are sent with manifests, playlists, segments, keys and MP4 bytes, kept in protected storage for background resume, and never sent to DRM license servers.
- Accept the same `headers` in `getAvailableTracks(url, options)`.

## 0.1.0

- Publish the independent package as `react-native-stream-downloader` under Apache-2.0.
- Provide the documented download API, local registration, events, persistent queue, configuration and asset management.
- Add Android HLS/DASH/MP4 and iOS HLS/MP4 downloads, real track selection, offline player integration and persistent DRM mechanisms.
- Correct HLS rendition groups, renewable Mux URL identity, iOS package paths, native audio/subtitle matching and intrinsic caption handling.
- Update the Expo example to import `react-native-stream-downloader`.

Package builds and 107 host/contract tests passed before the publication rename.
The user subsequently reported successful HLS and DRM downloads on a device.
