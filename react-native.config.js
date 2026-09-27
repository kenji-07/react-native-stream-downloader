module.exports = {
  dependency: {
    platforms: {
      android: {
        sourceDir: './android',
        packageImportPath: 'import org.openoffline.streamdownloader.StreamDownloaderPackage;',
        packageInstance: 'new StreamDownloaderPackage()',
      },
    },
  },
};
