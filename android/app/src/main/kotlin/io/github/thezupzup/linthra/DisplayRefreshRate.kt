package io.github.thezupzup.linthra

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import android.view.Display

/**
 * Opts the single Flutter window into the display's *native* refresh rate
 * (90 / 120 / 144 Hz where the panel supports it) instead of the 60 Hz many
 * OEMs hand an app by default.
 *
 * ## Why this is needed
 * A Flutter UI renders at whatever refresh rate the platform runs the app's
 * window at. On a lot of high-refresh phones — Samsung and several others — that
 * window defaults to 60 Hz unless the app explicitly asks for a higher
 * [Display.Mode]. Without this, scrolling the Songs/Albums/Queue lists and the
 * Now Playing animations are capped at 60 fps on panels that can do far better.
 *
 * ## What it does (and deliberately does not do)
 * - It picks the **highest refresh rate among the modes that match the current
 *   resolution**, so the only thing that changes is the refresh rate — a
 *   seamless switch — never the rendered resolution. It never downgrades
 *   resolution to chase a higher rate.
 * - It targets whatever the device actually supports; it never hard-codes a
 *   rate. A 90 Hz panel gets 90, a 144 Hz panel gets 144, a 60 Hz panel is left
 *   alone.
 * - **Battery saver is respected as the system's call, not ours.** When
 *   [PowerManager.isPowerSaveMode] is on, the preferred-mode pin is *released*
 *   (set back to "no preference") so Android is free to drop the refresh rate to
 *   save power. We never force a high rate over the system's power management,
 *   and we re-evaluate the moment battery saver toggles
 *   ([PowerManager.ACTION_POWER_SAVE_MODE_CHANGED]).
 *
 * ## Lifecycle
 * The pin lives on the window's `LayoutParams` and only matters while the
 * activity is in the foreground, so [onResume]/[onPause] drive it: [onResume]
 * applies the preference and starts listening for battery-saver changes;
 * [onPause] stops listening. Re-applying on every resume also re-asserts the
 * preference after a config change recreates the window.
 */
class DisplayRefreshRate(private val activity: Activity) {

    /**
     * Listens for battery-saver toggles while the activity is foregrounded so a
     * change to power-save mode re-evaluates the refresh-rate preference
     * immediately, rather than only on the next resume. Null while not
     * registered.
     */
    private var powerSaveReceiver: BroadcastReceiver? = null

    /** Apply the preferred mode and begin reacting to battery-saver changes. */
    fun onResume() {
        applyPreferredMode()
        registerPowerSaveListener()
    }

    /** Stop reacting to battery-saver changes; the window pin itself persists. */
    fun onPause() {
        val receiver = powerSaveReceiver ?: return
        powerSaveReceiver = null
        // Best-effort: a receiver that is somehow already unregistered throws
        // here, which must never crash a normal pause.
        try {
            activity.unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
        }
    }

    private fun registerPowerSaveListener() {
        if (powerSaveReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                applyPreferredMode()
            }
        }
        // ACTION_POWER_SAVE_MODE_CHANGED is a protected system broadcast, so a
        // context-registered receiver for it needs no export flag even on API
        // 34+. Registration is best-effort: if it ever fails, onResume's direct
        // call still covers the common foreground/return cases, so the live
        // toggle is a bonus, never a crash.
        try {
            activity.registerReceiver(
                receiver,
                IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
            )
            powerSaveReceiver = receiver
        } catch (_: Exception) {
        }
    }

    /**
     * Pin the window to the highest-refresh mode at the current resolution, or —
     * under battery saver — release the pin so the system can manage the rate.
     * Idempotent: it only writes the window's `LayoutParams` when the preferred
     * mode id actually changes, so a repeat call (resume, broadcast) is a no-op
     * once the window is already where we want it.
     *
     * Every per-mode display API touched here (`preferredDisplayModeId`,
     * [Display.getMode], [Display.getSupportedModes]) is API 23+, so the whole
     * body sits behind one `SDK_INT` guard.
     */
    private fun applyPreferredMode() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val window = activity.window ?: return
        val powerManager =
            activity.getSystemService(Context.POWER_SERVICE) as? PowerManager

        val targetModeId: Int = if (powerManager?.isPowerSaveMode == true) {
            // Hand refresh-rate control back to the system so it may lower the
            // rate to conserve power. We do not override power management.
            0
        } else {
            val display = currentDisplay()
            val active = display?.mode ?: return

            // Highest refresh rate among modes that keep the *current*
            // resolution, so the switch only raises the frame rate (seamless)
            // and never changes what is rendered.
            var best = active
            for (mode in display.supportedModes) {
                if (mode.physicalWidth == active.physicalWidth &&
                    mode.physicalHeight == active.physicalHeight &&
                    mode.refreshRate > best.refreshRate + REFRESH_RATE_EPSILON
                ) {
                    best = mode
                }
            }
            // Nothing faster at this resolution: leave the preference cleared so
            // the system keeps full control (including dropping to a lower idle
            // rate for static content). Pinning the only/native mode would
            // needlessly suppress that.
            if (best.modeId != active.modeId) best.modeId else 0
        }

        val params = window.attributes
        if (params.preferredDisplayModeId == targetModeId) return
        params.preferredDisplayModeId = targetModeId
        window.attributes = params
    }

    /**
     * The display hosting this activity. [Activity.getDisplay] is the supported
     * accessor from API 30; below that we fall back to the (deprecated, but
     * correct for a single-display phone) default display.
     */
    private fun currentDisplay(): Display? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay
        }
    }

    private companion object {
        // Reported refresh rates are floats (e.g. 59.96, 120.0); a small epsilon
        // keeps "is this mode actually faster" from tripping on rounding noise.
        const val REFRESH_RATE_EPSILON = 1f
    }
}
