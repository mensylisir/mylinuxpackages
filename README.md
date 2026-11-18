# mylinuxpackages

把桌面 AI 应用与命令行工具构建成 Linux 原生 `.deb` / `.rpm`，并通过 GitHub Actions
发布到本仓库 Releases。仓库与 [myaur](https://github.com/mensylisir/myaur) 相互独立：
myaur 只作为公开资料参考，本仓库不复制、不加载、不依赖其 PKGBUILD 或脚本，所有构建逻辑均在本仓库内实现。

## 目录结构

```
lib/
  common.sh              公共函数
  fetch.sh               下载、缓存、SHA256/BLAKE2b 校验
  build.sh               构建调度与通用 Electron 移植流程
  stage-common.sh        配方 stage 共享 helper
  package-deb.sh         从统一 root 生成 .deb (dpkg-deb)
  package-rpm.sh         从统一 root 生成 .rpm (rpmbuild)
  patch/                 自研 asar / Electron / 区域 / 运行时补丁
build-package.sh         顶层入口：recipe.conf -> deb/rpm
recipes/<app-id>/
  recipe.conf            版本、源、哈希、依赖、阶段模式
  stage.sh               该应用自己的装配逻辑（STAGE_MODE=recipe 时必须存在）
  *.sh / *.desktop / icons / launchers
.github/workflows/
  build-packages.yml     手动触发或 tag 触发，构建并发布
docs/assets/             README 用到的图片（打赏码）
out/                     本地构建产物（gitignore）
```

## 支持的配方

`appclone`、`catpaw`、`catpaw-cn`、`dumate-app`、`gw2api`、`kimi-code-cn`、
`kimi-code-intl`、`kimi-work`、`kimi-work-cn`、`kimi-work-intl`、`mimo-desktop`、
`mimo-desktop-intl`、`minimax-code-cli`、`minimax-code-cn`、`minimax-code-intl`、
`qoder-agent`、`qoder-cn-agent`、`qoder-cn-ide`、`qoder-ide`、`qoderwake`、
`qoderwake-cn`、`trae-cn-ide`、`trae-ide`、`workbuddy`、`workbuddy-intl`、
`zcode-cn`、`zcode-intl`。

## 本地构建

依赖：`p7zip-full unzip rpm file xz-utils build-essential python3 curl`，以及 Node.js 20+。
还需要全局安装 `@electron/asar` 与 `node-gyp`：

```bash
npm install -g @electron/asar node-gyp
```

构建：

```bash
# 同时构建 deb 和 rpm
./build-package.sh recipes/minimax-code-cn/recipe.conf --all

# 只构建 deb
./build-package.sh recipes/appclone/recipe.conf --deb

# 跳过产物校验
./build-package.sh recipes/kimi-code-cn/recipe.conf --all --no-verify
```

产物输出到 `out/`。下载缓存放在 `.cache/`，重复构建不会重新下载，且会按
`SOURCES` 中的 SHA256 / BLAKE2b 校验。

## 两种 stage 模式

- `STAGE_MODE=generic`：使用 `lib/build.sh` 内的通用 Electron 重建流程，
  当前用于 `minimax-code-cn` / `minimax-code-intl`。
- `STAGE_MODE=recipe`：由配方目录自己的 `stage.sh` 提供 `recipe_stage()`，
  负责把来源组装成统一的 `$ROOT`；`lib/build.sh` 只负责下载、校验和调度。

`package-deb.sh` 与 `package-rpm.sh` 都只消费 `$ROOT`，因此同一配方生成的
deb/rpm 内容一致。maintainer scripts 通过 `.mlp-postinst` / `.mlp-postrm`
暂存，再由打包层转换为 `DEBIAN/postinst`、rpm `%post` / `%postun`。

## 特殊处理

- **WorkBuddy / WorkBuddy International**：Electron 是官方 Linux deb 中的定制版本，
  带有私有 `workbuddyStorage` binding；构建时会强制校验，不能替换成普通 Electron。
  两个启动器都会预写 `shortcut-state.json`，避免 Wayland 下首次启动弹出
  “Add keyboard”/快捷键录入窗口；国际版使用独立的 `~/.workbuddy-international`。
- **CatPaw / 妙手**：从 Windows Inno Setup 安装包移植，自带 Electron、Node 与
  Python runtime，原生模块按 Electron ABI 146 编译或替换，并处理 Linux overlay
  与 skill manifest。
- **Kimi Work**：从 Windows NSIS 安装包移植，保留 Linux 工具链、剔除 win32 组件，
  自带 Electron 43 并固定 CN/Intl 区域；三个变体都会关闭 launcher 全局快捷键，
  避免 XDG GlobalShortcuts 弹窗。
- **Qoder / Trae / ZCode / MiMo / DuMate**：优先使用上游 Linux 包或 tarball，
  在本仓库内完成重打包、区域固定、资源路径修正和启动脚本生成。

## GitHub Actions 发布

两种触发方式：

1. Actions 页手动触发：选择配方（`all` 或单个）、格式（deb/rpm/all）、Release tag。
2. 推送 `v*` tag：自动为全部配方构建并发布。

`prepare` job 解析配方矩阵，各配方并行构建，产物上传到同一次 Release，
同时保留 GitHub Actions artifacts 作为备份。

## 新增应用

1. `mkdir recipes/<app-id>/`
2. 写 `recipe.conf`，`SOURCES` 每项格式为 `文件名|URL|checksum`；
   checksum 支持 64 位 SHA256、`b2:<128hex>` 或 `SKIP`；
   本地辅助文件使用 `local:文件名`。
3. 写 `stage.sh`，定义 `recipe_stage()` 并填充 `$ROOT`；
   可复用 `lib/stage-common.sh` 中的解包、图标、maintainer script helper。
4. 在 workflow 的 `inputs.recipe.options` 中加入新 id。

> myaur 中的包名风格（例如 `-bin` 后缀）在部分配方中保留，目的是保持产物名稳定；
> 这不代表运行时依赖 myaur。

## 打赏

如果这些包省了你的时间，可以请我喝杯咖啡。

| 支付宝 | 微信 |
|---|---|
| <img src="docs/assets/donate-alipay.jpg" width="260" alt="支付宝收款码"> | <img src="docs/assets/donate-wechat.jpg" width="260" alt="微信收款码"> |
