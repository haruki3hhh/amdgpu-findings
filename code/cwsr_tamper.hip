/* F10/F13 capstone: write to the CWSR save area between save and restore and
 * see whether the GPU honours it.  Target = MODE.FP_ROUND (benign, no RAS). */
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
static QI g[32]; static int gn=0;
static int (*rio)(int,unsigned long,...);
static volatile int g_run=1; static volatile long g_patch=0, g_seen=0;
static int g_mode=0;   /* 0=baseline observe, 1=tamper */

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
__global__ void spin(float*o,long n){
  float a=1.0f+(float)threadIdx.x;
  for(long i=0;i<n;i++) a=a*1.0000001f+1e-7f;
  if(threadIdx.x==0) o[blockIdx.x]=a;
}
/* Hunt for hwreg blocks and rewrite MODE.FP_ROUND -> 3 (round toward zero). */
static void*hunter(void*){
  while(g_run){
    for(int i=0;i<gn;i++){
      volatile uint32_t*b=(volatile uint32_t*)g[i].cwsr; if(!b) continue;
      size_t start=g[i].ctl/4, end=start+(4u<<20)/4;   /* 4MB window */
      for(size_t k=start;k+8<end;k++){
        if(b[k]==0xFFFFFFFFu&&b[k+1]==0xFFFFFFFFu){
          uint32_t st=b[k+2], mode=b[k+6];
          if(st==0||st==0xFFFFFFFFu) continue;
          if((mode&~0xFu)!=0x3f0u) continue;          /* expected MODE shape */
          g_seen++;
          if(g_mode){ b[k+6]=(mode&~0x3u)|0x3u; g_patch++; }  /* FP_ROUND=RTZ */
        }
      }
    }
  }
  return NULL;
}
int main(int argc,char**argv){
  g_mode = (argc>1 && !strcmp(argv[1],"tamper"));
  long iters = argc>2?atol(argv[2]):120000000L;
  float*d; hipMalloc(&d,4096*sizeof(float));
  hipMemset(d,0,4096*sizeof(float));
  hipStream_t s; hipStreamCreate(&s);
  hipLaunchKernelGGL(spin,dim3(512),dim3(256),0,s,d,iters);
  pthread_t th; pthread_create(&th,NULL,hunter,NULL);
  hipStreamSynchronize(s);
  g_run=0; pthread_join(th,NULL);
  float h[512]; hipMemcpy(h,d,sizeof h,hipMemcpyDeviceToHost);
  /* count distinct results across the 512 blocks */
  int distinct=0; uint32_t seen[64]; 
  for(int i=0;i<512;i++){ uint32_t bits; memcpy(&bits,&h[i],4);
    int dup=0; for(int j=0;j<distinct;j++) if(seen[j]==bits) dup=1;
    if(!dup&&distinct<64) seen[distinct++]=bits; }
  uint32_t b0; memcpy(&b0,&h[0],4);
  printf("%-9s blocks_seen=%-7ld patched=%-7ld out[0]=0x%08x (%.9g) distinct_results=%d\n",
         g_mode?"TAMPER":"BASELINE",g_seen,g_patch,b0,h[0],distinct);
  if(distinct>1){ printf("           values:"); for(int j=0;j<distinct&&j<8;j++){float f;memcpy(&f,&seen[j],4);printf(" 0x%08x(%.7g)",seen[j],f);} printf("\n"); }
  return 0;
}
