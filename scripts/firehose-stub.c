/*
 * firehose-stub.c -- a stand-in for libfirehose_kernel.
 *
 * xnu links against -lfirehose_kernel for os_log's shared-memory tracepoint
 * buffer. The real implementation lives in libdispatch's firehose_buffer.c,
 * which cannot be built here: it needs the firehose private headers, and the only
 * copies available are the ones in the current macOS SDK, written for a much
 * newer libdispatch. Mixing the two leaves the internal headers' bodies
 * compiled out and every inline entry point undeclared.
 *
 * None of that matters for bring-up. os_log is not how we read this kernel --
 * the console goes to the framebuffer, and printf/kprintf never touch
 * firehose. So the buffer simply never gets created: every reservation fails,
 * the kernel takes its own "no buffer" path, and the messages are dropped.
 *
 * Only five symbols are needed. The rest of the __firehose_* namespace
 * (__firehose_allocate, __firehose_critical_region_enter/leave,
 * __firehose_buffer_push_to_logd, and the chunk-count variables) is defined
 * by xnu itself in libkern/os/log.c and bsd/kern/subr_log.c.
 *
 * The parameter types here are deliberately plain: the real prototypes use
 * firehose types from headers we are avoiding, and a stub that ignores its
 * arguments does not care how they were passed.
 *
 * Build:
 *   clang -arch arm64 -mkernel -ffreestanding -fno-builtin -c firehose-stub.c
 *   ar rcs libfirehose_kernel.a firehose-stub.o
 */

typedef __UINT64_TYPE__ stub_u64;
typedef __UINT16_TYPE__ stub_u16;
typedef __UINT8_TYPE__  stub_u8;
typedef __SIZE_TYPE__   stub_size;

/*
 * Called once from oslog_init(). Returning NULL leaves kernel_firehose_addr
 * zero, which every later path already treats as "logging unavailable".
 */
void *
__firehose_buffer_create(stub_size *size)
{
	if (size) {
		*size = 0;
	}
	return (void *)0;
}

/*
 * Reserve space for one tracepoint. NULL means "no room"; os_log counts the
 * drop and moves on.
 */
void *
__firehose_buffer_tracepoint_reserve(stub_u64 stamp, unsigned int stream,
    stub_u16 pubsize, stub_u16 privsize, stub_u8 **privptr)
{
	(void)stamp; (void)stream; (void)pubsize; (void)privsize;
	if (privptr) {
		*privptr = (stub_u8 *)0;
	}
	return (void *)0;
}

/* Never reached: nothing is ever reserved. */
void
__firehose_buffer_tracepoint_flush(void *ft, stub_u64 ftid)
{
	(void)ft; (void)ftid;
}

/* Reply from logd. There is no logd here. */
void
__firehose_merge_updates(stub_u64 update)
{
	(void)update;
}

/*
 * Validates the chunk-count / io-pages boot-args. Accepting whatever xnu
 * picked keeps oslog_init() on its normal path up to the buffer creation
 * above, so the boot-time log line still prints.
 */
int
__firehose_kernel_configuration_valid(stub_u8 chunk_count, stub_u8 io_pages)
{
	(void)chunk_count; (void)io_pages;
	return 1;
}
