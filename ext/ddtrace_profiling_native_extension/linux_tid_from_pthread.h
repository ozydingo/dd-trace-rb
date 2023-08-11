#pragma once
#include <pthread.h>

// The profiler reports the tid (thread id) for a thread since that allows us to match up Ruby threads with what is seen
// by external tools, like your favorite task manager or the datadog native profiler.
//
// Before Ruby 3.1, the Ruby VM did not record the tid for threads when they were created, only the `pthread_t`.
// The Linux libc folks never wanted to expose a way to go from a `pthread_t` to a `pid_t`, but... it's possible.
// The `linux_tid_from_pthread.c` file implements a hack to get this information.
//
// When not on Linux, `linux_tid_from_pthread.c` provides fallback versions of the methods below that always return -1.

// Returns the offset parameter needed by `linux_tid_from` or -1 if something went wrong/info not available
short setup_linux_tid_from_pthread_offset(void);

// Returns the tid for the given thread. If something went wrong/info is not available, -1 is returned.
pid_t linux_tid_from(pthread_t thread, short offset);