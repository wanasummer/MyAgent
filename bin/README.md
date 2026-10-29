# bin/ — 内置 SBCL 运行时

本目录用于存放随项目分发的 SBCL 运行时，让使用者**无需自行安装 SBCL**：

```
bin/
├── sbcl.exe      # Windows 可执行文件（Linux/macOS 为 sbcl）
├── sbcl.core     # 运行时镜像（约 31 MB）
└── contrib/      # ASDF / UIOP 等附加模块（约 14 MB）
```

启动脚本 `start.bat` / `start.sh` 会**优先使用本目录**的运行时，并自动把
`SBCL_HOME` 指向本目录。

## 如何填充

**Windows**：把 SBCL 安装目录（含 `sbcl.exe`、`sbcl.core`、`contrib/`）里的内容
复制到本目录即可，例如：

```bat
robocopy "C:\path\to\sbcl" "%~dp0bin" /E
```

**Linux / macOS**：

```bash
cp -r /usr/local/lib/sbcl/* ./bin/      # 或 brew --prefix sbcl 对应目录
```

也可以从 <https://www.sbcl.org/platform-table.html> 下载官方发行版后解压到本目录。

## 版本控制说明

二进制运行时体积约 48 MB，默认**不纳入 git**（见根目录 `.gitignore` 的 `/bin/*`）。
若要随仓库分发，请使用 Git LFS，或删掉 `.gitignore` 中对应规则。

## 许可

SBCL 采用 Public Domain / BSD 风格许可（详见 <https://www.sbcl.org/>），可随项目一同分发。
