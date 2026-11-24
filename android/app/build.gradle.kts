import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config is read from android/key.properties when present.
// Both key.properties and the keystore are git-ignored — never commit them.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.buildtoapp.ir_net"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358" // todo: if you upgraded flutter make sure to change this back to flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.buildtoapp.ir_net"
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
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Use the release/upload key when key.properties is present,
            // otherwise fall back to debug signing so the project still builds.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // libv2ray (Go) looks its Java classes up over JNI; keep R8 off them.
            proguardFiles("proguard-rules.pro")
        }
    }

    // libv2ray's AAR bundles geoip.dat / geosite.dat (27 MB), and flutter_v2ray
    // copies them on every start into the folder the user's imported geo files
    // live in, overwriting an imported geoip.dat / geosite.dat. IRNet never
    // uses them (geoip:/geosite: rules need an imported file), so leave them
    // out. The first entries are aapt's defaults, which a custom list replaces.
    androidResources {
        ignoreAssetsPatterns += listOf(
            "!.svn", "!.git", "!.ds_store", "!*.scc", ".*", "<dir>_*", "!CVS", "!thumbs.db", "!picasa.ini", "!*~",
            "geoip.dat", "geosite.dat", "geoip-only-cn-private.dat",
        )
    }

    // flutter_v2ray starts its tun2socks binary from the native library
    // folder, so native libraries must be extracted at install time.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

repositories {
    // AndroidLibXrayLite (libv2ray), as flutter_v2ray resolves it.
    ivy {
        name = "AndroidLibXrayLite"
        url = uri("https://github.com/2dust/AndroidLibXrayLite/releases/download")
        patternLayout { artifact("[revision]/libv2ray.aar") }
        metadataSources { artifact() }
        content { includeGroup("com.github.2dust") }
    }
}

dependencies {
    // The in-app delay tester (XrayTester.kt). Newer than flutter_v2ray asks for
    // (same Java API), so Gradle gives the plugin this one too: the same core
    // as the desktop builds, with the "fragment" finalmask.
    implementation("com.github.2dust:libv2ray:v26.11.9@aar")

    testImplementation("junit:junit:4.13.2")
    // Android's org.json is only a stub in local unit tests.
    testImplementation("org.json:json:20240303")
}

flutter {
    source = "../.."
}
