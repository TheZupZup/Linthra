package org.rustls.platformverifier

// Stands in for the BuildConfig of the upstream Android library, whose
// CertificateVerifier.kt (vendored beside this) reads it: the test-only mock
// trust store stays off in the app.
internal object BuildConfig {
    const val TEST = false
}
