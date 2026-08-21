import com.android.build.api.dsl.LibraryExtension

allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
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

    // flutter_app_badger 1.5.0 predates AGP's required namespace DSL.
    // Configure it from the app without modifying the shared pub cache.
    if (project.name == "flutter_app_badger") {
        pluginManager.withPlugin("com.android.library") {
            extensions.configure<LibraryExtension> {
                namespace = "fr.g123k.flutterappbadge.flutterappbadger"
            }
        }
        afterEvaluate {
            extensions.configure<LibraryExtension> {
                compileSdk = 36
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
