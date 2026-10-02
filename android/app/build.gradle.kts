plugins {
    id("com.android.application")
}

android {
    namespace = "com.anicat.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.anicat.android"
        minSdk = 26
        targetSdk = 34
        // The app's version is version.txt's, like the desktop builds.
        versionName = file("../../version.txt").readText().trim()
        versionCode = versionName!!.split('.', '-').take(3).let { (a, b, c) -> a.toInt() * 10000 + b.toInt() * 100 + c.toInt() }
        // The engine is built for arm64 only; the libmpv AAR carries more.
        ndk { abiFilters += "arm64-v8a" }
    }

    buildTypes {
        release {
            // Signed with the debug key so `assembleRelease` installs; there
            // is no distributed Android build and so no release key.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        // Uncompressed and page-aligned in the APK, mapped from it directly.
        jniLibs.useLegacyPackaging = false
    }
}

dependencies {
    // libmpv with FFmpeg, prebuilt from mpv-android's scripts.
    implementation("dev.jdtech.mpv:libmpv:1.0.0")
}
