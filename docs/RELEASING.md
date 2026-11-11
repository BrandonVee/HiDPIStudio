# 构建与发布

项目使用本地 GitLab 保存代码备份，由 GitHub Actions 在 macOS ARM64 runner 上构建和发布。GitLab 不需要安装 macOS runner。GitHub 云端无法访问 `gitlab.localhost`，所以 GitLab 备份和远程引用校验由本机 `git publish` 在推送 GitHub 前完成。

## 自动触发

| 触发方式 | 结果 |
| --- | --- |
| 推送 `main` / 向 `main` 提交 PR | 构建、运行隔离检查、验证签名和 ZIP，上传 14 天有效的构建产物。 |
| Actions 手动运行 | 选择分支时只构建并上传产物；选择 `vMAJOR.MINOR.PATCH` 标签时也会执行正式 Release 发布。 |
| 推送 `vMAJOR.MINOR.PATCH` 标签 | 检查标签与应用版本一致，构建通过后创建草稿、上传 ZIP 与 SHA256，再发布正式 Release 并标记为 Latest。 |

流程文件：`.github/workflows/build-release.yml`。构建 job 只有代码读取权限，发布 job 才有 `contents: write`；使用 GitHub 自带的 `GITHUB_TOKEN`，无需另存个人访问令牌。依赖的 Actions 固定到提交 SHA。

## 发布一个新版本

1. 更新 `Resources/Info.plist` 的 `CFBundleShortVersionString`，例如 `2.4.1`，并递增 `CFBundleVersion`。更新 `CHANGELOG.md` 中对应的 `## 2.4.1` 条目和中英文 README（`README.md` / `README.en.md`）中的版本与下载链接。
2. 运行 `./scripts/package.sh`。脚本构建干净的应用包，运行 `--test-ci`，检查 ARM64 架构与 ad-hoc 签名，生成 ZIP，解压后再验证签名并生成 SHA256。不会更改实体显示模式或硬件亮度。
3. 检查差异并提交代码，为该提交创建新标签：`git tag -a v2.4.1 -m 'HiDPI Studio 2.4.1'`。
4. 执行 `git publish --tag v2.4.1`。它先原子推送本地分支和指定标签到 `origin`（GitLab），校验远程引用后才推送并校验 `github`。GitLab 失败时停止。
5. 查看 GitHub Actions 的标签运行。只有构建、隔离检查、安装包签名和下载后校验全部通过，Release 才会公开。

`git publish` 是本机已有的发布命令，不属于 Git 自带命令。其他开发机需要按同样顺序分别推送并验证 GitLab 与 GitHub；不要绕过备份直接发布 GitHub 标签。

手动运行 workflow 时，Actions 页面上的 **Use workflow from** 选择会决定发布行为：选择 `main` 或其他分支只执行构建，选择版本标签会触发发布 job。发布前确认标签已经推送到 GitHub，且 `CHANGELOG.md`、`Resources/Info.plist` 与标签版本一致。

## 产物

- `HiDPIStudio-v<版本>-macOS-arm64.zip`：解压后为 `HiDPI Studio.app`。
- `HiDPIStudio-v<版本>-SHA256SUMS.txt`：与应用 ZIP 一起下载到同一目录后，运行 `shasum -a 256 --check <校验文件>`。
- 源码由 GitHub 根据版本标签提供 ZIP / tar.gz 归档；不会将本地偏好、显示器信息或个人编辑器配置装入安装包。

本地输出目录默认为 `dist/`，也可执行 `./scripts/package.sh 2.4.1 /path/to/output`。指定的版本号不符时会在构建前失败。

## 失败与重试

- 构建失败：修复后提交新代码；已经公开的版本应使用新的版本号和标签，不移动旧标签。
- 草稿创建后上传失败：修复临时服务问题后重新运行标签 workflow，允许替换该草稿中的安装包。
- 已公开 Release：workflow 拒绝覆盖已公开的附件，避免同一版本指向不同安装包。
- 不会运行 `--test-virtual`、`--test-workspace`、`--test-persistence` 或实体亮度/模式写入测试；硬件兼容范围见 `VALIDATION.md`。

## 签名范围

当前自动发布正式 Release，使用本地 ad-hoc 签名，面向 Apple Silicon，构建目标为 macOS 13+。未配置 Developer ID 证书、Apple 公证或 Intel 安装包。Release 说明保留签名范围；用户首次打开仍可能需要在 macOS“隐私与安全性”中允许打开。
