const { boot, status, deferred, flush } = require('./helpers/bridge.cjs');

test('root exports the documented functions and useEvent', () => {
  expect(Object.keys(boot().api).sort()).toEqual([
    'registerPlugin', 'disablePlugin', 'isRegistered', 'setConfig', 'getConfig', 'downloadStream',
    'cancelDownload', 'cancelAllDownloads', 'pauseDownload', 'resumeDownload', 'getDownloadStatus',
    'getDownloadsStatus', 'getAvailableTracks', 'getDownloadedAssets', 'getDownloadedAsset',
    'deleteDownloadedAsset', 'deleteAllDownloadedAssets', 'deleteQueuedItem', 'deleteAllQueuedItems',
    'expireDownloadedAssetAt', 'getDRMLicenseStatus', 'renewDRMLicense', 'useEvent',
  ].sort());
});

test('registration is acknowledged, keyless, serial, and gates admissions during disable', async () => {
  const b = boot();
  const registration = deferred();
  b.replies.set('registerPlugin', () => registration.promise);
  expect(b.api.isRegistered()).toBe(false);
  await expect(b.api.getDownloadsStatus()).rejects.toMatchObject({ code: 'E_NOT_REGISTERED' });
  const first = b.api.registerPlugin();
  await flush();
  expect(b.api.isRegistered()).toBe(false);
  const disable = b.api.disablePlugin();
  expect(b.commands).toHaveLength(1);
  expect(b.commands[0].params).toEqual({});
  registration.resolve(true);
  await first;
  await expect(b.api.downloadStream('https://media.test/a.mp4')).rejects.toMatchObject({ code: 'E_NOT_REGISTERED' });
  await expect(disable).resolves.toBe(true);
  expect(b.api.isRegistered()).toBe(false);
  await b.api.registerPlugin();
  expect(b.api.isRegistered()).toBe(true);
});

test('registerPlugin rejects every supplied argument before native initialization', async () => {
  const b = boot();
  for (const args of [['sdsd'], [undefined], [null], [{}], ['first', 'second']]) {
    await expect(b.api.registerPlugin(...args)).rejects.toMatchObject({ code: 'E_INVALID_ARGUMENT', operation: 'registerPlugin' });
    expect(b.api.isRegistered()).toBe(false);
  }
  expect(b.commands).toHaveLength(0);
  expect(b.channels.size).toBe(0);
  await expect(b.api.registerPlugin()).resolves.toBe(true);
  expect(b.api.isRegistered()).toBe(true);
});

test('invalid registerPlugin calls leave pending and active registration intact', async () => {
  const b = boot();
  const registration = deferred();
  b.replies.set('registerPlugin', () => registration.promise);
  const first = b.api.registerPlugin();
  await flush();
  await expect(b.api.registerPlugin('sdsd')).rejects.toMatchObject({ code: 'E_INVALID_ARGUMENT' });
  registration.resolve(true);
  await expect(first).resolves.toBe(true);
  await expect(b.api.getDownloadsStatus()).resolves.toEqual([]);
  await expect(b.api.registerPlugin(undefined)).rejects.toMatchObject({ code: 'E_INVALID_ARGUMENT' });
  expect(b.api.isRegistered()).toBe(true);
  await expect(b.api.getDownloadsStatus()).resolves.toEqual([]);
  expect(b.commands.filter(command => command.method === 'registerPlugin')).toHaveLength(1);
});

test('a failed registration does not poison later registration', async () => {
  const b = boot();
  b.replies.set('registerPlugin', () => Promise.reject(Object.assign(new Error('Storage is unavailable.'), { code: 'E_STORAGE', retryable: true })));
  await expect(b.api.registerPlugin()).rejects.toMatchObject({ code: 'E_STORAGE', operation: 'registerPlugin', retryable: true });
  b.replies.set('registerPlugin', true);
  await expect(b.api.registerPlugin()).resolves.toBe(true);
});

test('missing native module rejects instead of reporting fake registration', async () => {
  const b = boot();
  delete b.rn.NativeModules.StreamDownloader;
  await expect(b.api.registerPlugin()).rejects.toMatchObject({ code: 'E_LINKING' });
  expect(b.api.isRegistered()).toBe(false);
});

test('React Native userInfo diagnostics survive conversion to an ordinary Error', async () => {
  const b = boot(); await b.api.registerPlugin();
  b.replies.set('getDownloadedAsset', () => Promise.reject(Object.assign(new Error('Asset is busy.'), { code: 'E_ASSET_IN_USE', userInfo: { retryable: true, downloadId: 'a' } })));
  await expect(b.api.getDownloadedAsset('a')).rejects.toMatchObject({ name: 'Error', code: 'E_ASSET_IN_USE', operation: 'getDownloadedAsset', retryable: true, downloadId: 'a' });
  await expect(b.api.pauseDownload('')).rejects.toMatchObject({ operation: 'pauseDownload' });
});

test('all asset/lifecycle wrappers dispatch their exact names and argument order', async () => {
  const b = boot();
  await b.api.registerPlugin();
  for (const method of ['cancelDownload', 'pauseDownload', 'resumeDownload', 'deleteDownloadedAsset', 'deleteQueuedItem']) {
    await expect(b.api[method]('asset-7')).resolves.toBeUndefined();
    expect(b.commands.at(-1)).toMatchObject({ version: 1, method, params: { id: 'asset-7' } });
  }
  for (const method of ['cancelAllDownloads', 'deleteAllDownloadedAssets', 'deleteAllQueuedItems']) {
    await b.api[method]();
    expect(b.commands.at(-1)).toMatchObject({ method, params: {} });
  }
  await b.api.expireDownloadedAssetAt('asset-7', 1234);
  expect(b.commands.at(-1)).toMatchObject({ method: 'expireDownloadedAssetAt', params: { id: 'asset-7', timestamp: 1234 } });
  await expect(b.api.getDownloadStatus('absent')).resolves.toBeNull();
  await expect(b.api.getDownloadedAsset('absent')).resolves.toBeNull();
  await expect(b.api.getDownloadsStatus()).resolves.toEqual([]);
  await expect(b.api.getDownloadedAssets()).resolves.toEqual([]);
});

test('admission and native decoding preserve documented data and remove internal fields', async () => {
  const b = boot(); await b.api.registerPlugin();
  b.replies.set('downloadStream', status('pending', { generation: 8, secretLicenseReference: 'never-public', metadata: { title: 'Example', custom: 3 } }));
  const result = await b.api.downloadStream('https://media.test/master.m3u8?token=a%2Fb', { tracks: { video: ['v', 'v'], audio: [] }, metadata: { title: 'Example', ignored: undefined } });
  expect(result).toEqual(status('pending', { metadata: { title: 'Example', custom: 3 } }));
  expect(b.commands.at(-1).params).toEqual({ url: 'https://media.test/master.m3u8?token=a%2Fb', options: { tracks: { video: ['v'], audio: [] }, metadata: { title: 'Example' } } });
  b.replies.set('getDownloadedAsset', { id: 'a', url: 'https://media.test/a', pathToFile: 'rnv-offline://asset/a/video.mp4', title: '', duration: 2000, downloadDate: 10, internal: 1 });
  expect(await b.api.getDownloadedAsset('a')).not.toHaveProperty('internal');
  b.replies.set('getDownloadStatus', status('imaginary'));
  await expect(b.api.getDownloadStatus('a')).rejects.toMatchObject({ code: 'E_BRIDGE' });
});

test('config updates forward partial changes and getters decode effective native values', async () => {
  const b = boot(); await b.api.registerPlugin();
  await b.api.setConfig({ maxParallelDownloads: 2 });
  expect(b.commands.at(-1).params).toEqual({ config: { maxParallelDownloads: 2 } });
  await expect(b.api.getConfig()).resolves.toEqual({ updateFrequencyMS: 1000, maxParallelDownloads: 5 });
  for (const invalid of [0, -1, 1.5, NaN, Infinity, '5', 2147483648]) {
    await expect(b.api.setConfig({ maxParallelDownloads: invalid })).rejects.toBeInstanceOf(Error);
  }
  await expect(b.api.setConfig({ invented: true })).rejects.toBeInstanceOf(Error);
});

test('initial configuration does not register or enable download operations', async () => {
  const b = boot();
  await b.api.setConfig({ maxParallelDownloads: 4, updateFrequencyMS: 1000 });
  await expect(b.api.getConfig()).resolves.toEqual({ updateFrequencyMS: 1000, maxParallelDownloads: 5 });
  expect(b.api.isRegistered()).toBe(false);
  expect(b.commands.map(command => command.method)).toEqual(['setConfig', 'getConfig']);
  await expect(b.api.downloadStream('https://media.test/a.mp4')).rejects.toMatchObject({ code: 'E_NOT_REGISTERED' });
  await b.api.registerPlugin();
  expect(b.api.isRegistered()).toBe(true);
});

test.each(['file:///secret', 'https://', 'ftp://a.test/b', 'https://u:p@a.test/a', 'https://a.test:99999/a', 'https://a.test/a%ZZ', 'https://a.test/a\n'])('invalid media URL rejects before bridge: %s', async url => {
  const b = boot(); await b.api.registerPlugin();
  await expect(b.api.downloadStream(url)).rejects.toMatchObject({ code: 'E_INVALID_URL' });
  expect(b.commands).toHaveLength(1);
});

test('invalid metadata, dates and empty selections never reach native code', async () => {
  const b = boot(); await b.api.registerPlugin();
  const cyclic = {}; cyclic.self = cyclic;
  let invoked = false;
  const getter = { get title() { invoked = true; return 'wrong'; } };
  const arrayGetter = []; Object.defineProperty(arrayGetter, '0', { get() { invoked = true; return 1; }, enumerable: true });
  for (const metadata of [cyclic, { date: new Date() }, { n: Infinity }, { b: 1n }, { fn() {} }, { a: [undefined] }, getter, { a: arrayGetter }, { a: new Array(1) }]) {
    await expect(b.api.downloadStream('https://media.test/a.mp4', { metadata })).rejects.toBeInstanceOf(Error);
  }
  expect(invoked).toBe(false);
  for (const expiresAt of [-1, NaN, new Date(), 0.5]) await expect(b.api.downloadStream('https://media.test/a.mp4', { expiresAt })).rejects.toBeInstanceOf(Error);
  await expect(b.api.downloadStream('https://media.test/a.mp4', { tracks: { video: [], audio: [], text: [] } })).rejects.toMatchObject({ code: 'E_INVALID_TRACKS' });
  expect(b.commands).toHaveLength(1);
});

test('metadata byte limit includes exact JSON encoding and Unicode bytes', () => {
  boot();
  const { metadata } = require('../lib/internal/validation');
  expect(() => metadata({ a: 'x'.repeat(1048576 - 8) })).not.toThrow();
  expect(() => metadata({ a: 'x'.repeat(1048576 - 7) })).toThrow('1 MiB');
  expect(() => metadata({ a: '😀'.repeat(262142) })).not.toThrow();
  expect(() => metadata({ a: '😀'.repeat(262143) })).toThrow('1 MiB');
});

test('DRM validation enforces native platform capabilities without inventing endpoints', async () => {
  const b = boot(); await b.api.registerPlugin();
  await expect(b.api.downloadStream('https://media.test/a.mpd', { drm: { getLicense: () => 'Q0tD' } })).rejects.toMatchObject({ code: 'E_UNSUPPORTED_CAPABILITY' });
  await expect(b.api.downloadStream('https://media.test/a.mpd', { drm: {} })).rejects.toMatchObject({ code: 'E_INVALID_DRM' });
  await expect(b.api.downloadStream('https://media.test/a.mpd', { drm: { licenseServer: 'https://license.test', headers: { Authorization: 'a\r\nb' } } })).rejects.toMatchObject({ code: 'E_INVALID_DRM' });
});
