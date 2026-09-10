# PC/EXEC 伪造能做什么 + 自己给自己拿 PRIV 的真正途径

**问题**:F10/F13 的"劫持 wave 控制流(伪造 PC/EXEC)"还能做什么?攻击者能不能改自己的 PC/EXEC 来利用?
**环境**:MI300X VF(gfx942),ROCm DKMS `amdgpu 6.16.13`,uid 1000,无 CAP_*。
**方法**:反汇编已发布 gfx942 trap handler + 读驱动源码 + 实测 ioctl 可达性。

---

## 0. 直接回答

**伪造自己的 PC/EXEC(经 CWSR)——没用。** 一个 compute shader 本来就在自己的 VMID 里以非特权任意执行代码;
把自己的 PC 重定向到自己地址空间里的某处,你本来就能直接把那段代码写进 shader。EXEC 掩码同理,自己随时能改。
而且 gfx942 的 CWSR 恢复以 `s_rfe` 结尾**清 PRIV**,伪造的 PC 落地时是非特权。所以自伤式 PC/EXEC 伪造不产生任何新能力。

**但"控制流劫持 → 特权执行"这条路真实存在,只是入口不是 CWSR PC 伪造,而是 trap handler 的二级指针。**
而且在 gfx942 上,拿到 PRIV=1 甚至不需要 F14 或 CWSR 伪造——一个**无 CAP 的 ioctl `SET_TRAP_HANDLER`** 就够了。

---

## 1. 为什么自伤 PC 伪造没用(已验证)

反汇编 gfx942 trap handler,一级 handler 到二级的唯一间接跳转(`cwsr_trap_handler_gfx9.asm` L353-431):

```asm
s_getreg_b32   ttmp14, hwreg(HW_REG_SQ_SHADER_TMA_LO)   ; TMA 来自硬件寄存器(内核设定)
s_getreg_b32   ttmp15, hwreg(HW_REG_SQ_SHADER_TMA_HI)
s_load_dwordx2 [ttmp2, ttmp3], [ttmp14, ttmp15], 0x0    ; 二级 TBA = *(TMA+0)
s_and_b64      [ttmp2, ttmp3], [ttmp2, ttmp3], ...
s_cbranch_scc0 L_NO_NEXT_TRAP                            ; *(TMA+0)==0 则跳过
s_setpc_b64    [ttmp2, ttmp3]                            ; 跳到二级 handler
```

跳转目标 `ttmp2/3` 来自 `*(TMA)`,`ttmp14/15` 被 `s_getreg TMA` 覆盖——**都不来自 CWSR 恢复的、用户可伪造的寄存器**。
所以伪造保存区里的 ttmp/PC 影响不了这个跳转。恢复路径本身又以 `s_rfe` 清 PRIV。⇒ 自伤 PC/EXEC 伪造无增益。

---

## 2. 真正的特权执行入口:`SET_TRAP_HANDLER`(无 CAP)

### 机制

`kfd_process_set_trap_handler()`(由 ioctl `AMDKFD_IOC_SET_TRAP_HANDLER`(0x13)调用,注册 **flags=0,无 CAP**):

```c
if (qpd->cwsr_kaddr) {                 /* CWSR 开启时(本机就是),恒成立 */
    uint64_t *tma = (uint64_t *)(qpd->cwsr_kaddr + KFD_CWSR_TMA_OFFSET);
    tma[0] = tba_addr;                 /* 用户传入的 args->tba_addr,零校验 */
    tma[1] = tma_addr;
}
```

- `tma[0]` 正是一级 handler `s_setpc` 的目标(§1)。
- `s_setpc` **不清 PRIV**(只有 `s_rfe` 清)。trap 进入时硬件置 PRIV=1,一级 handler 一路到 `s_setpc` 都没 `s_rfe`。
  ⇒ **二级 handler 在 PRIV=1 下运行。**
- s_trap 路径无 runtime_enable 门(`L_CHECK_TRAP_ID`:`s_save_pc_hi & TRAP_ID != 0` → `L_FETCH_2ND_TRAP`)。

### 已验证(实机,低风险)

```
ACQUIRE_VM ok (cwsr_kaddr 被置 -> SET_TRAP_HANDLER 会写二级槽)
SET_TRAP_HANDLER(tba=0x123456789000) -> *** ACCEPTED (无 CAP) ***
```

非特权用户成功把任意地址写进二级 TBA 槽。无任何校验(不检查地址是否落在保留区/只读区)。

### 完整利用形态(机制完备,危险步骤未执行)

```
1. ALLOC(EXECUTABLE) 一块 GPU 缓冲,写入攻击者的 shader gadget(二级 handler 代码)
2. SET_TRAP_HANDLER(tba_addr = 该 gadget)          -> tma[0] = gadget,无 CAP
3. 计算 shader 里执行 s_trap 1
4. 一级 handler -> L_FETCH_2ND_TRAP -> s_setpc gadget，此时 PRIV=1
5. gadget 在 PRIV=1 下运行于攻击者自己的 VMID
```

**这就是 gfx942 上"攻击者自己给自己拿到 PRIV=1 GPU 执行"的途径**——不需要 F14,不需要 CWSR 伪造,
一个无 CAP 的 ioctl + 一条 s_trap。

---

## 3. 拿到 PRIV=1 之后能做什么(取决于特权 hwreg 的跨上下文效果)

PRIV=1 在自己 VMID 内能 `s_setreg` 特权 hwreg、执行特权指令。原 findings 文档 F10 列的"最值得实测"项
正是这些,之前因"gfx942 拿不到 PRIV"被判不可达——现在有了载体:

- **`s_setreg(HW_REG_LDS_ALLOC)` → 跨 workgroup 读 LDS**:若可行,即同 CU 上读别的 workgroup 的 LDS —— **真正的跨 context 读**。
- **`s_sendmsg` MSG_HALT_WAVES / MSG_STALL_WAVE_GEN**:若 PRIV 可达,跨 SE 停摆 wave 生成(跨 context DoS)。
- 读/改一批特权 hwreg(HW_ID、TBA/TMA、SQ 配置、TRAPSTS 等)。

**这些的跨上下文效果是纯硬件行为,源码无法判定,需运行 PRIV handler 实测。** 我**没有执行**这一步:
写一个能正确返回的二级 trap handler 本身很精细,写错会让 wave/队列挂死;而在 SR-IOV VF 上,
特权 GPU 执行出错很可能需要 **host 侧介入复位**——与 ring-0 同一风险级别。机制已完备,属"能做但按需触发"。

> 重要区分:这是 AMD **设计内**的二级 trap handler 机制(ROCgdb 就靠它)。它的"安全性"完全押在
> "PRIV=1 只在自己 VMID 内、碰不到别的 context"这一假设上。而上面三项恰恰是在问这个假设成不成立。
> 若其中任一跨上下文有效,则这条无 CAP 路径就是一个真正的越权原语;若都不跨,则它是"受限的自我 PRIV"。
> **本机未验证跨上下文那一跳。**

---

## 4. 与 F10/F13/F12/F14 的关系

| 机制 | 拿 PRIV 的方式 | 本机可行性 |
|---|---|---|
| **F12(GFX11)** | CWSR 恢复走 `s_setpc` 保留 PRIV,伪造 PC → 特权 PC 执行 | 仅 GFX11(已反汇编确认 gfx11 blob 有该分支);gfx942 无 |
| **本文(gfx942)** | `SET_TRAP_HANDLER` 写二级 TBA → s_trap → PRIV=1 跳转 | ✅ 无 CAP,已验证 ioctl 可达 |
| F10/F13 CWSR STATUS.PRIV 伪造 | 直接伪造 PRIV 位 | ❌ 不生效(`s_rfe` 清,已实测) |
| F10/F13 PC/EXEC 自伤伪造 | — | ❌ 无增益(§1) |

**综合**:
- 拿 PRIV=1 执行:GFX11 用 F12(CWSR),gfx942 用 SET_TRAP_HANDLER。**PC 伪造只有在 PRIV 语境下才有杀伤**
  ——F12 里 PC 伪造 + 保留 PRIV = 特权任意 PC;gfx942 里 PRIV 来自 handler 指针,PC 由攻击者的 gadget 决定。
- F10/F13 在这条链里的角色是**辅助**:伪造 trap 前后状态、伪造别人的 wave 状态(配合 F14,见组合文档)。
- 若要跨 UID 改别人的二级 TBA 槽:`SET_TRAP_HANDLER` 只作用于**自己**进程;改别人的需 F14 写对方
  cwsr_kaddr 页(GTT/host,RO 但 F14 物理重映射可绕过)或 ptrace(同 UID)——即"配合其他机制"。

---

## 5. 定界与诚实说明

- **已确认**:SET_TRAP_HANDLER 无 CAP 可写任意二级 TBA(实机);一级 handler 在 PRIV=1 下 `s_setpc` 到它(反汇编+架构);s_trap 路径无 runtime_enable 门(反汇编)。
- **未执行**:实际的 PRIV=1 gadget 运行 + LDS_ALLOC/s_sendmsg 跨上下文测试(危险,VF 上出错需 host 复位)。
- **待定**:PRIV=1 是否真能跨 context(读别 workgroup LDS / 跨 SE 停摆)——纯硬件行为,是这条链是否构成真正越权的关键,需在可复位的专用机上测。
- **本质**:全程逻辑/架构层(ioctl 语义 + 架构 PRIV 语义),不涉及内存破坏。

---

## 6. 修复方向

- `SET_TRAP_HANDLER` 应校验 `tba_addr` 落在内核控制的、只读的 CWSR 保留区内(或仅允许 runtime/debug 已启用且经调试器路径设置),而非接受任意用户地址。
- 或:二级 handler 入口应由内核放置的可信 trampoline 固定,不让用户直接决定 PRIV 跳转目标。
- 根因层面:重新审视"PRIV=1 只在自己 VMID 内即安全"这一假设是否对 LDS/SE 级共享资源成立(即 F10 items 3/4)。

---

## 附:验证程序
- `settrap.c` — 实测 SET_TRAP_HANDLER 无 CAP 接受任意二级 TBA(scratchpad)
- 反汇编依据:`cwsr_trap_handler_gfx9.asm` L353-431(二级跳转)、`kfd_process.c` `kfd_process_set_trap_handler`、`kfd_chardev.c` `kfd_ioctl_set_trap_handler`(flags=0)

未执行 PRIV gadget,无 GPU reset,GPU 正常(rocminfo ok,VRAM 0.28 GB)。
