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

echo "==> [1.5/4] OpenCL 依赖准备（Adreno GPU 加速，llama.cpp 官方 OPENCL.md 路径）"
# 编译期：find_package(OpenCL REQUIRED) 需要 OpenCL 头文件 + libOpenCL.so（ICD loader），
# NDK sysroot 均不带 → 从 Khronos 源码 clone + 交叉编译，装进 NDK sysroot。
# 运行时：libOpenCL.so 随引擎打包（见 [4/4] 收集），app manifest 用
#   <uses-native-library android:name="libOpenCL.so" android:required="false" />
#   加载系统 vendor 驱动；llama.cpp OpenCL backend 初始化失败自动回落 CPU。
SYSROOT="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
THIRD_PARTY="$LLAMA_SRC_DIR/third_party"
OPENCL_HEADERS="$THIRD_PARTY/OpenCL-Headers"
OPENCL_ICD="$THIRD_PARTY/OpenCL-ICD-Loader"
OPENCL_BUILD="$PWD/build-opencl"
mkdir -p "$THIRD_PARTY"
if [ ! -d "$OPENCL_HEADERS/.git" ]; then
  echo "    clone OpenCL-Headers ..."
  git clone --depth 1 https://github.com/KhronosGroup/OpenCL-Headers.git "$OPENCL_HEADERS"
fi
if [ ! -d "$OPENCL_ICD/.git" ]; then
  echo "    clone OpenCL-ICD-Loader ..."
  git clone --depth 1 https://github.com/KhronosGroup/OpenCL-ICD-Loader.git "$OPENCL_ICD"
fi
# ICD loader 编译 libOpenCL.so（同 NDK toolchain / arm64-v8a）
# 注意1：必须 c++_static——ICD loader 是纯 C，不需要 C++ STL；
#   若用 c++_shared 会让 libOpenCL.so NEEDED libc++_shared.so，违反本项目
#   「全静态链、禁止 libc++_shared」门禁（llama.rn 的 build-opencl.sh 用 shared
#   是因为 RN 侧允许，WiseMuse 侧不允许）。
# 注意2：ICD loader 自带 VERSION/SOVERSION（libOpenCL.so.1），SONAME 默认是
#   libOpenCL.so.1。Android linker 按 DT_NEEDED 的 SONAME 找库，若记录成
#   libOpenCL.so.1 而 jniLibs 只有 libOpenCL.so，dlopen 会失败。故用
#   -Wl,-soname,libOpenCL.so 强制 SONAME 无版本号（Android 系统 vendor 驱动
#   也是这个名字），保证 NEEDED 闭环。
echo "    编译 OpenCL ICD loader -> libOpenCL.so ..."
cmake -S "$OPENCL_ICD" -B "$OPENCL_BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ARCH" \
  -DANDROID_PLATFORM="$PLATFORM" \
  -DCMAKE_BUILD_TYPE=Release \
  -DANDROID_STL=c++_static \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-soname,libOpenCL.so" \
  -DOPENCL_ICD_LOADER_HEADERS_DIR="$OPENCL_HEADERS" \
  -DBUILD_TESTING=OFF
cmake --build "$OPENCL_BUILD" -j"$NJOBS"
test -f "$OPENCL_BUILD/libOpenCL.so" || {
  echo "FATAL: libOpenCL.so 编译失败" >&2; exit 1
}
# 装进 sysroot（find_package(OpenCL) 从 sysroot 找头/库）。
# 注意：CI 的 NDK 装在 /opt/android-ndk 且 chmod 只给了 a+rX（无写权限），
# 非 root runner 用户直接 cp 会 Permission denied（实测失败点）→ 用 sudo。
# 首次建目录时 sudo 保证属主权限，后续非 sudo 也能读。
sudo mkdir -p "$SYSROOT/usr/include" "$SYSROOT/usr/lib/aarch64-linux-android"
sudo cp -r "$OPENCL_HEADERS/CL" "$SYSROOT/usr/include/"
sudo cp "$OPENCL_BUILD/libOpenCL.so" "$SYSROOT/usr/lib/aarch64-linux-android/"

# patch ai_chat.cpp：开 GPU offload（默认 n_gpu_layers=0 只会用 CPU）。
# llama.cpp 在 GPU backend 不可用时自动回落 CPU（offloaded 0/M layers），无风险。
AI_CHAT="$CMAKE_DIR/ai_chat.cpp"
sed -i 's/llama_model_params model_params = llama_model_default_params();/&\n    model_params.n_gpu_layers = 99; \/\/ [WiseMuse] offload all layers to GPU via OpenCL/' "$AI_CHAT"
grep -q "n_gpu_layers = 99" "$AI_CHAT" || {
  echo "FATAL: ai_chat.cpp offload patch 未生效" >&2; exit 1
}
echo "    ai_chat.cpp n_gpu_layers=99 patch 已应用"

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
  -DGGML_LLAMAFILE=OFF \
  -DGGML_OPENCL=ON \
  -DGGML_OPENCL_EMBED_KERNELS=ON \
  -DGGML_OPENCL_USE_ADRENO_KERNELS=ON

echo "==> [3/4] 编译（${NJOBS} 线程）"
cmake --build "$BUILD_DIR" --config Release -j"$NJOBS"

echo "==> [4/4] 收集产物 + strip"
STRIP="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
test -x "$STRIP" || { echo "FATAL: llvm-strip 未找到: $STRIP" >&2; exit 1; }

mkdir -p "$OUT_DIR/engine"
# 需要的 .so：ai-chat / llama / llama-common / ggml / ggml-base / ggml-cpu（静态注册）
# + ggml-opencl（OpenCL GPU 后端独立共享库，BUILD_SHARED_LIBS=ON 下生成）。
# 排除：server/cli/bench 等（LLAMA_BUILD_APP=OFF 本应不产生，防御性剔除）、rpc/sycl
find "$BUILD_DIR" -name '*.so' \( -name '*rpc*' -o -name '*sycl*' -o -name '*server*' \
  -o -name '*-cli*' -o -name '*bench*' -o -name '*impl*' -o -name '*mtmd*' \) -delete

FOUND=0
while IFS= read -r -d '' so; do
  base="$(basename "$so")"
  case "$base" in
    libai-chat.so|libllama.so|libllama-common.so|libggml-base.so|libggml.so|libggml-cpu.so|libggml-opencl.so)
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

# libOpenCL.so（OpenCL ICD loader）：libggml-opencl.so 链接它（NEEDED），必须随包。
# 真机通过 manifest <uses-native-library android:name="libOpenCL.so" ...> 加载系统
# vendor 驱动；此处打包自编译的 ICD loader（与 llama.rn scripts/build-opencl.sh 一致）。
"$STRIP" --strip-debug --strip-unneeded -o "$OUT_DIR/engine/libOpenCL.so" "$OPENCL_BUILD/libOpenCL.so"
echo "    strip -> libOpenCL.so ($(du -h "$OUT_DIR/engine/libOpenCL.so" | cut -f1))"

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