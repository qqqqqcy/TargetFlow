# Automated test releases

Every push to `main` (or manual run of `.github/workflows/release.yml`) creates the next patch version, builds arm64 and x86_64 test DMGs, and publishes a GitHub prerelease. The `release` branch points to the latest successfully published snapshot. It is generated and may be replaced with a guarded force push; do not develop on it.

Versions are calculated from the highest existing version tag and project version. Generated version changes live on the tagged release snapshot, not on `main`. A failed build can leave a reserved tag; a later run advances past it. Re-running a workflow starts a new version. Releases remain prereleases because these self-signed builds are not Apple-notarized.

Required repository configuration:

- Actions Secret `TARGETFLOW_CERTIFICATE_P12`: base64-encoded PKCS#12 containing only the persistent signing identity and its private key.
- Actions Secret `TARGETFLOW_CERTIFICATE_PASSWORD`: password protecting that PKCS#12.
- Actions Variable `TARGETFLOW_SIGNING_IDENTITY`: SHA-1 fingerprint of the certificate.

GitHub stores Secrets encrypted. The workflow imports the identity into a temporary macOS runner keychain and removes it after building. People who can modify workflows can use or exfiltrate Secrets, so protect repository write access. Secrets must never appear in logs, Git commits, artifacts, or release downloads. Keep a secure backup of the original certificate and private key. The current self-signed certificate expires on 2027-10-25; plan certificate migration before expiration.

The app bundle identifier and certificate-based designated requirement remain fixed across builds. Migration from the original ad-hoc Test 1 may require one more screen-recording authorization. macOS still controls permissions and Gatekeeper; self-signing is not notarization.

# 自动发布测试版

推送到 `main` 或手动运行发布工作流后，自动递增补丁版本，构建 Apple 芯片和 Intel DMG，并发布 GitHub 预发布版本。`release` 分支指向最新成功发布的快照，是自动生成的分支，可能通过带并发校验的强制推送更新，请勿在上面开发。

版本根据现有标签和项目版本计算，自动版本提交只保留在发布快照和标签中，不回写 `main`。构建失败可能留下已预留的标签，后续发布会跳过它；重新运行工作流会生成新版本。安装包未经 Apple 公证，因此保持为测试预发布。

私钥和证书包密码分别保存在 GitHub Actions 加密 Secret 中，签名指纹放在 Actions Variable 中。临时 macOS runner 导入后签名，完成后删除钥匙串。仓库写入者可以修改工作流使用或泄露 Secret，因此应保护仓库写入权限。私钥不得出现在日志、Git 提交、构建产物或下载包中。请安全备份原证书与私钥；当前证书于 2027-10-25 到期，需要提前规划迁移。

固定证书避免代码变更导致签名身份变化。从原临时签名 Test 1 迁移时仍可能需要重新授权一次；系统保留权限控制权，自签名不等于 Apple 公证。
