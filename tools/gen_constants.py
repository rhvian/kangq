"""从 poseidon2_ref.py 的解析结果生成 src/constants.cuh（设备错位表 + 主机原始表）。

动机：Poseidon2 的轮常量有 22+12+4*12+4*12 = 130 个数，手抄必然出错。
这里直接从已对拍 10/10 的解析结果导出，保证 GPU / 主机两侧与参考实现同源。
用法：python tools/gen_constants.py
"""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import poseidon2_ref as R  # noqa: E402

CUDA_OUT = HERE.parent / "src" / "constants.cuh"


def gen_cuda() -> str:
    def c_arr(name: str, values: list[int], storage: str) -> str:
        body = ",\n    ".join(f"0x{v:016x}ULL" for v in values)
        return f"{storage} uint64_t {name}[{len(values)}] = {{\n    {body}\n}};\n"

    def c_2d(name: str, rows: list[list[int]], storage: str) -> str:
        parts = []
        for row in rows:
            inner = ", ".join(f"0x{v:016x}ULL" for v in row)
            parts.append(f"    {{{inner}}}")
        return (f"{storage} uint64_t {name}[{len(rows)}][{len(rows[0])}] = {{\n"
                + ",\n".join(parts) + "\n};\n")

    dev = "__device__ __constant__"
    host = "static const"
    # 设备端用"错位"表：外部线性层顺带加**下一轮**的常量，于是
    #   RC_INITIAL_EXT[r+1] 在第 r 个初始轮的线性层里加；RC_INITIAL_EXT[4] = [第 0 个内部常量, 0...]
    #   RC_INTERNAL_EXT[r+1] 在第 r 个内部轮里加；末尾补 0
    #   RC_TERMINAL_EXT[0] 单独加；RC_TERMINAL_EXT[r+1] 在第 r 个终止轮的线性层里加；末行全 0
    init_ext = R.C["init"] + [[R.C["internal"][0]] + [0] * 11]
    internal_ext = R.C["internal"] + [0]
    term_ext = R.C["term"] + [[0] * 12]

    return (
        "// Poseidon2/Goldilocks 轮常量（CUDA 版）。\n"
        "// 由 tools/gen_constants.py 从 tools/poseidon2_ref.py 生成，请勿手工编辑。\n"
        "//\n"
        "// *_EXT 是设备端的错位表（线性层顺带加下一轮常量），H_* 是主机端精确实现用的原始表。\n"
        "#pragma once\n"
        "#include <cstdint>\n\n"
        + c_arr("MATRIX_DIAG", R.C["diag"], dev)
        + "\n"
        + c_2d("RC_INITIAL_EXT", init_ext, dev)
        + "\n"
        + c_arr("RC_INTERNAL_EXT", internal_ext, dev)
        + "\n"
        + c_2d("RC_TERMINAL_EXT", term_ext, dev)
        + "\n"
        + c_arr("H_MATRIX_DIAG", R.C["diag"], host)
        + "\n"
        + c_arr("H_INTERNAL_RC", R.C["internal"], host)
        + "\n"
        + c_2d("H_INITIAL_RC", R.C["init"], host)
        + "\n"
        + c_2d("H_TERMINAL_RC", R.C["term"], host)
    )


def main() -> int:
    assert len(R.C["internal"]) == 22, len(R.C["internal"])
    assert len(R.C["diag"]) == 12, len(R.C["diag"])
    assert len(R.C["init"]) == 4, len(R.C["init"])
    assert len(R.C["term"]) == 4, len(R.C["term"])

    CUDA_OUT.parent.mkdir(parents=True, exist_ok=True)
    cuda = gen_cuda()
    CUDA_OUT.write_text(cuda, encoding="utf-8")
    print(f"wrote {CUDA_OUT} ({len(cuda)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
