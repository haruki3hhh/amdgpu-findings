/* Generalized CWSR forge + readback harness.
 * Hunts hwreg blocks in the CWSR save area (via concurrent oversubscription),
 * patches a chosen field with (val,mask), and the kernel reads back its own
 * MODE/STATUS/TRAPSTS/IB_STS each iteration, accumulating OR/AND + distinct set,
 * so we see which forged bits actually survived the restore into hardware.  */
#define _GNU_SOURCE
#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <unistd.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <sys/ioctl.h>
#include <pthread.h>
extern "C" { 
#include <linux/kfd_ioctl.h>
}
struct QI{uint32_t qid;uint64_t cwsr;uint32_t size,ctl;};
static QI g[64]; static int gn=0;
static int (*rio)(int,unsigned long,...);
static volatile int run=1; static volatile long patched=0, blocks=0;
/* field offset within a hwreg block (bytes) and patch value/mask */
static uint32_t FOFF=0x24; static uint32_t FVAL=0, FMASK=0;

extern "C" int ioctl(int fd,unsigned long req,...){
  va_list ap;va_start(ap,req);void*a=va_arg(ap,void*);va_end(ap);
  if(!rio) rio=(int(*)(int,unsigned long,...))dlsym(RTLD_NEXT,"ioctl");
  int r=rio(fd,req,a);
  if(req==AMDKFD_IOC_CREATE_QUEUE&&r==0&&gn<64){
    auto*q=(struct kfd_ioctl_create_queue_args*)a;
    g[gn++]={q->queue_id,q->ctx_save_restore_address,q->ctx_save_restore_size,q->ctl_stack_size};
  }
  return r;
}
/* hunter: find hwreg blocks, patch FOFF field */
static void*hunt(void*){
  while(run){
    for(int i=0;i<gn;i++){
      volatile uint32_t*b=(volatile uint32_t*)g[i].cwsr; if(!b) continue;
      size_t start=g[i].ctl/4, end=start+(6u<<20)/4;
      for(size_t k=start;k+16<end;k++){
        if(b[k+3]==0xFFFFFFFFu && b[k+4]==0xFFFFFFFFu){   /* EXEC_lo/hi at +0x0c/+0x10 => block base = k-3 */
          uint32_t st=b[k+5];                              /* STATUS at +0x14 */
          if(st==0||st==0xFFFFFFFFu) continue;
          uint32_t mode=b[k+9];                            /* MODE at +0x24 */
          if((mode&~0xFFFu)!=0x000u && (mode&0xF0)!=0xF0) continue; /* sanity: looks like MODE */
          blocks++;
          if(FMASK){ volatile uint32_t*t=&b[k+FOFF/4]; *t=((*t)&~FMASK)|(FVAL&FMASK); patched++; }
        }
      }
    }
  }
  return NULL;
}
__global__ void work(unsigned long long iters, unsigned *out){
  /* per-wave local OR/AND, merged globally at exit so ANY forged read shows up */
  unsigned mo_or=0,mo_and=~0u, st_or=0,st_and=~0u, tr_or=0,tr_and=~0u, ib_or=0,ib_and=~0u;
  float acc=1.0f+threadIdx.x;
  for(unsigned long long i=0;i<iters;i++){
    unsigned mode,status,trapsts,ibsts;
    asm volatile("s_getreg_b32 %0, hwreg(HW_REG_MODE)"    :"=s"(mode));
    asm volatile("s_getreg_b32 %0, hwreg(HW_REG_STATUS)"  :"=s"(status));
    asm volatile("s_getreg_b32 %0, hwreg(HW_REG_TRAPSTS)" :"=s"(trapsts));
    asm volatile("s_getreg_b32 %0, hwreg(HW_REG_IB_STS)"  :"=s"(ibsts));
    mo_or|=mode; mo_and&=mode; st_or|=status; st_and&=status;
    tr_or|=trapsts; tr_and&=trapsts; ib_or|=ibsts; ib_and&=ibsts;
    acc=acc*1.0000001f+1e-7f;
  }
  if((threadIdx.x&63)==0){        /* one lane per wave */
    atomicOr(&out[0],mo_or);  atomicAnd(&out[1],mo_and);
    atomicOr(&out[2],st_or);  atomicAnd(&out[3],st_and);
    atomicOr(&out[4],tr_or);  atomicAnd(&out[5],tr_and);
    atomicOr(&out[6],ib_or);  atomicAnd(&out[7],ib_and);
    atomicAdd(&out[8],1u);
  }
  if(threadIdx.x==0&&blockIdx.x==0) out[31]=__float_as_uint(acc);
}
int main(int argc,char**argv){
  const char*field = argc>1?argv[1]:"mode";
  FVAL = argc>2? strtoul(argv[2],0,16):0;
  FMASK= argc>3? strtoul(argv[3],0,16):0;
  unsigned long long iters = argc>4? strtoull(argv[4],0,10):150000000ULL;
  if(!strcmp(field,"status"))  FOFF=0x14;
  else if(!strcmp(field,"trapsts")) FOFF=0x18;
  else if(!strcmp(field,"mode")) FOFF=0x24;
  else if(!strcmp(field,"ibsts")) FOFF=0x14; /* not in block; handled elsewhere - unused */
  unsigned *d; hipMalloc(&d,64*4);
  { unsigned init[64]; for(int j=0;j<64;j++) init[j]=(j==1||j==3||j==5||j==7)?0xffffffffu:0u; hipMemcpy(d,init,64*4,hipMemcpyHostToDevice); }
  pthread_t th; pthread_create(&th,NULL,hunt,NULL);
  hipLaunchKernelGGL(work,dim3(512),dim3(256),0,0,iters,d);
  hipError_t e=hipDeviceSynchronize();
  run=0; pthread_join(th,NULL);
  unsigned h[64]; hipMemcpy(h,d,64*4,hipMemcpyDeviceToHost);
  printf("field=%s off=0x%02x val=0x%08x mask=0x%08x | sync=%s blocks=%ld patched=%ld\n",
         field,FOFF,FVAL,FMASK,hipGetErrorString(e),blocks,patched);
  printf("  MODE    OR=0x%08x AND=0x%08x\n",h[0],h[1]);
  printf("  STATUS  OR=0x%08x AND=0x%08x\n",h[2],h[3]);
  printf("  TRAPSTS OR=0x%08x AND=0x%08x\n",h[4],h[5]);
  printf("  IB_STS  OR=0x%08x AND=0x%08x\n",h[6],h[7]);
  printf("  waves sampled=%u\n",h[8]);
  return 0;
}
