package org.openoffline.streamdownloader.background;

import android.app.Service;

/**
 * Java allows the API 35 overload to be declared while compiling against 34.
 * Both platform timeout callbacks dispatch to the same immediate stop path.
 */
public abstract class TimeoutAwareService extends Service {
    protected abstract void handleTimeout();
    @Override public void onTimeout(int startId) { handleTimeout(); }
    public void onTimeout(int startId, int foregroundServiceType) { handleTimeout(); }
}
