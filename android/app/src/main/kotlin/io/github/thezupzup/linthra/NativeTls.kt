package io.github.thezupzup.linthra

import android.content.Context
import android.util.Log

// Hands the Rust core (native/linthra_core/src/http/android.rs) what it needs
// to verify TLS certificates with Android's own trust manager: the system's
// CAs and the ones the user installed, as network_security_config.xml says.
object NativeTls {
    private const val TAG = "LinthraTls"

    @Volatile
    private var initialized = false

    @JvmStatic
    private external fun init(context: Context)

    // Called once per process by LinthraApplication, before any request can
    // go out of the Rust core. Never throws: failing here leaves Rust's TLS
    // unable to verify a server (so it refuses them), not the app unable to
    // start.
    @Synchronized
    fun initialize(context: Context) {
        if (initialized) return
        try {
            System.loadLibrary("linthra_core")
            init(context.applicationContext)
            initialized = true
        } catch (error: Throwable) {
            Log.w(TAG, "TLS verifier for the Rust core not set up: ${error.javaClass.simpleName}")
        }
    }
}
