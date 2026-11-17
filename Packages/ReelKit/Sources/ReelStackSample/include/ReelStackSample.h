#ifndef REEL_STACK_SAMPLE_H
#define REEL_STACK_SAMPLE_H
#include <mach/mach.h>
#include <stdint.h>

/// Suspends `thread`, copies its pc, lr and then the return address of every frame up the frame
/// pointer chain into `out` (at most `capacity`), and resumes it. Pure C: between the suspend and the
/// resume nothing may take a lock the suspended thread could hold, and the Swift runtime takes its
/// metadata lock inside generic code (a Debug build's `withUnsafeMutablePointer` on a tuple did,
/// and the main thread, suspended inside `swift_getGenericMetadata`, held it: the whole app froze,
/// 16 and 17 Nov 2026). Returns the number of addresses written, or -1 when the thread could not be
/// suspended or its state read. Pointer authentication bits are stripped.
int reel_sample_thread(thread_t thread, uintptr_t *out, int capacity);

#endif
