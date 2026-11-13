#!/usr/bin/env python3
"""轻量架构守卫（审查门禁）。

检查项：
1. PipeWeaver/addons/pcg_shared 必须是符号链接，且与根工程 addons/pcg_shared
   解析到同一真实目录（共享模块单一真实源）。
2. 回流扫描：共享模块之外的 .gd 源码禁止重新实现已抽取到 addons/pcg_shared
   的函数（mesh boxes/mesh/add_quad/triangle_count、surface math 内核、
   JSON list/envelope）。按签名级特征匹配：签名不同的同名 helper
   （如 transition_mesh_builder 的索引版 _add_quad、fused_wall 的委托适配层）
   不算回流。

失败打印 ARCH_FAIL 明细并以非零退出码结束。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHARED_LINK = os.path.join(ROOT, "PipeWeaver", "addons", "pcg_shared")
SHARED_REAL = os.path.join(ROOT, "addons", "pcg_shared")

# 不参与扫描的目录（缓存、产物、文档与一次性 spike 副本）。
SKIP_DIRS = {".git", ".godot", "reports", "spike", "docs"}

# (说明, 正则)：共享模块之外禁止出现的函数定义（签名级特征）。
FORBIDDEN = [
    ("mesh boxes 回流", r"\bfunc\s+_boxes\s*\("),
    ("mesh 顶点封包回流", r"\bfunc\s+_mesh\s*\("),
    ("mesh 三角计数回流", r"\bfunc\s+_triangle_count\s*\("),
    ("mesh add_quad 回流", r"\bfunc\s+_add_quad\s*\([^\n)]*\bquad_uvs\b"),
    ("surface math surface_transform 回流", r"\bfunc\s+surface_transform\s*\(\s*surface_kind\b"),
    ("surface math surface_distance 回流", r"\bfunc\s+surface_distance\s*\(\s*surface_kind\b"),
    ("surface math clamp_anchor 回流", r"\bfunc\s+clamp_anchor\s*\(\s*surface_kind\b"),
    ("surface math raycast 回流", r"\bfunc\s+raycast\s*\(\s*surface_kind\b"),
    ("surface math _radial_basis 回流", r"\bfunc\s+_radial_basis\s*\("),
    ("surface math _ray_cylinder 回流", r"\bfunc\s+_ray_cylinder\s*\("),
    ("surface math _ray_dome 回流", r"\bfunc\s+_ray_dome\s*\("),
    ("JSON list_documents 回流", r"\bfunc\s+list_documents\s*\("),
    ("JSON parse_envelope 回流", r"\bfunc\s+parse_envelope\s*\("),
]


def check_link() -> list:
    if not os.path.islink(SHARED_LINK):
        return ["PipeWeaver/addons/pcg_shared 不是符号链接（共享模块必须保持单一链接源）"]
    if not os.path.isdir(SHARED_LINK):
        return ["PipeWeaver/addons/pcg_shared 是链接但目标不存在"]
    link_real = os.path.realpath(SHARED_LINK)
    addon_real = os.path.realpath(SHARED_REAL)
    if link_real != addon_real:
        return ["PipeWeaver/addons/pcg_shared 指向 %s，与根工程 addons/pcg_shared（%s）不一致"
                % (link_real, addon_real)]
    print("ARCH_OK: PipeWeaver/addons/pcg_shared -> %s（与根工程同一真实目录）" % link_real)
    return []


def scan_backflow() -> list:
    shared_real = os.path.realpath(SHARED_REAL)
    failures = []
    scanned = 0
    for dirpath, dirnames, filenames in os.walk(ROOT, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        if os.path.realpath(dirpath) == shared_real:
            dirnames[:] = []
            continue
        for name in sorted(filenames):
            if not name.endswith(".gd"):
                continue
            path = os.path.join(dirpath, name)
            try:
                with open(path, encoding="utf-8") as handle:
                    text = handle.read()
            except (OSError, UnicodeDecodeError):
                continue
            scanned += 1
            for label, pattern in FORBIDDEN:
                match = re.search(pattern, text)
                if match:
                    line = text.count("\n", 0, match.start()) + 1
                    failures.append("%s:%d %s" % (os.path.relpath(path, ROOT), line, label))
    if not failures:
        print("ARCH_OK: 回流扫描完成，%d 个 .gd 文件无已抽取函数回流" % scanned)
    return failures


def main() -> int:
    failures = check_link() + scan_backflow()
    if failures:
        for failure in failures:
            print("ARCH_FAIL: %s" % failure)
        print("ARCH_FAIL: %d 项架构检查未通过" % len(failures))
        return 1
    print("ARCH_PASS: 链接一致性与回流扫描全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
