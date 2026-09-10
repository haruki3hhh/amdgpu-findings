	s_getreg_b32   ttmp2, hwreg(HW_REG_STATUS)
	s_getreg_b32   ttmp3, hwreg(HW_REG_HW_ID)
	s_store_dwordx2 ttmp[2:3], ttmp[14:15], 0x0 glc
	s_getreg_b32   ttmp4, hwreg(HW_REG_MODE)
	s_mov_b32      ttmp5, 0x600dc0de
	s_store_dwordx2 ttmp[4:5], ttmp[14:15], 0x8 glc
	s_dcache_wb
	s_waitcnt      lgkmcnt(0)
	s_add_u32      ttmp0, ttmp0, 4
	s_addc_u32     ttmp1, ttmp1, 0
	s_and_b32      ttmp1, ttmp1, 0xffff
	s_lshr_b32     ttmp5, ttmp12, 3
	s_setreg_b32   hwreg(HW_REG_STATUS, 3, 29), ttmp5
	s_nop          2
	s_setreg_b32   hwreg(HW_REG_STATUS, 0, 1), ttmp12
	s_rfe_b64      ttmp[0:1]
