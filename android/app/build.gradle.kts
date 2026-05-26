import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Keystore configuration ────────────────────────────────────────────────────
// key.properties este exclus din git (vezi .gitignore).
// For local release builds: fill key.properties with the real values.
// For CI/CD: set environment variables and uncomment the block below.
//
// val storePasswordEnv = System.getenv("VAULTCHAT_STORE_PASSWORD") ?: ""
// val keyPasswordEnv   = System.getenv("VAULTCHAT_KEY_PASSWORD") ?: ""

val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
if (keyPropertiesFile.exists()) {
    keyPropertiesFile.inputStream().use { keyProperties.load(it) }
}

// Read values with an empty-string fallback. Debug builds do not require a keystore.
val releaseKeyAlias    : String = keyProperties.getProperty("keyAlias",    "")
val releaseKeyPassword : String = keyProperties.getProperty("keyPassword", "")
val releaseStoreFile   : String = keyProperties.getProperty("storeFile",   "")
val releaseStorePassword: String = keyProperties.getProperty("storePassword", "")

val hasReleaseKeystore = releaseStorePassword.isNotEmpty()
        && releaseKeyPassword.isNotEmpty()
        && releaseStoreFile.isNotEmpty()

android {
    namespace = "com.vaultchat.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.vaultchat.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing config. Created only when the keystore exists.
    // Debug builds always work, regardless of key.properties.
    if (hasReleaseKeystore) {
        signingConfigs {
            create("release") {
                keyAlias     = releaseKeyAlias
                keyPassword  = releaseKeyPassword
                storeFile    = file(releaseStoreFile)
                storePassword = releaseStorePassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled    = true
            isShrinkResources  = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isMinifyEnabled   = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
