// Makes mavenLocal() available for all projects in this build.
// Used to resolve kmp-mail artifacts published via `./gradlew publishToMavenLocal`
// in /home/guettli/projects/kmp-mail.
allprojects {
    repositories {
        mavenLocal()
    }
}
