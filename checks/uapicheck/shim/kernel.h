/* uapicheck: prelude for kernel-internal headers probed in "extract" mode
 * (the ioctl part of e.g. the 5.4 adsprpc_shared.h, gf_spi.h). Kernel type
 * names and the attribute/bit macros, with the kernel's definitions. Used
 * for both trees alike. */
#ifndef _UAPICHECK_KERNEL_H
#define _UAPICHECK_KERNEL_H
#include <stdbool.h>
typedef __u8 u8;
typedef __u16 u16;
typedef __u32 u32;
typedef __u64 u64;
typedef __s8 s8;
typedef __s16 s16;
typedef __s32 s32;
typedef __s64 s64;
#ifndef __user
#define __user
#endif
#ifndef __iomem
#define __iomem
#endif
#ifndef __force
#define __force
#endif
#ifndef __packed
#define __packed __attribute__((packed))
#endif
#define __aligned(x) __attribute__((__aligned__(x)))
#define BIT(nr) (1UL << (nr))
#define BIT_ULL(nr) (1ULL << (nr))
#define GENMASK(h, l) (((~0UL) - (1UL << (l)) + 1) & (~0UL >> (8 * sizeof(long) - 1 - (h))))
#define GENMASK_ULL(h, l) (((~0ULL) - (1ULL << (l)) + 1) & (~0ULL >> (64 - 1 - (h))))
/* include/linux/kconfig.h */
#ifndef IS_ENABLED
#define __ARG_PLACEHOLDER_1 0,
#define __take_second_arg(__ignored, val, ...) val
#define __and(x, y) ___and(x, y)
#define ___and(x, y) ____and(__ARG_PLACEHOLDER_##x, y)
#define ____and(arg1_or_junk, y) __take_second_arg(arg1_or_junk y, 0)
#define __or(x, y) ___or(x, y)
#define ___or(x, y) ____or(__ARG_PLACEHOLDER_##x, y)
#define ____or(arg1_or_junk, y) __take_second_arg(arg1_or_junk 1, y)
#define __is_defined(x) ___is_defined(x)
#define ___is_defined(val) ____is_defined(__ARG_PLACEHOLDER_##val)
#define ____is_defined(arg1_or_junk) __take_second_arg(arg1_or_junk 1, 0)
#define IS_BUILTIN(option) __is_defined(option)
#define IS_MODULE(option) __is_defined(option##_MODULE)
#define IS_REACHABLE(option) __or(IS_BUILTIN(option), __and(IS_MODULE(option), __is_defined(MODULE)))
#define IS_ENABLED(option) __or(IS_BUILTIN(option), IS_MODULE(option))
#endif
#endif
