plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.r2gallery.r2_gallery"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.r2gallery"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // FAD 配布は CI で固定したデバッグ鍵で署名する。鍵を変えると端末で上書き更新できなくなる
            signingConfig = signingConfigs.getByName("debug")
            // KMP 版のリリース設定と同じく難読化・縮小はしない。プラグインのリフレクションを
            // R8 が消すと実機でしか分からん壊れ方をするので、速さに効く Dart の AOT だけを取る
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // LaunchTheme の親に Theme.AppCompat を使う（local_auth の認証ダイアログが要求）。
    // プラグイン側の依存は app のリソース解決から見えないので、ここで直接持つ
    implementation("androidx.appcompat:appcompat:1.7.0")
}

flutter {
    source = "../.."
}
