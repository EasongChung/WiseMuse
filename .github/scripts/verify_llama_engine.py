#!/usr/bin/env python3
# v0.1.0 ｜ llama.android 引擎 .so 门禁校验（打到产物本身）
#
# 复用历史项目 G4 血泪教训：「日志绿」≠「二进制对」。CI 校验必须解析 ELF 实体：
#   1. 架构 = aarch64 (ELFMACHINE 183) / 64 位（ELFDATA 64 位）
#   2. libai-chat.so 导出 JNI 符号（dynsym）—— Java_com_arm_aichat_internal_* 全命中
#   3. 关键库下落：libllama / libllama-common / ggml 家族必须齐备
#   4. 任何 .so 不得依赖 libc++_shared.so（避免 App 额外声明 / 加载顺序坑）
#
# 用法：python3 verify_llama_engine.py <engine_dir>（engine 目录内含 *.so）

import glob
import os
import struct
import sys

# ELF 常量
ELFCLASS64 = 2
EM_AARCH64 = 183
DT_NEEDED = 1
PT_DYNAMIC = 2

EXPECTED_JNI = [
    "Java_com_arm_aichat_internal_InferenceEngineImpl_init",
    "Java_com_arm_aichat_internal_InferenceEngineImpl_load",
    "Java_com_arm_aichat_internal_InferenceEngineImpl_prepare",
    "Java_com_arm_aichat_internal_InferenceEngineImpl_systemInfo",
    "Java_com_arm_aichat_internal_InferenceEngineImpl_benchModel",
    "Java_com_arm_aichat_internal_InferenceEngineImpl_processSystemPrompt",
    "Java_com_arm_aichat_internal_InferenceEngineImpl_processUserPrompt",
    "Java_com_arm_aichat_internal_InferenceEngineImpl_generateNextToken",
    "Java_com_arm_aichat_internal_InferenceEngineImpl_unload",
    "Java_com_arm_aichat_internal_InferenceEngineImpl_shutdown",
]

def read_cstr(data, off):
    end = data.find(b"\x00", off)
    return data[off:end].decode("utf-8", "replace") if end != -1 else ""

def parse_elf(path):
    """返回 {machine, elfclass, dynsyms:set, needed:set}"""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise ValueError(f"非 ELF 文件: {path}")
    ei_class = data[4]                      # EI_CLASS
    ei_data = data[5]                       # EI_DATA: 1=LSB, 2=MSB
    endian = "<" if ei_data == 1 else ">"
    if ei_class != ELFCLASS64:
        raise ValueError(f"{path}: 非 64 位 ELF (EI_CLASS={ei_class})")
    machine = struct.unpack_from(endian + "H", data, 18)[0]
    e_shoff = struct.unpack_from(endian + "Q", data, 40)[0]
    e_shentsize = struct.unpack_from(endian + "H", data, 58)[0]
    e_shnum = struct.unpack_from(endian + "H", data, 60)[0]
    e_shstrndx = struct.unpack_from(endian + "H", data, 62)[0]
    if e_shoff == 0 or e_shnum == 0:
        raise ValueError(f"{path}: 无 section header")

    # section 名表
    shstr_hdr = e_shoff + e_shstrndx * e_shentsize
    shstr_off = struct.unpack_from(endian + "Q", data, shstr_hdr + 24)[0]
    shstr_size = struct.unpack_from(endian + "Q", data, shstr_hdr + 32)[0]
    shstr = data[shstr_off:shstr_off + shstr_size]

    symbols = set()
    needed = set()
    for i in range(e_shnum):
        sh = e_shoff + i * e_shentsize
        sh_name = struct.unpack_from(endian + "I", data, sh)[0]
        sh_type = struct.unpack_from(endian + "I", data, sh + 4)[0]
        sh_offset = struct.unpack_from(endian + "Q", data, sh + 24)[0]
        sh_size = struct.unpack_from(endian + "Q", data, sh + 32)[0]
        sh_link = struct.unpack_from(endian + "I", data, sh + 40)[0]
        sh_entsize = struct.unpack_from(endian + "Q", data, sh + 56)[0]
        name = read_cstr(shstr, sh_name)

        if name == ".dynsym" and sh_size and sh_entsize:
            # 需要 .dynstr（sh_link 指向它）
            str_hdr = e_shoff + sh_link * e_shentsize
            str_off = struct.unpack_from(endian + "Q", data, str_hdr + 24)[0]
            str_size = struct.unpack_from(endian + "Q", data, str_hdr + 32)[0]
            strtab = data[str_off:str_off + str_size]
            for off in range(sh_offset, sh_offset + sh_size, sh_entsize):
                st_name = struct.unpack_from(endian + "I", data, off)[0]
                if st_name:
                    symbols.add(read_cstr(strtab, st_name))
        elif name == ".dynamic" and sh_size:
            # 解析 DT_NEEDED（需 .dynstr：sh_link）
            str_hdr = e_shoff + sh_link * e_shentsize
            str_off = struct.unpack_from(endian + "Q", data, str_hdr + 24)[0]
            str_size = struct.unpack_from(endian + "Q", data, str_hdr + 32)[0]
            strtab = data[str_off:str_off + str_size]
            for off in range(sh_offset, sh_offset + sh_size, 16):
                d_tag = struct.unpack_from(endian + "q", data, off)[0]
                d_val = struct.unpack_from(endian + "Q", data, off + 8)[0]
                if d_tag == DT_NEEDED:
                    needed.add(read_cstr(strtab, d_val))
                elif d_tag == 0:  # DT_NULL
                    break

    return {"machine": machine, "elfclass": ei_class, "dynsyms": symbols, "needed": needed}

def main():
    if len(sys.argv) < 2:
        print("用法: python3 verify_llama_engine.py <engine_dir>")
        sys.exit(2)
    engine_dir = sys.argv[1]
    sos = sorted(glob.glob(os.path.join(engine_dir, "*.so")))
    if not sos:
        print(f"FAIL: {engine_dir} 下没有任何 .so")
        sys.exit(1)

    print(f"校验 {len(sos)} 个 .so：")
    ai_chat = os.path.join(engine_dir, "libai-chat.so")
    base_names = {os.path.basename(p) for p in sos}
    # 系统库（Android 运行时就绪，无需随包）：libc/libm/libdl/liblog/libandroid
    # 其余 NEEDED 必须在本包内闭环（如 libomp.so 曾被漏收 → dlopen 失败）
    SYSTEM_LIBS = {"libc.so", "libm.so", "libdl.so", "liblog.so", "libandroid.so"}
    all_syms = set()
    missing_necessary = []
    missing_deps = set()
    for p in sos:
        try:
            info = parse_elf(p)
        except ValueError as e:
            print(f"  FAIL {os.path.basename(p)}: {e}")
            sys.exit(1)
        base = os.path.basename(p)
        if info["machine"] != EM_AARCH64:
            missing_necessary.append(f"{base}: machine={info['machine']}（非 aarch64）")
        all_syms |= info["dynsyms"]
        # NEEDED 闭环：非系统库依赖必须都在本包内
        for dep in info["needed"]:
            if dep in SYSTEM_LIBS:
                continue
            if dep not in base_names:
                missing_deps.add(f"{base} -> {dep}（包内缺失）")
        # 每个 .so 的 NEEDED 里不允许 libc++_shared
        if "libc++_shared.so" in info["needed"]:
            print(f"  FAIL {base}: 依赖 libc++_shared.so（必须全静态链）")
            sys.exit(1)
        print(f"  OK  {base}  (machine={info['machine']} needed={sorted(info['needed'])})")

    if missing_deps:
        for d in sorted(missing_deps):
            print(f"  FAIL 依赖闭环: {d}")
        sys.exit(1)

    # libai-chat.so 必须存在且 JNI 符号齐全
    if not os.path.exists(ai_chat):
        print("FAIL: 缺少 libai-chat.so（JNI 壳）"); sys.exit(1)
    ai_info = parse_elf(ai_chat)
    for sym in EXPECTED_JNI:
        if sym not in ai_info["dynsyms"]:
            print(f"FAIL: libai-chat.so 缺少 JNI 符号 {sym}")
            sys.exit(1)
    print("  OK  libai-chat.so JNI 导出符号 10/10")

    # 关键库必须齐备
    necessary = {"libllama.so", "libllama-common.so", "libggml.so", "libggml-base.so"}
    for n in sorted(necessary):
        if n not in base_names:
            missing_necessary.append(f"缺少 {n}")

    # CPU 后端布局校验（GGML_BACKED_DL=OFF 静态注册方案）：
    #   - 必须存在 libggml-cpu.so（非 GGML_CPU_ALL_VARIANTS 的单一 CPU 后端载体）
    #   - 必须导出 CPU 后端注册/接口符号（ggml_backend_cpu_reg 或 ggml_cpu_init），
    #     否则运行时 ggml_backend_reg_count()==0 → llama_model_load_from_file 秒返
    #     nullptr（真机曾整个引擎 Release 全部变体缺符号导致任何模型都加载失败）
    CPU_EXPORTS_REQUIRED = {"ggml_backend_cpu_reg", "ggml_cpu_init"}
    cpu_lib = "libggml-cpu.so"
    if cpu_lib not in base_names:
        missing_necessary.append(f"缺少 {cpu_lib}（CPU 后端静态注册载体）")
    else:
        cpu_info = parse_elf(os.path.join(engine_dir, cpu_lib))
        cpu_hits = CPU_EXPORTS_REQUIRED & cpu_info["dynsyms"]
        print(f"  OK  {cpu_lib} CPU 后端导出: {sorted(cpu_hits) or '（空）'}")
        if not cpu_hits:
            missing_necessary.append(f"{cpu_lib} 无 CPU 后端导出符号（静态注册未生效）")

    # OpenCL GPU 后端布局校验（GGML_OPENCL=ON，Adreno 加速）：
    #   - 必须存在 libggml-opencl.so（OpenCL 后端独立共享库）
    #   - 必须导出 ggml_backend_opencl_reg（否则运行时 register_backend 无效，
    #     n_gpu_layers 设了也全回落 CPU，等于没加速）
    #   - 必须存在 libOpenCL.so（ICD loader，libggml-opencl.so 的 NEEDED 依赖；
    #     已在依赖闭环处校验，此处显式确认在包内）
    opencl_lib = "libggml-opencl.so"
    if "libggml-opencl.so" not in base_names:
        missing_necessary.append("缺少 libggml-opencl.so（OpenCL GPU 后端）")
    else:
        opencl_info = parse_elf(os.path.join(engine_dir, opencl_lib))
        opencl_hits = {"ggml_backend_opencl_reg"} & opencl_info["dynsyms"]
        print(f"  OK  {opencl_lib} OpenCL 后端导出: {sorted(opencl_hits) or '（空）'}")
        if not opencl_hits:
            missing_necessary.append(f"{opencl_lib} 无 ggml_backend_opencl_reg 导出（静态注册未生效）")
    if "libOpenCL.so" not in base_names:
        missing_necessary.append("缺少 libOpenCL.so（OpenCL ICD loader 运行时依赖）")

    if missing_necessary:
        print("FAIL: " + "; ".join(missing_necessary)); sys.exit(1)

    print(f"PASS: 引擎门禁全绿（{len(sos)} 个 .so，CPU+OpenCL 后端已确认, 架构 aarch64/64 位）")
    sys.exit(0)

if __name__ == "__main__":
    main()