#include <hip/hip_runtime.h>
#include <cstdio>
#include <unistd.h>
__global__ void spin(float*o,long n){ float a=1.0f+threadIdx.x; for(long i=0;i<n;i++) a=a*1.0000001f+1e-7f; if(threadIdx.x==0)o[blockIdx.x]=a; }
int main(int argc,char**argv){ long it=argc>1?atol(argv[1]):300000000L; float*d; hipMalloc(&d,4096*4);
  hipStream_t s; hipStreamCreate(&s);
  hipLaunchKernelGGL(spin,dim3(512),dim3(256),0,s,d,it);
  fprintf(stderr,"[spinv %d] running\n",getpid());
  hipStreamSynchronize(s); return 0; }
