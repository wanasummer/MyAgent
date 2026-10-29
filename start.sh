#!/usr/bin/env sh
# MyAgent launcher (Linux / macOS)
#
# 优先使用项目内置运行时：./bin/sbcl
# 其次使用环境变量 MYAGENT_SBCL，最后回退到 PATH 里的 sbcl。
#
# 可选环境变量：
#   MYAGENT_SBCL=<sbcl 路径>        指定 SBCL
#   MYAGENT_ROOT=<项目根目录>       覆盖项目根目录
#   MYAGENT_MEMORY_DIR=<记忆目录>   覆盖记忆目录
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ -x "$DIR/bin/sbcl" ]; then
    SBCL_BIN="$DIR/bin/sbcl"
    SBCL_HOME="$DIR/bin"
    export SBCL_HOME
else
    SBCL_BIN="${MYAGENT_SBCL:-sbcl}"
fi

if ! command -v "$SBCL_BIN" >/dev/null 2>&1; then
    echo "[MyAgent] 未找到 SBCL。" >&2
    echo "  可将 SBCL 运行时放到 ./bin/（sbcl + sbcl.core + contrib/），" >&2
    echo "  或安装 SBCL，或用 MYAGENT_SBCL 指定可执行文件路径。" >&2
    exit 1
fi

exec "$SBCL_BIN" --noinform --load "$DIR/run.lisp" -- "$@"
