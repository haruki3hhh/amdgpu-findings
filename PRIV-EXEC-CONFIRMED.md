# gfx942 上确认:非特权用户经 SET_TRAP_HANDLER 获得 PRIV=1 GPU 代码执行

**日期**:2026-09-10 **环境**:MI300X VF(gfx942),ROCm DKMS amdgpu 6.16.13,uid 1000,无 CAP_*
**状态**:**实机确认**(此前分析判定 gfx942 无法拿 PRIV;本测试推翻该结论)

## 结论

非特权用户可用无 CAP 的 `AMDKFD_IOC_SET_TRAP_HANDLER` 把二级 trap handler 指向自己的一段 shader gadget;
该 gadget 在一次 `s_trap` 后**以 PRIV=1 执行**,并能干净返回。实测寄存器:

```
marker = 0x600dc0de           (gadget 执行)
STATUS = 0x80010061           PRIV(bit5)=1  TRAP_EN(bit6)=1     <-- 特权态确认
HW_ID  = 0x403028a0
kernel resumed flag=0xa5      (gadget 经 s_rfe 干净返回,主 shader 继续)
```

PRIV=1 下读到的特权寄存器(非特权 shader 读不到):
```
SQ_SHADER_TBA / SQ_SHADER_TMA (内核 CWSR handler 地址)、GPR_ALLOC、LDS_ALLOC、IB_STS
```
gadget 返回路径里的 `s_setreg hwreg(HW_REG_STATUS,...)` 本身就是一次特权写(PRIV=0 下无效),
干净返回即证明特权写成功。⇒ **item 3(一批特权 hwreg 读/写)确认。**

## 关键实现要点(排错记录)

1. **ABI**:二级 handler 入口 ttmp0/1=返回 PC,ttmp12=STATUS,ttmp2/3/4/5 空闲,ttmp14/15=我设的 tma_addr(用作结果缓冲指针)。返回 = 恢复 STATUS(set_status_without_spi_prio 从 ttmp12)+ `s_and ttmp1,0xffff` + `s_rfe [ttmp0,ttmp1]`。
2. **PC 前进**:s_trap 的返回 PC 指向 s_trap 本身,必须 `+4`(s_add_u32 ttmp0,4 / s_addc_u32 ttmp1,0)否则 s_rfe 回到 s_trap 无限重陷 → 挂死。
3. **与 ROCr 抢 tma[0]**:ROCr 在每次 kernel 启动时重设 trap handler。必须在 kernel **已经运行**后再 SET_TRAP_HANDLER。用 coherent pinned 内存做 host↔kernel 握手:kernel 置 running 标志并自旋等待 host,host 见到 running 后装 handler 再释放 kernel → s_trap。否则 s_trap 在我 set 之前触发 → 走 ROCr 的 handler(结果全 0)。
4. **结果回读**:结果写进 coherent pinned 缓冲(tma_addr 指向它),host 轮询,即使 wave 挂死也能读到已写入的证据。

## PoC
- `code/priv_test_confirmed.hip` — 完整 PoC(找 ROCr 的 kfd/drm fd → 在其 VM 里分配 EXECUTABLE handler BO → 写入 gadget → SET_TRAP_HANDLER → coherent 握手 → s_trap → 回读)
- `code/h.s` / `code/hd.s` — 二级 handler 汇编(h.s=最小 PRIV 证明;hd.s=批量特权 hwreg dump),`llvm-mc -mcpu=gfx942`

## 意义
- gfx942 上拿 PRIV=1 的途径 = 无 CAP 的 SET_TRAP_HANDLER(不需要 F14、不需要 CWSR 伪造)。
- 与 gfx11 对比:gfx11(GC 11.0.0-11.0.3)抢占后自动 PRIV=1;gfx942 需这条 SET_TRAP_HANDLER 路径。两者殊途同归。
- 剩余待测(纯硬件行为,风险高):PRIV=1 下 (1) 重编 LDS_ALLOC 跨 workgroup 读 LDS;(2) s_sendmsg HALT_WAVES/STALL 跨 SE 停摆。PRIV 使能已确认,这两项的跨上下文效果需 CU-mask 强制同 CU 共驻(LDS)/整卡 halt 恢复(sendmsg)。

---

## 三项跨上下文测试的实机结果(2026-09-10 续)

拿到 PRIV=1 载体后,实测原 F10 三项:

### item 3 — 特权 hwreg 读/写:✅ 确认
PRIV=1 handler 读到 `SQ_SHADER_TBA/TMA`(内核 CWSR handler 地址)、`GPR_ALLOC`、`LDS_ALLOC`;
其返回路径的 `s_setreg STATUS` 与 LDS_BASE 重编都是特权写且生效。

### item 1 — LDS_ALLOC 重编 → 跨 workgroup 读 LDS:❌ 未成功(本方法/本机)
- PRIV=1 handler 成功 `s_setreg hwreg(LDS_ALLOC).LDS_BASE=0` 并 `ds_read` —— 但**只读到自己 WG 的 LDS**(offset 0 = 0xA11A…,自己的数据)。
- 用 1-CU mask(`hipExtStreamCreateWithCUMask`)+ 7 个 victim WG 填满 CU,handler 扫 0..0xB800 的 CU LDS:
  除自己 offset 0 外**全为 0**,没读到任何 victim 的 0x5EC0… 图样。
- 结论:重编 LDS_BASE 后 `ds_read` **未能越过本 wave 自己的 LDS 分配**去读其它 workgroup 的 LDS。
  两种可能(本机无法进一步区分):(a) 即便 PRIV=1,`ds_read` 仍被限制在本 wave 的 LDS 分配内;
  (b) MI300 多 XCC 下 CU-mask 未能把 victim 与 attacker 强制放到**同一块物理 CU**(victim 在别的 CU,故其 LDS 不在 attacker 的 CU LDS 里,读出 0)。
- **所以"通过 LDS_ALLOC 做真正的跨 context 读"在 gfx942 上本次未复现**(重要的负面/存疑结果)。

### item 2 — s_sendmsg HALT_WAVES / STALL_WAVE_GEN:未执行(安全考量)
- 需要在 PRIV=1 halt 全部 wave;无可靠的 un-halt/resume 路径时会 wedge 整个 GPU,SR-IOV VF 上需 host 复位。
- 与整卡复位同风险级,未在共享测试机执行。PRIV 使能已确认,该消息的跨 SE 效果留待可复位专用机。

### 结论修正
- **确认**:非 CAP → PRIV=1 任意 GPU 代码执行(gfx942);PRIV 下特权 hwreg 读/写。
- **未达成**:PRIV 本身**不自动**等于跨 context 读——LDS 跨 WG 读本次未复现(ds_read 似乎仍限于本 wave 分配,或 co-residency 未保证)。这与"PRIV 不改 VMID、跨 context 杀伤取决于具体共享资源能否被触及"的判断一致:LDS 这条至少在本机/本方法下没打通。
- 全程无 GPU reset;仅一次可恢复的 retry page fault(大 offset ds_read 命中未映射区)。
