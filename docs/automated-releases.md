# Automated releases

Every push to `main` (or a manual run of `.github/workflows/release.yml`) creates the next patch version, builds arm64 and x86_64 DMGs, and publishes a GitHub prerelease. The `release` branch points to the latest successfully published snapshot. It is generated and may be replaced with a guarded force push; do not develop on it.

Versions are calculated from the highest existing version tag and project version. Generated version changes live on the tagged release snapshot, not on `main`. A failed build can leave a reserved tag; a later run advances past it. Re-running a workflow starts a new version. Releases remain prereleases because these self-signed builds are not Apple-notarized.

Required repository configuration:

- Actions Secret `TARGETFLOW_CERTIFICATE_P12`: base64-encoded PKCS#12 containing only the persistent signing identity and its private key.
- Actions Secret `TARGETFLOW_CERTIFICATE_PASSWORD`: password protecting that PKCS#12.
- Actions Variable `TARGETFLOW_SIGNING_IDENTITY`: SHA-1 fingerprint of the certificate.

GitHub stores Secrets encrypted. The workflow imports the identity into a temporary macOS runner keychain and removes it after building. People who can modify workflows can use or exfiltrate Secrets, so protect repository write access. Secrets must never appear in logs, Git commits, artifacts, or release downloads. Keep a secure backup of the original certificate and private key. The current self-signed certificate expires on 2027-10-25; plan certificate migration before expiration.

The app bundle identifier and certificate-based designated requirement remain fixed across builds. macOS still controls permissions and Gatekeeper; self-signing is not notarization.
