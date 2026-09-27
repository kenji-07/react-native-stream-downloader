export class DownloaderError extends Error {
  readonly code: string;
  readonly operation: string;
  readonly downloadId?: string;
  readonly nativeCode?: string;
  readonly retryable: boolean;

  constructor(code: string, message: string, operation = 'validation', downloadId?: string) {
    super(message);
    this.name = 'Error';
    this.code = code;
    this.operation = operation;
    this.retryable = false;
    if (downloadId !== undefined) this.downloadId = downloadId;
  }
}

export function asError(value: unknown, operation: string): Error {
  if (value instanceof DownloaderError) return new DownloaderError(value.code, value.message, operation, value.downloadId);
  if (value !== null && typeof value === 'object') {
    const error = value as Record<string, unknown>;
    const userInfo = error.userInfo !== null && typeof error.userInfo === 'object' ? error.userInfo as Record<string, unknown> : {};
    return Object.assign(
      new Error(typeof error.message === 'string' ? error.message : `${operation} failed.`),
      {
        operation,
        code: typeof error.code === 'string' ? error.code : 'E_NATIVE',
        ...(typeof (error.downloadId ?? userInfo.downloadId) === 'string' ? { downloadId: error.downloadId ?? userInfo.downloadId } : {}),
        ...(typeof (error.nativeCode ?? userInfo.nativeCode) === 'string' ? { nativeCode: error.nativeCode ?? userInfo.nativeCode } : {}),
        retryable: (error.retryable ?? userInfo.retryable) === true,
      },
    );
  }
  return new DownloaderError('E_NATIVE', `${operation} failed.`, operation);
}
