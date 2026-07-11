/* standalone_mutate_stub.c — a no-op LLVMFuzzerMutate for the standalone reproducer build.
 *
 * The OSS-Fuzz harness (fuzz_config_read.c) defines LLVMFuzzerCustomMutator, which calls the
 * libFuzzer-provided LLVMFuzzerMutate(). The libFuzzer build links that symbol from the fuzzing
 * engine. The standalone reproducer (StandaloneFuzzTargetMain.c) has no libFuzzer runtime, so
 * LLVMFuzzerMutate would be an undefined reference at link time even though the custom mutator is
 * never actually invoked when just replaying inputs. This weak stub satisfies the link; if it were
 * ever called it returns the buffer unchanged. */
#include <stddef.h>
#include <stdint.h>

__attribute__((weak)) size_t LLVMFuzzerMutate(uint8_t *Data, size_t Size, size_t MaxSize)
{
    (void)Data;
    (void)MaxSize;
    return Size;
}
