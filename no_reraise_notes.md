# no_reraise: / ignore_errno: — dropped, concerns

## no_reraise:

### M:N use-after-free

When a Ruby thread is killed via `Thread#kill` inside a `no_reraise: false` JIT function,
TAG_FATAL bypasses `rb_rescue2`, so `frame_pop` never runs. The native thread's
`rbffi_current_frame` is left pointing to a frame on the killed thread's C stack.

In M:N Ruby (≥3.3), native threads are pooled and reused — another Ruby thread picked up
by the same native thread would inherit this dangling pointer. Any FFI callback fired inside
a `no_reraise: true` JIT function on that thread (which pushes no frame of its own) would
call `save_callback_exception` against freed stack memory — use-after-free.

### Thread#kill is not dropped

`Thread#raise` uses TAG_RAISE and is caught and silently dropped by `rb_rescue2`.
`Thread#kill` uses TAG_FATAL which bypasses `rb_rescue2` entirely — the thread is always
terminated regardless of `no_reraise: true`. The semantics are inconsistent.

### Outer frame leaks

A `no_reraise: true` JIT function called from within a Ruby callback invoked by a
`no_reraise: false` JIT function provides no isolation — `rbffi_frame_current()` still
returns the outer frame, so callback exceptions from inside the inner function leak to the
outer frame and propagate through it.

## ignore_errno:

`FFI.errno` storage is `pthread_key_t`-based (`ThreadData` in FFI's `LastError.c`) —
native-thread-local, not Ruby-thread-local. In M:N Ruby, if the scheduler migrates the
Ruby thread to a different native thread between `rbffi_save_errno()` and the user reading
`FFI.errno`, the wrong `ThreadData` is read. This makes `FFI.errno` inherently unreliable
in M:N Ruby regardless of `ignore_errno:`, so the option optimizes something already broken
in that environment.
