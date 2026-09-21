import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. `android/key.properties` (gitignored — see
// key.properties.example) names the upload keystore; when it is absent a
// release build falls back to the debug key so `flutter run --release`
// still works on a dev machine. Play App Signing holds the real app key;
// this one only signs uploads, but back it up all the same.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.willcharlesgill.wordwizard"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // The dictionary ships as an install-time asset pack (see
    // dictionary_pack/build.gradle.kts) rather than a Flutter asset. Gradle
    // only packs asset packs into *bundles*; an APK built with `assemble`
    // (flutter run, flutter build apk) would come out without it — so for
    // those the same file is folded into the base APK's assets instead.
    // Either way the app finds it at AssetManager "dictionary.db".
    assetPacks += listOf(":dictionary_pack")
    val buildingBundle = gradle.startParameter.taskNames.any { it.contains("bundle", ignoreCase = true) }
    if (!buildingBundle) {
        sourceSets.getByName("main").assets.srcDirs("../dictionary_pack/src/main/assets")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications' use of java.time APIs.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Permanent: Play ties the listing to it and it can never change
        // after the first upload. It is not user-facing, which is why the
        // Lexery rename left it alone (docs/DESIGN.md).
        applicationId = "com.willcharlesgill.wordwizard"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
