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

// プラグイン側の compileSdk を評価後に書き換える手段は AGP のロック順序と衝突するため使わない。
// API36 要求の flutter_plugin_android_lifecycle 7.x は pubspec の dependency_overrides で 2.x に固定する
tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
