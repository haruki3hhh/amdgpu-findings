	s_mov_b32 ttmp4, 0
	s_setreg_b32 hwreg(6,0,8), ttmp4
	s_mov_b32 exec_lo, 1
	s_mov_b32 exec_hi, 0
	v_mov_b32 v0, 0
	ds_read_b32 v1, v0 offset:0
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 0 glc
	ds_read_b32 v1, v0 offset:2048
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 4 glc
	ds_read_b32 v1, v0 offset:4096
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 8 glc
	ds_read_b32 v1, v0 offset:6144
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 12 glc
	ds_read_b32 v1, v0 offset:8192
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 16 glc
	ds_read_b32 v1, v0 offset:10240
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 20 glc
	ds_read_b32 v1, v0 offset:12288
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 24 glc
	ds_read_b32 v1, v0 offset:14336
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 28 glc
	ds_read_b32 v1, v0 offset:16384
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 32 glc
	ds_read_b32 v1, v0 offset:18432
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 36 glc
	ds_read_b32 v1, v0 offset:20480
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 40 glc
	ds_read_b32 v1, v0 offset:22528
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 44 glc
	ds_read_b32 v1, v0 offset:24576
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 48 glc
	ds_read_b32 v1, v0 offset:26624
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 52 glc
	ds_read_b32 v1, v0 offset:28672
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 56 glc
	ds_read_b32 v1, v0 offset:30720
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 60 glc
	ds_read_b32 v1, v0 offset:32768
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 64 glc
	ds_read_b32 v1, v0 offset:34816
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 68 glc
	ds_read_b32 v1, v0 offset:36864
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 72 glc
	ds_read_b32 v1, v0 offset:38912
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 76 glc
	ds_read_b32 v1, v0 offset:40960
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 80 glc
	ds_read_b32 v1, v0 offset:43008
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 84 glc
	ds_read_b32 v1, v0 offset:45056
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 88 glc
	ds_read_b32 v1, v0 offset:47104
	s_waitcnt lgkmcnt(0)
	v_readlane_b32 ttmp2, v1, 0
	s_store_dword ttmp2, ttmp[14:15], 92 glc
	s_mov_b32 ttmp2, 0x600dc0de
	s_store_dword ttmp2, ttmp[14:15], 96 glc
	s_dcache_wb
	s_waitcnt lgkmcnt(0)
	s_add_u32 ttmp0, ttmp0, 4
	s_addc_u32 ttmp1, ttmp1, 0
	s_and_b32 ttmp1, ttmp1, 0xffff
	s_lshr_b32 ttmp5, ttmp12, 3
	s_setreg_b32 hwreg(HW_REG_STATUS, 3, 29), ttmp5
	s_nop 2
	s_setreg_b32 hwreg(HW_REG_STATUS, 0, 1), ttmp12
	s_rfe_b64 ttmp[0:1]
