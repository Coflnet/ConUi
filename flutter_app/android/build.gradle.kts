import com.android.build.gradle.LibraryExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// contacts_service (a plugin this app depends on, unrelated to the backup
// feature) hasn't been updated for Android Gradle Plugin 8+, which
// requires every Android library module to declare its own `namespace`
// (AGP 8 no longer infers it from the manifest's `package` attribute the
// way older AGP did) - without this, `flutter build apk` fails during
// Gradle configuration with "Namespace not specified" before any of this
// app's own code is even compiled. Patching it here, rather than in the
// plugin's own android/build.gradle under the pub cache (not this
// project's to edit, and wouldn't survive a fresh `pub get` on another
// machine anyway), is the standard workaround for this exact error on an
// unmaintained plugin; the value matches the `package` attribute already
// in contacts_service's own AndroidManifest.xml, so it changes nothing
// about how the plugin resolves at runtime.
subprojects {
    afterEvaluate {
        if (project.name == "contacts_service") {
            extensions.findByType(LibraryExtension::class.java)?.let { android ->
                if (android.namespace == null) {
                    android.namespace = "flutter.plugins.contactsservice.contactsservice"
                }
            }
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
