
import {
  ConfigPlugin,
  withInfoPlist,
  withAndroidManifest,
} from '@expo/config-plugins';

export type StreamDownloaderPluginOptions = {
  enableBackgroundDownloads?: boolean;
};

const withStreamDownloader: ConfigPlugin<
  StreamDownloaderPluginOptions
> = (config, options = {}) => {
  const enableBackgroundDownloads =
    options.enableBackgroundDownloads ?? false;

  config = withAndroidManifest(config, (modConfig) => {
    const manifest = modConfig.modResults.manifest;

    if (enableBackgroundDownloads) {
      const permissions = manifest['uses-permission'] ?? [];

      const permissionExists = permissions.some(
        (permission) =>
          permission.$?.['android:name'] ===
          'android.permission.FOREGROUND_SERVICE',
      );

      if (!permissionExists) {
        permissions.push({
          $: {
            'android:name':
              'android.permission.FOREGROUND_SERVICE',
          },
        });
      }

      manifest['uses-permission'] = permissions;
    }

    return modConfig;
  });

  config = withInfoPlist(config, (modConfig) => {
    if (enableBackgroundDownloads) {
      modConfig.modResults.UIBackgroundModes = [
        ...new Set([
          ...(modConfig.modResults.UIBackgroundModes ?? []),
          'processing',
        ]),
      ];
    }

    return modConfig;
  });

  return config;
};

export default withStreamDownloader;
