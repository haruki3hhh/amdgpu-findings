#include <hip/hip_runtime.h>
#include <cstdio>
__global__ void probe(unsigned *o){
  unsigned mode=0,status=0,trapsts=0,hwid=0,t4=0,ibsts=0;
  asm volatile("s_getreg_b32 %0, hwreg(HW_REG_MODE)"    : "=s"(mode));
  asm volatile("s_getreg_b32 %0, hwreg(HW_REG_STATUS)"  : "=s"(status));
  asm volatile("s_getreg_b32 %0, hwreg(HW_REG_TRAPSTS)" : "=s"(trapsts));
  asm volatile("s_getreg_b32 %0, hwreg(HW_REG_HW_ID)"   : "=s"(hwid));
  asm volatile("s_getreg_b32 %0, hwreg(HW_REG_IB_STS)"  : "=s"(ibsts));
  asm volatile("s_mov_b32 %0, ttmp4"                    : "=s"(t4));
  if(threadIdx.x==0 && blockIdx.x==0){
    o[0]=mode; o[1]=status; o[2]=trapsts; o[3]=hwid; o[4]=ibsts; o[5]=t4;
  }
}
int main(){
  unsigned *d,h[8]={0}; hipMalloc(&d,8*4); hipMemset(d,0,8*4);
  hipLaunchKernelGGL(probe,dim3(1),dim3(64),0,0,d);
  hipError_t e=hipDeviceSynchronize();
  printf("launch/sync: %s\n", hipGetErrorString(e));
  hipMemcpy(h,d,8*4,hipMemcpyDeviceToHost);
  printf("MODE   =0x%08x\n",h[0]);
  printf("STATUS =0x%08x\n",h[1]);
  printf("TRAPSTS=0x%08x\n",h[2]);
  printf("HW_ID  =0x%08x\n",h[3]);
  printf("IB_STS =0x%08x\n",h[4]);
  printf("ttmp4  =0x%08x\n",h[5]);
  return 0;
}
