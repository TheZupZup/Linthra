package io.github.thezupzup.linthra

import android.app.Application

// The process's own start, which every way in shares: the launcher, Android
// Auto and the media service starting without the activity.
class LinthraApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        NativeTls.initialize(this)
    }
}
