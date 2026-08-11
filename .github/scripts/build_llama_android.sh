#!/usr/bin/env bash
# v0.1.0 ｜ llama.android 本地 LLM 引擎全源码自编脚本（GitHub Actions / Ubuntu）
#
# 复用 llama.cpp 官方 examples/llama.android/lib 模块的 CMake（-S 指向其 cpp 目录，
# 内部 LLAMA_SRC 相对路径自动上溯到 llama.cpp 仓库根），在 CI 上用 Android NDK + CMake
# 独立交叉编译 libai-chat.so 全家，绕开 AGP/Gradle（本机禁编译，一切走 CI）。
#
# 用法：
#   ANDROID_NDK_ROOT=<绝对路径> LLAMA_RELEASE=b10355 ./build_llama_android.sh [输出目录]
# 产物：
#   <输出目录>/engine/*.so —— libai-chat / libllama / libllama-common / libggml* 全家
#   <输出目录>/llama-engine-<release>.tar.gz
set -euo pipefail

LLAMA_RELEASE="${LLAMA_RELEASE:?需指定 llama.cpp release tag，如 b10355}"
NDK_ROOT="${ANDROID_NDK_ROOT:?需指定 ANDROID_NDK_ROOT}"
OUT_DIR="${1:-$PWD/engine-out}"
LLAMA_SRC_DIR="${LLAMA_CPP_SRC:-$PWD/llama.cpp}"

ARCH="arm64-v8a"
# 编译档 = 30（Android 11）。原因：官方 bridge logging.h 调用
# __android_log_is_loggable（API 30 才引入），CPU 内核虽只用 posix_memalign(17+)，
# 但 JNI 壳日志头卡死在 API 30 → 编档必须 ≥30。
# app 侧 minSdk 仍为 26，运行时用 SDK_INT>=30 特性开关（Android 11+ 本地引擎，
# 老机型静默回落云端），与 docs/15 双引擎架构一致。
PLATFORM="30"
NJOBS="${NJOBS:-$(nproc 2>/dev/null || echo 4)}"

echo "==> [1/4] 检出 llama.cpp @ ${LLAMA_RELEASE}"
mkdir -p "$LLAMA_SRC_DIR"
if [ ! -d "$LLAMA_SRC_DIR/.git" ]; then
  echo "    clone（浅克隆）..."
  git clone --depth 1 --branch "$LLAMA_RELEASE" https://github.com/ggml-org/llama.cpp "$LLAMA_SRC_DIR"
else
  echo "    已存在，git fetch tag..."
  (cd "$LLAMA_SRC_DIR" \
    && git fetch --depth 1 origin "refs/tags/$LLAMA_RELEASE:refs/tags/$LLAMA_RELEASE" \
    && git checkout -f "$LLAMA_RELEASE")
fi

CMAKE_DIR="$LLAMA_SRC_DIR/examples/llama.android/lib/src/main/cpp"
test -f "$CMAKE_DIR/CMakeLists.txt" || {
  echo "FATAL: 官方 AI Chat CMakeLists 缺失: $CMAKE_DIR" >&2; exit 1
}

echo "==> [2/4] CMake 配置（arm64-v8a / android-$PLATFORM / Release / Ninja）"
BUILD_DIR="$PWD/build-android"
cmake -S "$CMAKE_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ARCH" \
  -DANDROID_PLATFORM="$PLATFORM" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MESSAGE_LOG_LEVEL=DEBUG \
  -DCMAKE_VERBOSE_MAKEFILE=ON \
  -DBUILD_SHARED_LIBS=ON \
  -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_COMMON=ON \
  -DLLAMA_OPENSSL=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_LLAMAFILE=OFF

echo "==> [3/4] 编译（${NJOBS} 线程）"
cmake --build "$BUILD_DIR" --config Release -j"$NJOBS"

echo "==> [4/4] 收集产物 + strip"
STRIP="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
test -x "$STRIP" || { echo "FATAL: llvm-strip 未找到: $STRIP" >&2; exit 1; }

mkdir -p "$OUT_DIR/engine"
# 需要的 .so：ai-chat / llama / llama-common / ggml / ggml-base / ggml-cpu（静态注册）
# 排除：server/cli/bench 等（LLAMA_BUILD_APP=OFF 本应不产生，防御性剔除）、rpc/sycl
find "$BUILD_DIR" -name '*.so' \( -name '*rpc*' -o -name '*sycl*' -o -name '*server*' \
  -o -name '*-cli*' -o -name '*bench*' -o -name '*impl*' -o -name '*mtmd*' \) -delete

FOUND=0
while IFS= read -r -d '' so; do
  base="$(basename "$so")"
  case "$base" in
    libai-chat.so|libllama.so|libllama-common.so|libggml-base.so|libggml.so|libggml-cpu.so)
      "$STRIP" --strip-debug --strip-unneeded -o "$OUT_DIR/engine/$base" "$so"
      echo "    strip -> $base ($(du -h "$OUT_DIR/engine/$base" | cut -f1))"
      FOUND=1
      ;;
    *) echo "    跳过 $base" ;;
  esac
done < <(find "$BUILD_DIR" -name '*.so' -print0)

if [ "$FOUND" = "0" ]; then
  echo "FATAL: 未收集到任何目标 .so" >&2; exit 1
fi

# libomp.so：官方 arm64 默认 GGML_OPENMP=ON，各 .so NEEDED 依赖 libomp，
# 但 Android 系统库不提供它（NDK 自带），必须随引擎打包，否则真机
# dlopen 报 library "libomp.so" not found。
# 实测 NDK r29 的 aarch64 libomp 位于 LLVM 工具链内：
#   .../lib/clang/<ver>/lib/linux/aarch64/libomp.so
# NOT sysroot/usr/lib/aarch64-linux-android/（社区资料多写这里，易误判）。
# 用可移植 find：优先含 /linux/aarch64/ 的路径，否则全局兜底并校验 ELF aarch64。
OMP_SRC="$(find "$NDK_ROOT" -name 'libomp.so' 2>/dev/null | grep '/linux/aarch64/' | head -1)"
if [ -z "$OMP_SRC" ]; then
  OMP_SRC="$(find "$NDK_ROOT" -name 'libomp.so' 2>/dev/null | head -1)"
fi
if [ -z "$OMP_SRC" ]; then
  echo "FATAL: NDK 未找到 libomp.so（GGML_OPENMP=ON 的运行时依赖）" >&2
  exit 1
fi
"$STRIP" --strip-debug --strip-unneeded -o "$OUT_DIR/engine/libomp.so" "$OMP_SRC"
echo "    strip -> libomp.so from $OMP_SRC ($(du -h "$OUT_DIR/engine/libomp.so" | cut -f1))"

echo "    tar 打包..."
TARBALL="$OUT_DIR/llama-engine-${LLAMA_RELEASE}-${ARCH}.tar.gz"
tar -czf "$TARBALL" -C "$OUT_DIR" engine
echo "==> 完成: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
echo "ENGINE_TARBALL=$TARBALL"