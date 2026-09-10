#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstring>
#include <unistd.h>
__global__ void spin(float*o,long n){ float a=1.0f+(float)threadIdx.x; for(long i=0;i<n;i++) a=a*1.0000001f+1e-7f; if(threadIdx.x==0)o[blockIdx.x]=a; }
int main(int argc,char**argv){
  long it=argc>1?atol(argv[1]):250000000L;
  float*d; hipMalloc(&d,512*4); hipMemset(d,0,512*4);
  hipStream_t s; hipStreamCreate(&s);
  hipLaunchKernelGGL(spin,dim3(512),dim3(256),0,s,d,it);
  hipStreamSynchronize(s);
  float h[512]; hipMemcpy(h,d,512*4,hipMemcpyDeviceToHost);
  unsigned seen[64]; int nd=0;
  for(int i=0;i<512;i++){ unsigned b; memcpy(&b,&h[i],4); int dup=0; for(int j=0;j<nd;j++) if(seen[j]==b)dup=1; if(!dup&&nd<64)seen[nd++]=b; }
  unsigned b0; memcpy(&b0,&h[0],4);
  printf("[det_victim %d] out[0]=0x%08x (%.7g) distinct=%d %s\n",getpid(),b0,h[0],nd,
         nd>1?"<== MY COMPUTE WAS CORRUPTED BY ANOTHER PROCESS":"(clean)");
  return 0;
}
