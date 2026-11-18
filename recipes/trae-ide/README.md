# Trae IDE (international)

本目录是 Trae IDE 国际版的 mylinuxpackages 构建配方。它从上游 Linux tarball
组装 `/opt/trae-ide`，并生成 deb/rpm 包。

## Install

从本仓库 Releases 下载对应发行版的 `.deb` 或 `.rpm` 安装。

## Build locally

```bash
./build-package.sh recipes/trae-ide/recipe.conf --all
```

具体构建逻辑见本目录 `stage.sh` 与仓库根目录 `README.md`。
