// Test-only transport. It records calls; it does not emulate a media engine.
function boot(platform = 'android') {
  jest.resetModules();
  const channels = new Map();
  const replies = new Map([
    ['registerPlugin', true], ['disablePlugin', true],
    ['getConfig', { updateFrequencyMS: 1000, maxParallelDownloads: 5 }],
    ['getDownloadStatus', null], ['getDownloadedAsset', null],
    ['getDownloadedAssets', []], ['getDownloadsStatus', []],
    ['getAvailableTracks', { audio: [], video: [], text: [] }],
  ]);
  const commands = [];
  const native = {
    execute: jest.fn(command => {
      commands.push(command);
      const reply = replies.get(command.method);
      return Promise.resolve(typeof reply === 'function' ? reply(command) : reply ?? null);
    }),
    completeLicenseRequest: jest.fn(() => Promise.resolve(null)),
    setProgressEnabled: jest.fn(), addListener: jest.fn(), removeListeners: jest.fn(),
  };
  class NativeEventEmitter {
    addListener(channel, callback) {
      if (!channels.has(channel)) channels.set(channel, new Set());
      channels.get(channel).add(callback);
      return { remove: () => channels.get(channel).delete(callback) };
    }
  }
  const rn = { Platform: { OS: platform }, NativeModules: { StreamDownloader: native }, NativeEventEmitter };
  jest.doMock('react-native', () => rn);
  const api = require('../../lib');
  const { runtimeId } = require('../../lib/internal/native');
  let sequence = 0;
  let licenseSequence = 0;
  function emit(channel, value) { for (const cb of channels.get(channel) ?? []) cb(value); }
  return {
    api, native, replies, commands, rn, channels, runtimeId, emit,
    event(event, payload, overrides = {}) {
      emit('StreamDownloaderEvent', { runtimeId, sequence: ++sequence, event, payload, ...overrides });
    },
    license(overrides = {}) {
      emit('StreamDownloaderLicenseRequest', {
        runtimeId, sequence: ++licenseSequence, requestId: `request-${licenseSequence}`, callbackRef: '',
        assetId: 'a', spcString: 'U1BD', contentId: 'content', licenseUrl: '',
        loadedLicenseUrl: 'skd://content', ...overrides,
      });
    },
  };
}
const status = (state = 'pending', extra = {}) => ({ id: 'a', url: 'https://media.test/master.m3u8', progress: 0, status: state, ...extra });
const deferred = () => { let resolve; let reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
module.exports = { boot, status, deferred, flush };
