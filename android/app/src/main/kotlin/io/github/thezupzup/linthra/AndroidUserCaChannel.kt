package io.github.thezupzup.linthra

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore

// Reads user-installed CA certificates from Android's trusted CA store.
// Dart can then add these certificates to its normal TLS trust roots.
class AndroidUserCaChannel {
    private val worker = PlatformChannelWorker()

    fun configure(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getUserCaCertificates" -> worker.submit(
                    work = {
                        val store = KeyStore.getInstance("AndroidCAStore")
                        store.load(null, null)

                        val certificates = mutableListOf<ByteArray>()
                        val aliases = store.aliases()

                        while (aliases.hasMoreElements()) {
                            val alias = aliases.nextElement()

                            // Keep only user-installed CAs, not system CAs.
                            if (alias.startsWith("user:")) {
                                store.getCertificate(alias)?.encoded?.let {
                                    certificates.add(it)
                                }
                            }
                        }

                        certificates
                    },
                    onSuccess = { certificates ->
                        result.success(certificates)
                    },
                    onFailure = {
                        result.error(
                            "ca_store_unavailable",
                            "Unable to read Android user CA certificates.",
                            null,
                        )
                    },
                )

                else -> result.notImplemented()
            }
        }
    }

    companion object {
        const val CHANNEL = "io.github.thezupzup.linthra/user_cas"
    }
}
