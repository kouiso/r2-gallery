plugins {
    kotlin("jvm") version "2.2.20"
    id("org.jetbrains.compose") version "1.9.0"
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.20"
    id("org.jetbrains.kotlin.plugin.serialization") version "2.2.20"
}
dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.7.1")
    implementation("io.coil-kt.coil3:coil-compose:3.3.0")
}
kotlin { jvmToolchain(21) }
tasks.register<JavaExec>("render") {
    mainClass.set("RenderKt")
    classpath = sourceSets.main.get().runtimeClasspath
    systemProperty("java.awt.headless", "true")
    args(listOfNotNull((project.findProperty("out") ?: "out").toString(), project.findProperty("only")?.toString()))
}
