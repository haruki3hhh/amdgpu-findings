/* Locate the CWSR hwreg block in the save area and read the saved STATUS.
 * Signature (gfx9 order): M0, PC_lo, PC_hi, EXEC_lo, EXEC_hi, STATUS, TRAPSTS, ...
 * For a full wave64 block EXEC = 0xFFFFFFFF_FFFFFFFF. */
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
extern "C" {
#include <linux/kfd_ioctl.h>
}
struct QI{uint32_t qid;uint64_t cwsr;uint32_t size,ctl;};
static QI g[32]; static int gn=0;
static int (*rio)(int,unsigned long,...);
extern "C" int ioctl(int fd,unsigned long req,...){
  va_list ap;va_start(ap,req);void*a=va_arg(ap,void*);va_end(ap);
  if(!rio) rio=(int(*)(int,unsigned long,...))dlsym(RTLD_NEXT,"ioctl");
  int r=rio(fd,req,a);
  if(req==AMDKFD_IOC_CREATE_QUEUE&&r==0&&gn<32){
    auto*q=(struct kfd_ioctl_create_queue_args*)a;
    g[gn++]={q->queue_id,q->ctx_save_restore_address,q->ctx_save_restore_size,q->ctl_stack_size};
  }
  return r;
}
__global__ void spin(float*o,long n){float a=1.f+threadIdx.x;for(long i=0;i<n;i++)a=a*1.0000001f+1e-7f;if(threadIdx.x==0)o[blockIdx.x]=a;}

static void scan(const char*tag){
  for(int i=0;i<gn;i++){
    volatile uint32_t*b=(volatile uint32_t*)g[i].cwsr; if(!b) continue;
    size_t start=g[i].ctl/4, end=g[i].size/4;
    int found=0;
    for(size_t k=start;k+8<end && found<2;k++){
      if(b[k]==0xFFFFFFFFu && b[k+1]==0xFFFFFFFFu){
        uint32_t st=b[k+2];
        if(st==0||st==0xFFFFFFFFu) continue;
        uint32_t spi=(st>>1)&3, ecc=(st>>17)&1, halt=(st>>13)&1, priv=(st>>18)&1, trapen=(st>>6)&1;
        printf("  [%s q%u] block@+0x%08zx\n",tag,g[i].qid,(size_t)(k-3)*4);
        const char* nm[12]={"M0","PC_lo","PC_hi","EXEC_lo","EXEC_hi","STATUS",
                            "TRAPSTS","XNACK_LO","XNACK_HI","MODE","?+0x28","?+0x2c"};
        for(int j=0;j<12;j++)
          printf("            +0x%02x %-9s = 0x%08x\n",j*4,nm[j],b[k-3+j]);
        printf("            STATUS decode: SPI_PRIO=%u ECC_ERR=%u HALT=%u PRIV=%u TRAP_EN=%u\n",
               spi,ecc,halt,priv,trapen);
        found++;
      }
    }
    if(!found) printf("  [%s q%u] no hwreg-block signature found\n",tag,g[i].qid);
  }
}
int main(int argc,char**argv){
  long iters = argc>1?atol(argv[1]):200000000L;
  float*d; hipMalloc(&d,4096*sizeof(float));
  hipStream_t s; hipStreamCreate(&s);
  printf("== before launch ==\n"); scan("pre");
  hipLaunchKernelGGL(spin,dim3(512),dim3(256),0,s,d,iters);
  for(int t=0;t<6;t++){ sleep(2); printf("== t=%d ==\n",t*2); scan("run"); }
  hipStreamSynchronize(s);
  printf("== after ==\n"); scan("post");
  return 0;
}
