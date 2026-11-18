# mylinuxpackages

用 GitHub Actions 把桌面应用（主要是 Windows Electron 应用）重打包成 Linux 原生
`.deb` 和 `.rpm`，发布到本仓库的 Releases。与 [myaur](https://github.com/mensylisir/myaur)
相互独立——那边是 AUR（pkg.tar.zst），这里只做 deb/rpm。

## 目录结构

```
lib/                    通用构建框架（与具体应用无关）
  common.sh             公共函数
  fetch.sh              带 SHA256 校验的下载与缓存
  build.sh              通用移植构建：解包 → 换运行时 → 替换原生模块 → 打补丁 → stage
  package-deb.sh        stage → .deb (dpkg-deb)
  package-rpm.sh        stage → .rpm (rpmbuild)
build-package.sh        顶层入口：recipe → deb/rpm
recipes/<应用>/         每个应用一个配方目录
  recipe.conf           声明式配方（版本、源、哈希、原生模块、依赖）
  patch-region.js       应用专属补丁脚本（可选）
  repack-asar.js        asar 头重写脚本（可选）
  *.sh / *.desktop / *.png   启动脚本、桌面项、图标
.github/workflows/
  build-packages.yml    构建并发布到 Release
out/                    本地构建产物（gitignore）
```

## 本地构建

依赖：`p7zip-full unzip rpm file xz-utils node-gyp build-essential python3 curl`,
以及 Node.js 20+。

```bash
# 构建全部格式
./build-package.sh recipes/minimax-code-cn/recipe.conf --all

# 只构建 deb
./build-package.sh recipes/minimax-code-intl/recipe.conf --deb

# 产物在 out/
```

下载带 SHA256 校验，缓存到 `.cache/`，重复构建不会重新下载。

## GitHub Actions 发布

两种触发方式：

1. **Actions 页手动触发**：选配方（`all` 或单个）、格式、Release tag。
2. **推送 tag**：`git tag v3.1.16 && git push origin v3.1.16`，自动为所有配方构建。

`prepare` job 解析配方矩阵，各配方并行构建，产物上传到同一次 Release。

## 新增一个应用

1. `mkdir recipes/<app-id>/`
2. 写 `recipe.conf`（参考现有配方；`SOURCES` 里每项格式为 `文件名|URL|sha256`）
3. 放入该应用需要的补丁脚本、启动脚本、desktop、图标
4. 在 workflow 的 `inputs.recipe.options` 里加上新 id（选填，手动触发才能选）

框架支持的 `EXE_FORMAT`：`nsis`（NSIS 安装包，指定内层 7z 路径）、`inno`
（Inno Setup，需额外指定 `INNOEXTRACT_FILE`）。

## 设计说明

- 移植逻辑来自已验证的打包实践：解包上游安装器 → 换成同版本官方 Linux Electron
  运行时 → 剔除 Windows/macOS 原生二进制 → 用 N-API/prebuilt/node-gyp 三种方式
  补回 Linux 原生模块 → 重写 asar 头 → 组装 `/opt` 目录。
- deb 用 `dpkg-deb`，rpm 用 `rpmbuild`（系统自带，无第三方运行时依赖）。
- 两者从同一份 `stage/` 打包，内容一致。
