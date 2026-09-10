/* Can a non-CAP user install a 2nd-level trap handler pointer? (no trap triggered) */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/kfd_ioctl.h>
#define GPU_ID 46235
int main(void){
  int kfd=open("/dev/kfd",O_RDWR), drm=open("/dev/dri/renderD128",O_RDWR);
  struct kfd_ioctl_acquire_vm_args aq={.drm_fd=(uint32_t)drm,.gpu_id=GPU_ID};
  if(ioctl(kfd,AMDKFD_IOC_ACQUIRE_VM,&aq)){perror("ACQUIRE_VM");return 1;}
  printf("ACQUIRE_VM ok (cwsr_kaddr now set -> SET_TRAP_HANDLER writes 2nd-level slot)\n");
  /* try to install an arbitrary 2nd-level TBA pointer */
  struct kfd_ioctl_set_trap_handler_args a; memset(&a,0,sizeof a);
  a.gpu_id=GPU_ID; a.tba_addr=0x123456789000ULL; a.tma_addr=0xdeadbeef000ULL;
  int r=ioctl(kfd,AMDKFD_IOC_SET_TRAP_HANDLER,&a);
  printf("SET_TRAP_HANDLER(tba=0x%llx) -> %s%s\n",(unsigned long long)a.tba_addr,
         r==0?"*** ACCEPTED (no CAP) ***":"failed ", r==0?"":strerror(errno));
  return 0;
}
