#include "ReelStackSample.h"
#include <mach/mach.h>
#include <mach/thread_status.h>

#if defined(__arm64__)
static uintptr_t strip(uint64_t v) { return (uintptr_t)(v & 0x0000007FFFFFFFFFull); }

int reel_sample_thread(thread_t thread, uintptr_t *out, int capacity) {
    if (capacity < 2 || out == NULL) return -1;
    if (thread_suspend(thread) != KERN_SUCCESS) return -1;
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    int n = 0;
    if (kr == KERN_SUCCESS) {
        out[n++] = strip(state.__pc);
        out[n++] = strip(state.__lr);
        uintptr_t fp = strip(state.__fp);
        uint64_t pair[2];
        while (n < capacity) {
            if (fp <= 0x1000 || (fp & 0xF) != 0) break;
            vm_size_t outsize = 0;
            if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, 16, (vm_address_t)pair, &outsize) != KERN_SUCCESS || outsize != 16) break;
            uintptr_t next = strip(pair[0]), ret = strip(pair[1]);
            if (ret <= 0x1000) break;
            out[n++] = ret;
            if (next <= fp) break;   /* stacks grow down: the caller's frame is higher */
            fp = next;
        }
    }
    thread_resume(thread);
    return kr == KERN_SUCCESS ? n : -1;
}
#else
int reel_sample_thread(thread_t thread, uintptr_t *out, int capacity) { (void)thread; (void)out; (void)capacity; return -1; }
#endif
