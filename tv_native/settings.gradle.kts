pluginManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Spiegel von Maven Central (hilft bei 429 „Too Many Requests“).
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
    }
}
rootProject.name = "JasonStreamTV"
include(":app", ":core", ":data", ":player")
