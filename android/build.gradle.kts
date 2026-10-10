allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// ─── compileSdk floor ──────────────────────────────────────────────────────────
//
// Several plugins still pin `compileSdk 34` in their own build files, while
// `flutter_plugin_android_lifecycle` requires 36. Rather than wait for every
// plugin to publish a release, the app's floor is imposed on every subproject
// after evaluation.
//
// `compileSdk` only decides which API surface is available at compile time — it
// is deliberately separate from `targetSdk`, which opts into runtime behaviour,
// and from `minSdk`, which decides which devices can install the app. Raising it
// therefore cannot change behaviour on a device that is already supported.
val requiredCompileSdk = 36

// AGP 9's DSL lives in `com.android.build.api.dsl`; the `com.android.build.gradle`
// extension classes are deprecated and are gone in AGP 10.
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension> {
            if (compileSdk != null && compileSdk!! < requiredCompileSdk) {
                compileSdk = requiredCompileSdk
            }
        }
    }

    plugins.withId("com.android.application") {
        extensions.configure<com.android.build.api.dsl.ApplicationExtension> {
            if (compileSdk != null && compileSdk!! < requiredCompileSdk) {
                compileSdk = requiredCompileSdk
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}