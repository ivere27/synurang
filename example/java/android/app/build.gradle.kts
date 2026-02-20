plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.protobuf")
}

android {
    namespace = "com.example.synurang.demo"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.example.synurang.demo"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    externalNativeBuild {
        cmake {
            path = file("../../../../java/src/main/c/CMakeLists.txt")
        }
    }

    // Proto files are copied from the shared directories into src/main/proto/
    // by the copyProtos task (see below).
}

// Copy shared proto files into the standard proto source directory.
// example.proto imports core.proto, so both must be co-located.
val copyProtos = tasks.register<Copy>("copyProtos") {
    from("../../../api/example.proto")  // example/api/example.proto
    from("../../../../api/core.proto")  // api/core.proto
    from("../../../../api/cache.proto") // api/cache.proto
    from("../../api/media.proto")       // example/java/api/media.proto
    into("src/main/proto")
}

tasks.matching { it.name.startsWith("generate") && it.name.contains("Proto") }.configureEach {
    dependsOn(copyProtos)
}

protobuf {
    protoc {
        artifact = "com.google.protobuf:protoc:3.25.1"
    }
    plugins {
        create("grpc") {
            artifact = "io.grpc:protoc-gen-grpc-java:1.60.0"
        }
    }
    generateProtoTasks {
        all().forEach { task ->
            task.builtins {
                create("java") {
                    option("lite")
                }
            }
            task.plugins {
                create("grpc") {
                    option("lite")
                }
            }
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")

    // Protobuf lite
    implementation("com.google.protobuf:protobuf-javalite:3.25.1")

    // gRPC
    implementation("io.grpc:grpc-protobuf-lite:1.60.0")
    implementation("io.grpc:grpc-stub:1.60.0")
    implementation("io.grpc:grpc-okhttp:1.60.0")  // needed for ProcessHost socketpair mode
    compileOnly("javax.annotation:javax.annotation-api:1.3.2")

    // Synurang Java host library (local project)
    implementation(files("../../../../build/java/libs/java.jar"))
}
