const { boot, status, flush } = require('./helpers/bridge.cjs');

test('retry and Wi-Fi policy are validated before crossing the native bridge', async () => {
  const b = boot();
  const config = { wifiOnly: true, retry: { maxRetries: 3, initialDelayMS: 1000, maxDelayMS: 8000 } };
  await b.api.setConfig(config);
  expect(b.commands.at(-1).params).toEqual({ config });
  for (const retry of [{ maxRetries: 11 }, { maxRetries: -1 }, { initialDelayMS: 0 }, { maxDelayMS: Infinity }, { initialDelayMS: 20, maxDelayMS: 10 }, { invented: true }]) {
    await expect(b.api.setConfig({ retry })).rejects.toMatchObject({ code: 'E_INVALID_ARGUMENT' });
  }
  await expect(b.api.setConfig({ wifiOnly: 'yes' })).rejects.toMatchObject({ code: 'E_INVALID_ARGUMENT' });
  expect(b.commands).toHaveLength(1);
  b.replies.set('getConfig', { ...config, maxParallelDownloads: 2, updateFrequencyMS: 1000 });
  await expect(b.api.getConfig()).resolves.toEqual({ ...config, maxParallelDownloads: 2, updateFrequencyMS: 1000 });
});

test('progress decodes transfer estimates and retry/network waiting metadata', async () => {
  const b = boot(); await b.api.registerPlugin();
  const current = status('pending', { retryCount: 1, nextRetryAt: 12345, waitingForNetwork: true, bytesPerSecond: 250, estimatedRemainingSeconds: 4 });
  b.replies.set('getDownloadStatus', current);
  await expect(b.api.getDownloadStatus('a')).resolves.toEqual(current);
});

test('Widevine status and no-DRM assets are returned without JS expiration requests', async () => {
  const b = boot(); await b.api.registerPlugin();
  const license = { id: 'a', scheme: 'widevine', state: 'valid', checkedAt: 100, licenseDurationRemainingSeconds: 60, playbackDurationRemainingSeconds: 30 };
  b.replies.set('getDRMLicenseStatus', license);
  const callback = jest.fn();
  await expect(b.api.getDRMLicenseStatus('a', { getExpirationDate: callback })).resolves.toEqual(license);
  expect(callback).not.toHaveBeenCalled();
  b.replies.set('getDRMLicenseStatus', null);
  await expect(b.api.getDRMLicenseStatus('clear')).resolves.toBeNull();
});

test('FairPlay expiration requires a provider response, not an invented local duration', async () => {
  const b = boot('ios'); await b.api.registerPlugin();
  b.replies.set('getDRMLicenseStatus', { id: 'a', scheme: 'fairplay', state: 'unknown', checkedAt: 100, expirationTokens: ['U1BD'] });
  await expect(b.api.getDRMLicenseStatus('a')).resolves.toMatchObject({ state: 'unknown' });
  const expiresAt = Date.now() + 60000;
  const getExpirationDate = jest.fn(async tokens => { expect(tokens).toEqual(['U1BD']); return expiresAt; });
  await expect(b.api.getDRMLicenseStatus('a', { getExpirationDate })).resolves.toMatchObject({ state: 'valid', expiresAt });
  await expect(b.api.getDRMLicenseStatus('a', { getExpirationDate: () => 1 })).resolves.toMatchObject({ state: 'expired' });
  await expect(b.api.getDRMLicenseStatus('a', { getExpirationDate: () => null })).resolves.toMatchObject({ state: 'unknown' });
  await expect(b.api.getDRMLicenseStatus('a', { getExpirationDate: () => { throw new Error('secret'); } })).rejects.toMatchObject({ code: 'E_DRM_STATUS', message: 'The provider expiration check failed.' });
});

test('renewal retains a temporary FairPlay callback only until the native operation settles', async () => {
  const b = boot('ios'); await b.api.registerPlugin();
  const license = { id: 'a', scheme: 'fairplay', state: 'unknown', checkedAt: 100 };
  let finish;
  b.replies.set('renewDRMLicense', () => new Promise(resolve => { finish = resolve; }));
  const callback = jest.fn(() => 'Q0tD');
  const renewal = b.api.renewDRMLicense('a', { certificateUrl: 'https://license.test/certificate', getLicense: callback });
  const config = b.commands.at(-1).params.drm;
  expect(config.getLicense).toBeUndefined();
  b.license({ callbackRef: config.callbackRef }); await flush();
  expect(callback).toHaveBeenCalledTimes(1);
  finish(license); await expect(renewal).resolves.toEqual(license);
  b.license({ callbackRef: config.callbackRef }); await flush();
  expect(callback).toHaveBeenCalledTimes(1);
  expect(b.native.completeLicenseRequest.mock.calls.at(-1)[0].error.code).toBe('E_DRM_CALLBACK_UNAVAILABLE');
});
