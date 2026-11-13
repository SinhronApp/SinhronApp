# ADR-059 — Credential Manager finds its Play Services provider by reflection
# (Android 13 and older); keep it through R8 in release builds.
-if class androidx.credentials.CredentialManager
-keep class androidx.credentials.playservices.** {
  *;
}
