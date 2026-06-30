package io.github.thezupzup.linthra

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// Switches the app's launcher icon by enabling exactly one <activity-alias> and
// disabling the rest. Every alias targets .MainActivity, so the launched
// activity, the audio_service media session, Android Auto, notifications, and
// deep links are identical regardless of which icon is showing — only the
// home-screen / app-drawer icon changes.
//
// Toggling is done with PackageManager.setComponentEnabledSetting(...,
// DONT_KILL_APP), so the running process — including the audio foreground
// service and its notification — is never killed by the switch.
//
// The Dart side (AndroidLauncherIconService) sends the alias *simple* name
// (e.g. "IconNeon"); the full component is "<packageName>.<alias>". The alias
// list below MUST mirror the <activity-alias android:name=".Icon…"> entries in
// AndroidManifest.xml and LauncherIconAliases on the Dart side.
class LauncherIconChannel(private val context: Context) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Android always supports the component-enabled API; the platform
            // split lives on the Dart side, so this is a constant true.
            "isSupported" -> result.success(true)
            "getEnabledIcon" -> result.success(currentEnabledAlias())
            "setIcon" -> {
                val alias = call.argument<String>("alias")
                if (alias == null || alias !in ALIASES) {
                    result.error("bad_args", "Unknown launcher alias: $alias", null)
                } else {
                    setIcon(alias, result)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun setIcon(target: String, result: MethodChannel.Result) {
        try {
            val pm = context.packageManager
            // Enable the target first, then disable the others, so there is
            // never a window with zero enabled launcher aliases (which would
            // make the app vanish from the launcher).
            applyState(pm, target, enabled = true)
            for (alias in ALIASES) {
                if (alias != target) {
                    applyState(pm, alias, enabled = false)
                }
            }
            result.success(true)
        } catch (e: Exception) {
            // Surface as a channel error; the Dart side treats any failure as
            // "not applied" and keeps the in-app selection.
            result.error("set_icon_failed", e.message, null)
        }
    }

    // Writes the enabled/disabled setting for one alias, but only when its
    // *effective* state differs from what we want — so re-asserting the current
    // icon (e.g. on every cold start) writes nothing and triggers no launcher
    // refresh.
    private fun applyState(pm: PackageManager, alias: String, enabled: Boolean) {
        val component = ComponentName(context, "${context.packageName}.$alias")
        if (isEffectivelyEnabled(pm.getComponentEnabledSetting(component), alias)
            == enabled
        ) {
            return
        }
        pm.setComponentEnabledSetting(
            component,
            if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            },
            PackageManager.DONT_KILL_APP,
        )
    }

    private fun currentEnabledAlias(): String {
        val pm = context.packageManager
        for (alias in ALIASES) {
            val component = ComponentName(context, "${context.packageName}.$alias")
            if (isEffectivelyEnabled(pm.getComponentEnabledSetting(component), alias)) {
                return alias
            }
        }
        return DEFAULT_ALIAS
    }

    // getComponentEnabledSetting returns COMPONENT_ENABLED_STATE_DEFAULT until a
    // setting has ever been written, in which case the manifest's android:enabled
    // decides: only the default alias ships enabled. Map DEFAULT back to that so
    // a never-touched install reads as "Classic enabled, others disabled".
    private fun isEffectivelyEnabled(state: Int, alias: String): Boolean {
        return when (state) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
            else -> alias == DEFAULT_ALIAS
        }
    }

    companion object {
        const val CHANNEL = "io.github.thezupzup.linthra/launcher_icon"

        private const val DEFAULT_ALIAS = "IconClassic"

        private val ALIASES = listOf(
            "IconClassic",
            "IconDark",
            "IconNeon",
            "IconServer",
            "IconWaveform",
            "IconLonely",
            "IconGold",
            "IconBlackWhite",
        )
    }
}
