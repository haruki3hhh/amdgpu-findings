#define _GNU_SOURCE
#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cerrno>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <pthread.h>
extern "C" { 
#include <linux/kfd_ioctl.h>
}
#define GPU_ID 46235
static int kfd=-1, drm=-1;
static const uint32_t HANDLER[] = {
 0xb8eef802,0xb8eff804,0xc0471bbd,0x00000000,0xb8f0f801,0xbef100ff,0x600dc0de,0xc0471c3d,
 0x00000008,0xc0840000,0x00000000,0xbf8cc07f,0x806c846c,0x826d806d,0x866dff6d,0x0000ffff,
 0x8f718378,0xb971e0c2,0xbf800002,0xb9780002,0xbe801f6c };
static int find_fd(const char*w){DIR*d=opendir("/proc/self/fd");struct dirent*e;char b[256],l[256];int r=-1;
 while((e=readdir(d))){snprintf(b,sizeof b,"/proc/self/fd/%s",e->d_name);ssize_t n=readlink(b,l,sizeof l-1);
 if(n<=0)continue;l[n]=0; if(!strcmp(l,w)){r=atoi(e->d_name);break;}} closedir(d);return r;}
static int alloc_mem(uint64_t va,uint64_t sz,uint32_t fl,uint64_t*h,uint64_t*mo){
 struct kfd_ioctl_alloc_memory_of_gpu_args a;memset(&a,0,sizeof a);a.va_addr=va;a.size=sz;a.gpu_id=GPU_ID;a.flags=fl;
 int r=ioctl(kfd,AMDKFD_IOC_ALLOC_MEMORY_OF_GPU,&a);if(!r){if(h)*h=a.handle;if(mo)*mo=a.mmap_offset;}return r;}
static int map_mem(uint64_t h){uint32_t d=GPU_ID;struct kfd_ioctl_map_memory_to_gpu_args m;memset(&m,0,sizeof m);
 m.handle=h;m.device_ids_array_ptr=(uintptr_t)&d;m.n_devices=1;return ioctl(kfd,AMDKFD_IOC_MAP_MEMORY_TO_GPU,&m)==0?(int)m.n_success:-1;}

// kernel: announce running, wait for host release, then s_trap, then done-flag
__global__ void trigger(volatile unsigned *sync){
  if(threadIdx.x==0) sync[0]=0xBB;                       // running
  while(sync[1]==0){ }                                    // wait for host release
  asm volatile("s_trap 1");
  if(threadIdx.x==0) sync[2]=0xA5;                        // resumed after trap
}
int main(){
  setvbuf(stdout,NULL,_IONBF,0);
  int *warm; hipMalloc(&warm,4096);
  kfd=find_fd("/dev/kfd"); drm=find_fd("/dev/dri/renderD128");
  printf("kfd=%d drm=%d\n",kfd,drm); if(kfd<0||drm<0)return 1;

  // coherent pinned buffers: sync (host<->kernel), res (handler writes, host reads)
  volatile unsigned *sync; hipHostMalloc((void**)&sync, 64, hipHostMallocCoherent);
  volatile unsigned *res;  hipHostMalloc((void**)&res, 64, hipHostMallocCoherent);
  sync[0]=sync[1]=sync[2]=0; for(int i=0;i<16;i++) res[i]=0;
  void *sync_dev=0,*res_dev=0;
  hipHostGetDevicePointer(&sync_dev,(void*)sync,0);
  hipHostGetDevicePointer(&res_dev,(void*)res,0);
  printf("res_dev=%p (handler will store here via tma_addr)\n",res_dev);

  // handler BO: executable, in HIP's VM (raw alloc on ROCr's kfd fd)
  const uint64_t HVA=0x420000000000ULL; uint64_t hh,hoff;
  if(alloc_mem(HVA,4096,KFD_IOC_ALLOC_MEM_FLAGS_VRAM|KFD_IOC_ALLOC_MEM_FLAGS_PUBLIC|
      KFD_IOC_ALLOC_MEM_FLAGS_EXECUTABLE|KFD_IOC_ALLOC_MEM_FLAGS_WRITABLE|
      KFD_IOC_ALLOC_MEM_FLAGS_NO_SUBSTITUTE,&hh,&hoff)){printf("halloc %s\n",strerror(errno));return 1;}
  volatile uint32_t*hc=(volatile uint32_t*)mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_SHARED,drm,(off_t)hoff);
  if(hc==MAP_FAILED){printf("hmmap %s\n",strerror(errno));return 1;}
  for(unsigned i=0;i<sizeof(HANDLER)/4;i++) hc[i]=HANDLER[i]; (void)hc[0];
  if(map_mem(hh)<=0){printf("hmap %s\n",strerror(errno));return 1;}

  struct kfd_ioctl_set_trap_handler_args t; memset(&t,0,sizeof t);
  t.gpu_id=GPU_ID; t.tba_addr=HVA; t.tma_addr=(uint64_t)res_dev;   // 2nd-level TMA -> result buffer
  printf("handler ready @0x%llx, tma->res\n",(unsigned long long)HVA);

  // launch async; kernel will park until we release
  hipLaunchKernelGGL(trigger,dim3(1),dim3(1),0,0,sync);
  // wait for kernel to be running
  for(int i=0;i<100000 && sync[0]!=0xBB;i++) usleep(100);
  printf("kernel running=%s\n", sync[0]==0xBB?"yes":"NO");
  // install our 2nd-level handler NOW (kernel parked, past ROCr launch setup)
  for(int i=0;i<20;i++) if(ioctl(kfd,AMDKFD_IOC_SET_TRAP_HANDLER,&t)){printf("settrap %s\n",strerror(errno));break;}
  printf("installed handler; releasing kernel to hit s_trap\n");
  sync[1]=1;   // release -> kernel does s_trap
  // poll result buffer for the handler's marker (survives even if wave hangs)
  int ran=0;
  for(int i=0;i<3000;i++){ if(res[3]==0x600dc0de){ran=1;break;} usleep(1000); }
  printf("\n=== result (read from coherent buffer) ===\n");
  printf("  marker = 0x%08x %s\n",res[3], ran?"*** HANDLER RAN ***":"(not seen within 3s)");
  if(ran){
    unsigned st=res[0], hwid=res[1], mode=res[2];
    printf("  STATUS = 0x%08x  PRIV(b5)=%u TRAP_EN(b6)=%u\n",st,(st>>5)&1,(st>>6)&1);
    printf("  HW_ID  = 0x%08x\n",hwid);
    printf("  MODE   = 0x%08x\n",mode);
    if((st>>5)&1) printf("\n*** 2nd-level trap handler EXECUTED at PRIV=1 ***\n");
    else          printf("\n(handler ran but PRIV bit=%u)\n",(st>>5)&1);
  }
  printf("kernel resumed flag=0x%x\n", sync[2]);
  return ran?0:2;
}
