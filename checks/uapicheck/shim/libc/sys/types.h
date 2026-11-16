/* uapicheck shim: the few libc types the vendor UAPI headers use. The same
 * shim is used for the 5.4 and the 6.12 headers, so it cannot cause a
 * difference; sizes follow bionic (ILP32 armv7, LP64 aarch64). */
#ifndef _UAPICHECK_SYS_TYPES_H
#define _UAPICHECK_SYS_TYPES_H
#include <stddef.h>
#include <stdint.h>
typedef long ssize_t;
typedef long off_t;
typedef int pid_t;
typedef unsigned int uid_t;
typedef unsigned int gid_t;
typedef unsigned int mode_t;
typedef long time_t;
typedef long suseconds_t;
typedef unsigned int uint;
typedef unsigned long ulong;
typedef unsigned short ushort;
#endif
