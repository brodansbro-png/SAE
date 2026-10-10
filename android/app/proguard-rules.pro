# R8 / ProGuard rules for the SAE attendance app.
#
# ─── Scope ─────────────────────────────────────────────────────────────────────
#
# `isMinifyEnabled` and `isShrinkResources` are on in `build.gradle.kts`, and the
# Dart side is obfuscated separately with `--obfuscate --split-debug-info`. Both
# halves are needed: R8 hides the Java/Kotlin, `--obfuscate` renames the Dart
# symbols that actually contain the geofence and liveness logic.
#
# ─── What this does and does not buy ───────────────────────────────────────────
#
# Obfuscation raises the cost of reading an APK. It does not prevent it. A client
# app runs on hardware the attacker controls, so anything enforced only on the
# device — the geofence decision, the liveness verdict, the integrity checks — is
# a statement of intent, not a guarantee.
#
# That is why the real enforcement lives in `firestore.rules`: the server refuses
# a punch whose `userId` is not the caller's, whose day key does not match, or
# whose check-in already exists. Obfuscation here is one layer among several,
# not the layer that matters.

# ─── Flutter ───────────────────────────────────────────────────────────────────
#
# The embedding is entered from the Android manifest, not from Dart, so nothing in
# the sources references it and R8 cannot see that it is reachable.
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.plugins.** { *; }

# ─── Google Play Services and Firebase ─────────────────────────────────────────
#
# Firebase resolves classes by name at runtime through `Class.forName`, so R8
# sees them as unused. Without these keeps the app builds and then fails at
# startup with a bare `NoClassDefFoundError`.
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# ML Kit loads its face-detection model through a native bridge.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_face.** { *; }

# safe_device's jailbreak and root probes read these by path rather than by
# reference, so R8 cannot see the dependency.
-keep class com.scottyab.** { *; }

# Play Core is referenced by the deferred-components installer. Absent from a
# standard build, but the reference is resolved at runtime.
-dontwarn com.google.android.play.core.**

# ─── Kotlin metadata ───────────────────────────────────────────────────────────
#
# R8 cannot see that a Kotlin class uses reflection-based features — default
# arguments, data-class `copyWith`, exhaustive `when` over sealed types — so the
# synthetic members must be retained or those features throw at runtime.
-keepattributes *Annotation*,InnerClasses,Signature,RuntimeVisibleAnnotations

# ─── Crash reports ─────────────────────────────────────────────────────────────
#
# Source file and line number are stripped by default, which turns any Play
# Console deobfuscation into guesswork. Renaming must stay, so only the
# attribution is retained.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# ─── Diagnostics ───────────────────────────────────────────────────────────────
#
# Uncomment locally to read a stack trace against real names. Never ship this: it
# defeats the obfuscation it exists to debug.
#
# -keepnames class com.sae.presensi.** { *; }
# -keep class com.sae.presensi.** { *; }