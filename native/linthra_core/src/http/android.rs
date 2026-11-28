//! Gives rustls-platform-verifier the JVM handles it needs to ask Android's
//! trust manager about a certificate. `NativeTls.init` in the Android app
//! (android/app/src/main/kotlin/io/github/thezupzup/linthra/NativeTls.kt)
//! calls this once per process, at startup, before any request goes out.

use jni::errors::ThrowRuntimeExAndDefault;
use jni::objects::{JClass, JObject};
use jni::{jni_mangle, EnvUnowned};

/// `NativeTls.init(context)`. A failure, or a panic (`with_env` catches it,
/// so it never unwinds into the JVM), is thrown back to Kotlin as a
/// `RuntimeException`.
#[jni_mangle("io.github.thezupzup.linthra.NativeTls")]
pub fn init<'caller>(
    mut env: EnvUnowned<'caller>,
    _class: JClass<'caller>,
    context: JObject<'caller>,
) {
    env.with_env(|env| rustls_platform_verifier::android::init_with_env(env, context))
        .resolve::<ThrowRuntimeExAndDefault>();
}
