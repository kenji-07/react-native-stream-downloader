These two-second clear-media fixtures were generated locally with FFmpeg from
`testsrc2` (160 × 90, 10 fps) and a 440 Hz sine wave. They contain no third-party
recording or DRM. H.264 video uses a one-second GOP; audio is AAC.

HLS uses one-second MPEG-TS segments. DASH uses fragmented MP4, separate audio
and video adaptation sets, and a static two-second MPD. Host tests feed the
resources through a deterministic Media3 DataSource, including byte-range
reads. They verify real downloader selection, persistence and cache-only reads;
they do not establish device decoding or DRM playback.

`mp4/multitrack.mp4` is a locally generated two-second clear MP4 with a test-pattern
video track and two sine-wave audio tracks tagged `eng` and `mon`. Swift host
export tests select the Mongolian track, exclude other tracks and verify native
cancellation/partial-file cleanup. It contains no DRM or third-party media.
