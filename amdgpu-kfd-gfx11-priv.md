# gfx11 上的可利用性:PRIV=1 是 CWSR 抢占后的默认状态

**问题**:F10/F13/trap-handler 那套在 gfx11 上还能利用吗?
**结论**:能,而且 **PRIV 这条线比 gfx942 更严重**——在 GC 11.0.0–11.0.3 上,普通计算队列被 CWSR 抢占一次后
**默认**就在 PRIV=1 下恢复运行,不需要 debugger、不需要 `SET_TRAP_HANDLER`、不需要伪造。
**方法**:已发布 gfx11 CWSR blob 反汇编(`cwsr_trap_gfx11_hex`)+ 驱动源码版本门控。**无 gfx11 硬件**
(本机 MI300X=gfx942),故为 blob+源码分析,非实机;跨 context 的 PRIV 收益那一跳需 gfx11 实机验证。

---

## 1. 核心机制(已在 shipped blob 确认)

### (a) 驱动给 gfx11 队列设 `trap_en = 0`

`kfd_device_queue_manager.c:267`:
```c
queue_input.trap_en = !kfd_dbg_has_cwsr_workaround(q->device);
```
`kfd_debug.h`:
```c
static inline bool kfd_dbg_has_cwsr_workaround(struct kfd_node *dev) {
    return KFD_GC_VERSION(dev) >= IP_VERSION(11, 0, 0) &&
           KFD_GC_VERSION(dev) <= IP_VERSION(11, 0, 3);
}
```
⇒ **GC 11.0.0–11.0.3(Navi31/32/33 = RX 7600/7700/7800/7900,及部分 Phoenix APU)上 `trap_en = 0`。**

### (b) SW_SA_TRAP 恢复路径:TRAP_EN=0 → 保留 PRIV=1(shipped gfx11 blob,反汇编 675-678 行)

```asm
s_bitcmp1_b32 ttmp2, 6                        ; 测 STATUS.TRAP_EN (bit6)
                                              ; TRAP_EN==0 → 落到下面两条:
s_setreg_b32  hwreg(HW_REG_STATUS), ttmp14    ; STATUS 全字,来自用户可写保存区
s_setpc_b64   ttmp[0:1]                        ; 跳到保存的 PC —— 保留 PRIV=1(不是 s_rfe)
                                              ; TRAP_EN==1 → 下面是 s_rfe(清 PRIV,正常返回)
s_setreg_b32  hwreg(HW_REG_STATUS), ttmp14
s_rfe_b64     ttmp[0:1]
```

`ttmp14 = s_restore_status`、`ttmp[0:1] = s_restore_pc`,都由 `read_hwreg_from_mem` 从用户保存区读入。
源码对应 `cwsr_trap_handler_gfx10.asm`(SW_SA_TRAP == CHIP_PLUM_BONITO,即全部 gfx11)第 1253-1267 行,
注释原文:*"If traps are enabled then return to the shader with PRIV=0. Otherwise retain PRIV=1 for
subsequent context save requests."*

### (c) shader 主体确实跑在 PRIV=1 —— 驱动自证

`cwsr_trap_handler_gfx10.asm:1176`:
> `// s_barrier with MODE.DEBUG_EN=1, STATUS.PRIV=1 incorrectly asserts debug exception.`
> `// Clear DEBUG_EN before and restore MODE after the barrier.`

AMD 专门为"wave 以 STATUS.PRIV=1 跑到 s_barrier 会误触发 debug 异常"这个硬件 bug 打了 workaround——
反证了 gfx11 上 wave 抢占后**以 PRIV=1 运行普通 shader**是常态。

**合起来**:GC 11.0.0–11.0.3 普通计算队列(`trap_en=0`)被 CWSR 抢占一次 → 恢复走 `s_setpc` 保留 PRIV=1
→ **用户的普通 shader 在 PRIV=1 下继续执行**。这是"cwsr workaround"的既定行为,非罕见状态。

---

## 2. 相对 gfx942 的两处翻转

### 翻转一:"自己伪造 PC/EXEC 没用" → 在 gfx11 变"有用"

- gfx942:恢复以 `s_rfe` 清 PRIV,伪造自己保存的 PC 落地是非特权 → 无增益(你本来就有非特权任意执行)。
- gfx11(TRAP_EN=0):恢复以 `s_setpc` **保留 PRIV**,且 **PC 与 STATUS 全字来自用户可写保存区**
  → **伪造自己保存的 PC = 在攻击者选定地址以 PRIV=1 执行**。这正是"attacker 改自己的 PC 实现利用"在 gfx11 成立。

### 翻转二:拿 PRIV 的门槛从 SET_TRAP_HANDLER 降到零

- gfx942:要靠无 CAP 的 `SET_TRAP_HANDLER` 装二级 handler 才到 PRIV=1(见 `amdgpu-kfd-trap-handler-priv.md`)。
- gfx11(11.0.0–11.0.3):抢占一次自动 PRIV=1。攻击者流程:
  1. 写一个含特权指令的 compute shader(`s_setreg` 特权 hwreg / `s_sendmsg` / 读写特权寄存器);
  2. 超额订阅制造 CWSR 抢占(与 gfx942 上验证过的手法相同);
  3. 抢占恢复后 wave 处于 PRIV=1,特权指令生效(shader 可先试一条特权读自检已 PRIV,再动手)。

---

## 3. 其余各面在 gfx11 的适用性

| 面 | gfx11 情况 |
|---|---|
| **F11 SPI_PRIO** | gfx11 STATUS 全字恢复、不屏蔽 SPI_PRIO → 跨 context 抢占 SIMD 发射优先级,成立 |
| **F10/F13 假故障合成 / MODE 篡改** | 同一"CWSR restore 从用户内存加载不净化"模式;STATUS 全字,可伪造位更多 |
| **SET_TRAP_HANDLER → 二级 handler PRIV=1** | arch 无关,gfx11 也有;但 11.0.0–11.0.3 不需要它(自动 PRIV) |
| **F14 USERPTR→DOORBELL(跨租户显存 + 页表改写)** | ioctl 层 arch 无关;消费卡 BAR 布局/CWSR 区位置细节需实机 |

---

## 4. 拿到 PRIV=1 之后 —— 同一个未决硬件问题,但 gfx11 唾手可得

PRIV=1 本身**不改 VMID**(不直接跨租户读内存)。真正的跨 context 杀伤仍取决于特权操作能否碰 CU/SE 级
**共享**资源:
- `s_setreg(HW_REG_LDS_ALLOC)` → 跨 workgroup 读 LDS(真正的跨 context 读)
- `s_sendmsg MSG_HALT_WAVES / MSG_STALL_WAVE_GEN` → 跨 SE 停摆 wave 生成

区别:gfx942 要先跨过"拿 PRIV"这道坎(SET_TRAP_HANDLER,风险大);gfx11(11.0.0–11.0.3)PRIV 是免费默认态,
这些测试的**前置条件自动满足**。这一跳是纯硬件行为,gfx942 上我未执行(风险等同 ring-0),gfx11 上更无硬件可测。

---

## 5. 覆盖面与定界

| 芯片 | trap_en | 抢占后 PRIV | 说明 |
|---|---|---|---|
| **GC 11.0.0–11.0.3** | 0 | **保留 PRIV=1(自动)** | Navi31/32/33 = RX 7600/7700/7800/7900,部分 Phoenix |
| GC 11.0.4+ / 11.5.x | 1 | s_rfe 清 PRIV(无自动) | SW_SA_TRAP 代码仍在 blob 内但不走;SET_TRAP_HANDLER 路径仍在 |
| gfx942(本机) | — | 无自动 PRIV | 需 SET_TRAP_HANDLER;CWSR STATUS.PRIV 伪造实测不生效 |

- **已确认**(blob+源码):`trap_en=0` 门控范围;shipped gfx11 blob 的 `s_setpc` 保留 PRIV 路径;barrier workaround 佐证 shader 跑 PRIV=1;STATUS/PC 全字来自用户保存区。
- **未验证**:无 gfx11 硬件——自动 PRIV=1 的架构机制已确认,但"PRIV=1 能否真的跨 context 读 LDS / 跨 SE 停摆"需 gfx11 实机。
- **本质**:架构 PRIV 语义 + 驱动版本门控,非内存破坏。

---

## 6. 修复方向

- 根因(F12):SW_SA_TRAP 的 PRIV 保留把"仅 trap handler 特权"扩大到"整个 shader 特权"。应重新评估
  `trap_en=0` + 保留 PRIV 的 cwsr workaround 是否可用不暴露特权 shader 的方式实现(需 AMD 明确这是设计还是疏忽)。
- F10/F13:恢复路径重新净化 STATUS/MODE(而非仅保存路径)。
- 重新审视"PRIV=1 只在自己 VMID 内即安全"这一假设对 LDS/SE 级共享资源是否成立。

---

## 附:证据
- `evidence/gfx11.dis` — 已发布 gfx11 blob(`cwsr_trap_gfx11_hex`,882 dwords)反汇编。675-678 行 = TRAP_EN 分支 + `s_setpc` 保留 PRIV。
- 提取/反汇编:从 `cwsr_trap_handler.h` 抽 `cwsr_trap_gfx11_hex[]` → `llvm-mc -arch=amdgcn -mcpu=gfx1100 -disassemble`。
- 源码依据:`kfd_device_queue_manager.c:267`(trap_en)、`kfd_debug.h` `kfd_dbg_has_cwsr_workaround`、`cwsr_trap_handler_gfx10.asm` L1176/L1253-1267。
