package io.github.thezupzup.linthra

import com.ryanheise.audioservice.AudioServiceActivity

// Extends AudioServiceActivity (instead of the default FlutterActivity) so the
// single Flutter activity binds to the audio_service media session correctly.
// This is the activity audio_service expects to host the engine; using the
// plain FlutterActivity would leave the background service unable to attach.
class MainActivity : AudioServiceActivity()
