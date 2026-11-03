import { ConfigPlugin } from '@expo/config-plugins';
export type StreamDownloaderPluginOptions = {
    enableBackgroundDownloads?: boolean;
};
declare const withStreamDownloader: ConfigPlugin<StreamDownloaderPluginOptions>;
export default withStreamDownloader;
