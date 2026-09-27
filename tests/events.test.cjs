const { boot, status } = require('./helpers/bridge.cjs');

test('hooks subscribe before registration, refresh callbacks, deduplicate and clean up', async () => {
  const b = boot();
  const React = require('react');
  const { create, act } = require('react-test-renderer');
  const first = jest.fn(); const second = jest.fn(); const errors = jest.fn();
  function Watch({ callback }) {
    b.api.useEvent('onDownloadProgress', callback);
    b.api.useEvent('onError', errors);
    return null;
  }
  let tree;
  act(() => { tree = create(React.createElement(Watch, { callback: first })); });
  expect(b.native.setProgressEnabled).toHaveBeenLastCalledWith(b.runtimeId, true);
  await b.api.registerPlugin();
  b.event('onDownloadProgress', [status()], { sequence: 10 });
  b.event('onDownloadProgress', [status()], { sequence: 10 });
  b.event('onDownloadProgress', [status()], { sequence: 9 });
  b.event('onDownloadProgress', [status()], { runtimeId: 'old-runtime', sequence: 100 });
  expect(first).toHaveBeenCalledTimes(1);
  act(() => tree.update(React.createElement(Watch, { callback: second })));
  b.event('onDownloadProgress', [status('downloading', { progress: 0.5, generation: 4 })], { sequence: 11 });
  expect(first).toHaveBeenCalledTimes(1);
  expect(second).toHaveBeenCalledWith([status('downloading', { progress: 0.5 })]);
  b.event('onDownloadProgress', { wrong: 'shape' }, { sequence: 12 });
  expect(errors).toHaveBeenCalledWith('Invalid StreamDownloader native event.');
  act(() => tree.unmount());
  expect(b.native.setProgressEnabled).toHaveBeenLastCalledWith(b.runtimeId, false);
  b.event('onDownloadProgress', [status()], { sequence: 13 });
  expect(second).toHaveBeenCalledTimes(1);
  expect(b.channels.get('StreamDownloaderEvent').size).toBe(1);
});

test('progress intent stays enabled until the final progress hook unmounts', () => {
  const b = boot(); const React = require('react'); const { create, act } = require('react-test-renderer');
  function Watch() { b.api.useEvent('onDownloadProgress', () => {}); return null; }
  let a; let c;
  act(() => { a = create(React.createElement(Watch)); c = create(React.createElement(Watch)); });
  b.native.setProgressEnabled.mockClear();
  act(() => a.unmount());
  expect(b.native.setProgressEnabled).not.toHaveBeenCalled();
  act(() => c.unmount());
  expect(b.native.setProgressEnabled).toHaveBeenCalledTimes(1);
  expect(b.native.setProgressEnabled).toHaveBeenCalledWith(b.runtimeId, false);
});

test('error/end events preserve payload types and ordering without replay', async () => {
  const b = boot(); const React = require('react'); const { create, act } = require('react-test-renderer');
  const log = [];
  function Watch() {
    b.api.useEvent('onError', e => log.push(e));
    b.api.useEvent('onDownloadEnd', s => log.push(s.status));
    return null;
  }
  await b.api.registerPlugin();
  b.event('onDownloadEnd', status('completed', { progress: 1 }));
  let tree; act(() => { tree = create(React.createElement(Watch)); });
  expect(log).toEqual([]);
  b.event('onError', 'Storage write failed.'); b.event('onDownloadEnd', status('failed', { error: 'Storage write failed.' }));
  expect(log).toEqual(['Storage write failed.', 'failed']);
  act(() => tree.unmount());
});
