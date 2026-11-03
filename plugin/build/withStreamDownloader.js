"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const config_plugins_1 = require("@expo/config-plugins");
const withStreamDownloader = (config, options = {}) => {
    const enableBackgroundDownloads = options.enableBackgroundDownloads ?? false;
    config = (0, config_plugins_1.withAndroidManifest)(config, (modConfig) => {
        const manifest = modConfig.modResults.manifest;
        if (enableBackgroundDownloads) {
            const permissions = manifest['uses-permission'] ?? [];
            const permissionExists = permissions.some((permission) => permission.$?.['android:name'] ===
                'android.permission.FOREGROUND_SERVICE');
            if (!permissionExists) {
                permissions.push({
                    $: {
                        'android:name': 'android.permission.FOREGROUND_SERVICE',
                    },
                });
            }
            manifest['uses-permission'] = permissions;
        }
        return modConfig;
    });
    config = (0, config_plugins_1.withInfoPlist)(config, (modConfig) => {
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
exports.default = withStreamDownloader;
