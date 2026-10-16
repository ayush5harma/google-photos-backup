plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.chaquo.python")
}

android {
    namespace = "com.photosbackup"
    compileSdk = 36
    buildToolsVersion = "36.0.0"
    defaultConfig {
        applicationId = "com.photosbackup"
        minSdk = 26
        targetSdk = 36
        versionCode = 400
        versionName =
            rootProject.file("../VERSION").takeIf { it.exists() }?.readText()?.trim() ?: "0.4.0"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    signingConfigs {
        if (System.getenv("ANDROID_KEYSTORE_PATH") != null)
            create("localRelease") {
                storeFile = file(System.getenv("ANDROID_KEYSTORE_PATH"))
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
    }
    buildTypes {
        getByName("debug") { applicationIdSuffix = ".debug" }
        getByName("release") { signingConfig = signingConfigs.findByName("localRelease") }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    packaging { resources.excludes += setOf("META-INF/LICENSE*", "META-INF/NOTICE*") }
}

val syncSharedBridge by
    tasks.registering(Sync::class) {
        from(rootProject.file("../Bridge")) { include("gpmc_bridge.py") }
        into(layout.buildDirectory.dir("generated/sharedBridge"))
    }

tasks
    .matching { it.name.startsWith("merge") && it.name.endsWith("PythonSources") }
    .configureEach { dependsOn(syncSharedBridge) }

chaquopy {
    defaultConfig {
        version = "3.11"
        pip {
            install("gpmc==0.9.0")
            install("bbpb==1.4.2")
            install("requests==2.32.5")
            install("rich==14.2.0")
        }
    }
    sourceSets { getByName("main") { srcDir(layout.buildDirectory.dir("generated/sharedBridge")) } }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.04.01"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.work:work-testing:2.10.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.04.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    // 3.5.0 (Compose's transitive default) reflects InputManager.getInstance,
    // which is absent on Android 17. 3.7.0 uses getSystemService instead.
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
