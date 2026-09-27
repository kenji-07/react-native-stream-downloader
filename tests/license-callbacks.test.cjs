const { boot, status, deferred, flush } = require('./helpers/bridge.cjs');
const url = 'https://media.test/master.m3u8';
const drm = getLicense => ({ certificateUrl: 'https://license.test/certificate', getLicense });
const ref = b => b.commands.find(c => c.method === 'downloadStream').params.options.drm.callbackRef;

test('getLicense stays in JS, gets the four documented arguments, and settles once', async () => {
  const b = boot('ios'); await b.api.registerPlugin();
  b.replies.set('downloadStream', status());
  const callback = jest.fn(() => 'Q0tD');
  await b.api.downloadStream(url, { drm: drm(callback) });
  expect(JSON.stringify(b.commands)).not.toContain('getLicense');
  b.license({ callbackRef: ref(b), requestId: 'same', sequence: 1 });
  b.license({ callbackRef: ref(b), requestId: 'same', sequence: 1 });
  await flush();
  expect(callback).toHaveBeenCalledTimes(1);
  expect(callback).toHaveBeenCalledWith('U1BD', 'content', '', 'skd://content');
  expect(b.native.completeLicenseRequest).toHaveBeenCalledTimes(1);
  expect(b.native.completeLicenseRequest).toHaveBeenCalledWith({ runtimeId: b.runtimeId, requestId: 'same', ckcBase64: 'Q0tD' });
  b.event('onDownloadEnd', status('completed', { progress: 1 }));
  b.license({ callbackRef: ref(b) }); await flush();
  expect(callback).toHaveBeenCalledTimes(1);
  expect(b.native.completeLicenseRequest.mock.calls.at(-1)[0].error.code).toBe('E_DRM_CALLBACK_UNAVAILABLE');
});

test('callbacks can be requested during admission and terminal-before-admission does not retain them', async () => {
  const b = boot('ios'); await b.api.registerPlugin();
  const admission = deferred(); const callback = jest.fn(() => Promise.resolve('Q0tD'));
  b.replies.set('downloadStream', () => admission.promise);
  const operation = b.api.downloadStream(url, { drm: drm(callback) });
  b.license({ callbackRef: ref(b) }); await flush();
  expect(callback).toHaveBeenCalledTimes(1);
  b.event('onDownloadEnd', status('completed', { progress: 1 }));
  admission.resolve(status()); await operation;
  b.license({ callbackRef: ref(b) }); await flush();
  expect(callback).toHaveBeenCalledTimes(1);
});

test('duplicate admissions share callback identity and one terminal releases the asset lease', async () => {
  const b = boot('ios'); await b.api.registerPlugin();
  b.replies.set('downloadStream', status());
  const callback = jest.fn(() => 'Q0tD');
  await Promise.all([b.api.downloadStream(url, { drm: drm(callback) }), b.api.downloadStream(url, { drm: drm(callback) })]);
  const refs = b.commands.filter(c => c.method === 'downloadStream').map(c => c.params.options.drm.callbackRef);
  expect(refs[0]).toBe(refs[1]);
  b.event('onDownloadEnd', status('removed'));
  b.license({ callbackRef: refs[0] }); await flush();
  expect(callback).not.toHaveBeenCalled();
});

test.each(['cancel', 'disable'])('%s discards a late callback result', async action => {
  const b = boot('ios'); await b.api.registerPlugin();
  b.replies.set('downloadStream', status());
  const response = deferred(); const callback = jest.fn(() => response.promise);
  await b.api.downloadStream(url, { drm: drm(callback) });
  b.license({ callbackRef: ref(b) }); await flush();
  if (action === 'disable') await b.api.disablePlugin();
  else { await b.api.cancelDownload('a'); b.event('onDownloadEnd', status('removed')); }
  response.resolve('Q0tD'); await flush();
  expect(b.native.completeLicenseRequest).not.toHaveBeenCalled();
});

test('timeout sends a typed private error and ignores the eventual result', async () => {
  jest.useFakeTimers();
  try {
    const b = boot('ios'); await b.api.registerPlugin(); b.replies.set('downloadStream', status());
    const response = deferred();
    await b.api.downloadStream(url, { drm: drm(() => response.promise) });
    b.license({ callbackRef: ref(b) }); await flush();
    jest.advanceTimersByTime(60000); await flush();
    expect(b.native.completeLicenseRequest.mock.calls[0][0].error.code).toBe('E_DRM_TIMEOUT');
    response.resolve('Q0tD'); await flush();
    expect(b.native.completeLicenseRequest).toHaveBeenCalledTimes(1);
  } finally { jest.useRealTimers(); }
});

test.each([
  () => { throw new Error('secret bearer credential'); },
  () => Promise.reject(new Error('secret bearer credential')),
  () => '<ckc>not-base64</ckc>',
])('callback errors/invalid CKC are sanitized and reject native licensing', async callback => {
  const b = boot('ios'); await b.api.registerPlugin(); b.replies.set('downloadStream', status());
  await b.api.downloadStream(url, { drm: drm(callback) });
  b.license({ callbackRef: ref(b) }); await flush();
  expect(b.native.completeLicenseRequest.mock.calls[0][0].error.code).toBe('E_DRM_LICENSE');
  expect(JSON.stringify(b.native.completeLicenseRequest.mock.calls)).not.toContain('secret bearer');
});
