# amdgpu / amdkfd — trap-handler PRIV 与 CWSR 利用分析

MI300X VF(gfx942)、ROCm DKMS `amdgpu 6.16.13`、运行内核 `6.8.0-124-generic` 上,针对
`drivers/gpu/drm/amd/{amdgpu,amdkfd}` 的实机安全分析。攻击者模型:uid 1000,`render`+`video` 组,
**无任何 CAP_\***。全部结论区分"已实机验证 / 部分验证 / 未执行(危险步骤)"。

---

## 核心结论(本目录聚焦)

**攻击者自己伪造 PC/EXEC 没用;但一个无 CAP 的 `SET_TRAP_HANDLER` ioctl 能让二级 trap handler 指向
攻击者代码,并在 `PRIV=1` 下运行。** 这是 gfx942 上"自己给自己拿到特权 GPU 执行"的途径——不需要 F14、
不需要 CWSR 伪造。拿到 PRIV=1 之后能否跨 context(读别 workgroup 的 LDS、跨 SE 停摆)是关键未知,
属危险步骤,未在此 VF 上执行。

---

## 文档

| 文件 | 内容 | 主要证据等级 |
|---|---|---|
| **`amdgpu-kfd-trap-handler-priv.md`** | **本目录主文档**。自伤 PC/EXEC 伪造为何无用;`SET_TRAP_HANDLER`(无 CAP)→ 二级 TBA → PRIV=1 执行的机制与利用形态 | ioctl 可达性已实测;PRIV gadget 执行未做 |
| `amdgpu-kfd-F10-F13-exploitation.md` | F10/F13(CWSR 保存区寄存器伪造)单独利用面:故障合成、调试器伪造、MODE 篡改;PRIV 伪造的负面结果 | 实机(伪造+回读) |
| `amdgpu-kfd-F10-F13-combinations.md` | F10/F13 配合 F14 / 调试 API:跨租户 wave 状态控制(触及+写入已证,执行影响受竞态限制) | 实机(触及+写入) |
| `amdgpu-kfd-gfx11-priv.md` | **gfx11 分析**:GC 11.0.0–11.0.3 上 `trap_en=0` + SW_SA_TRAP → CWSR 抢占后**默认**保留 PRIV=1;自伤伪造 PC/STATUS 由此变可利用。比 gfx942 更严重 | blob+源码(无 gfx11 硬件) |

> 关联但不在本目录的更广材料(可按需补入):`amdgpu-kfd-F14-*.md`(USERPTR→DOORBELL 跨租户显存原语
> 及页表改写)、`amdgpu-kfd-findings-VERIFICATION.md`(原始 13 条 finding 的实机验证)。

---

## 代码(`code/`)

| 文件 | 对应 | 说明 |
|---|---|---|
| `settrap.c` | **trap-handler-priv** | 实测无 CAP `SET_TRAP_HANDLER` 接受任意二级 TBA 地址(不触发 trap,低风险) |
| `rdprobe.hip` | F10/F13 | 回读工具能力探测:非特权 kernel 经内联汇编读 MODE/STATUS/TRAPSTS/HW_ID/IB_STS/ttmp |
| `cwsr_forge.hip` | F10/F13 | 通用伪造+回读框架(参数 field/val/mask;hunter 拍保存区 + 全局 OR/AND 回读) |
| `forge_run.sh` | F10/F13 | 并发超额订阅运行器(触发 CWSR 轮转) |
| `cwsr_tamper.hip` | F10/F13 | 早期 MODE.FP_ROUND 端到端篡改(结果 1081104→~37585) |
| `cwsr_dump.hip` | F10/F13 | 保存区 hwreg 块定位/解析(确认 STATUS/MODE 布局) |
| `f14_cwsr_scan.hip` | 组合(F14×F10/F13) | F14 窗口扫描**别租户**的 CWSR 块(证明触及,扫到 3072 块) |
| `f14_cwsr_forge.hip` / `f14_cwsr_forge2.hip` | 组合 | 经 F14 改写别租户 CWSR MODE(证明写入,落 1024 次;连续版尝试打竞态) |
| `det_victim.hip` | 组合 | 确定性计算受害者(报告 distinct,基线=1) |
| `spinv.hip` | 组合 | 长自旋计算 victim(制造超额订阅) |

## 证据(`evidence/`)

| 文件 | 说明 |
|---|---|
| `gfx9_4_3.dis` | 已发布 gfx942 CWSR/trap handler blob(`cwsr_trap_gfx9_4_3_hex`)反汇编。二级跳转 `s_setpc [*(TMA)]`(PRIV=1)、STATUS/MODE/TRAPSTS 恢复自保存区等结论的直接依据 |
| `gfx11.dis` | 已发布 gfx11 blob(`cwsr_trap_gfx11_hex`)反汇编。675-678 行 = TRAP_EN 分支 + `s_setpc` 保留 PRIV=1;`amdgpu-kfd-gfx11-priv.md` 的直接依据 |

---

## 编译 / 运行

```sh
# 内联汇编回读 / trap handler ioctl（C）
gcc -O0 -I/usr/src/amdgpu-6.16.13-2341068.24.04/include/uapi -o settrap code/settrap.c

# HIP kernels
hipcc -O2 --offload-arch=gfx942 -I/usr/src/amdgpu-6.16.13-2341068.24.04/include/uapi \
      -o cwsr_forge code/cwsr_forge.hip -ldl -lpthread
```

gpu_id(46235)、CWSR 保存区偏移等常量见各源文件顶部。反汇编:
`llvm-mc -arch=amdgcn -mcpu=gfx942 -disassemble`(见 evidence/ 生成说明)。

---

## 状态与边界

- **已实机验证**:`SET_TRAP_HANDLER` 无 CAP 接受任意二级 TBA;F10/F13 各寄存器伪造+回读;
  F14 触及并写入别租户 CWSR 块;MODE.FP_ROUND 端到端篡改。
- **部分验证**:F14→受害者 CWSR 执行影响(写入落地,执行影响受 save↔restore 竞态/一致性限制,未稳定复现)。
- **未执行(危险)**:PRIV=1 gadget 的实际运行 + LDS_ALLOC/s_sendmsg 跨上下文测试;ECC_ERR 整卡复位。
  原因:SR-IOV VF 上特权 GPU 执行/复位出错需 host 侧介入,与 ring-0 同风险级别。
- 全部测试过程无 GPU reset、无内核 oops。
- **修复方向**:`SET_TRAP_HANDLER` 校验 `tba_addr` 落在内核控制的只读 CWSR 保留区;F10/F13 在恢复路径重新净化;
  F14 补 USERPTR→DOORBELL 尺寸/归属校验。详见各文档。
