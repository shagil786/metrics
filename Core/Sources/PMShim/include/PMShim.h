// PMShim: minimal C surface for libproc / sysctl APIs not exposed to Swift.
#ifndef PM_SHIM_H
#define PM_SHIM_H
#include "PMAudio.h"

#include <sys/types.h>
#include <sys/sysctl.h>
#include <libproc.h>
#include <string.h>
#include <stdlib.h>

/// PROC_PIDVNODEPATHINFO current-working-directory path into a caller buffer.
/// Returns >0 on success (bytes copied), 0 on failure.
static inline int pm_cwd_path(pid_t pid, char *buf, uint32_t buflen) {
    struct proc_vnodepathinfo vpi;
    int rc = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (rc <= 0) return 0;
    if (vpi.pvi_cdir.vip_path[0] == '\0') return 0;
    strlcpy(buf, vpi.pvi_cdir.vip_path, buflen);
    return (int)strnlen(buf, buflen);
}

/// Full executable path via proc_pidpath. Returns length, 0 on failure.
static inline int pm_exec_path(pid_t pid, char *buf, uint32_t buflen) {
    int rc = proc_pidpath(pid, buf, buflen);
    return rc > 0 ? rc : 0;
}

/// Cumulative disk I/O byte counts for a process via proc_pid_rusage
/// (RUSAGE_INFO_CURRENT, public libproc API; works for the caller's own
/// processes without special permission). Returns 0 on success and fills
/// both counters; nonzero on failure (short-lived pid, permission).
static inline int pm_rusage_disk(pid_t pid,
                                 unsigned long long *out_read_bytes,
                                 unsigned long long *out_written_bytes) {
    rusage_info_current ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, (rusage_info_t)&ri) != 0) {
        return -1;
    }
    *out_read_bytes = ri.ri_diskio_bytesread;
    *out_written_bytes = ri.ri_diskio_byteswritten;
    return 0;
}

/// argc + argv from sysctl(KERN_PROCARGS2) for another process.
/// Result is a heap-allocated array of C strings; caller frees with pm_free_args.
/// Returns count >= 1 on success, -1 on failure (permission, short-lived pid, ...).
static inline int pm_procargs2(pid_t pid, char ***out_args) {
    *out_args = NULL;
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) return -1;
    if (size < sizeof(int)) return -1;
    if (size > 1024 * 1024) return -1; // sanity cap

    void *buf = malloc(size);
    if (!buf) return -1;
    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0) {
        free(buf);
        return -1;
    }

    int argc = 0;
    memcpy(&argc, buf, sizeof(argc));
    if (argc <= 0 || argc > 4096) {
        free(buf);
        return -1;
    }

    // Layout: argc | exec_path (null-padded) | padding | env strings | arg strings...
    char *p = (char *)buf + sizeof(int);
    char *end = (char *)buf + size;

    // Skip exec path.
    size_t pathLen = strnlen(p, (size_t)(end - p));
    if (p + pathLen >= end) { free(buf); return -1; }
    p += pathLen + 1;

    // Skip padding NULs, then env strings (until the empty-string terminator).
    while (p < end && *p == '\0') p++;
    while (p < end) {
        size_t l = strnlen(p, (size_t)(end - p));
        if (l == 0) break;
        p += l + 1;
    }
    if (p >= end) { free(buf); return -1; }
    p++; // skip the NUL terminator of the env block

    char **args = (char **)malloc(sizeof(char *) * (size_t)argc);
    if (!args) { free(buf); return -1; }
    int n = 0;
    while (n < argc && p < end) {
        size_t l = strnlen(p, (size_t)(end - p));
        if (l == 0) break;
        args[n] = strdup(p);
        if (!args[n]) break;
        n++;
        p += l + 1;
    }
    free(buf);
    if (n == 0) { free(args); return -1; }
    *out_args = args;
    return n;
}

/// Free the array returned by pm_procargs2.
static inline void pm_free_args(char **args, int count) {
    if (!args) return;
    for (int i = 0; i < count; i++) free(args[i]);
    free(args);
}

// MARK: - SMC (Apple Silicon / Intel temperature & fan sensors)
//
// The SMC user client is the same mechanism every menu-bar system monitor
// uses (iStat, Stats, smcFanControl). Read-only here: temperature and fan
// keys only, no writes, no fan control. The structs mirror the canonical
// community layout exactly — C guarantees the memory layout the kernel
// expects, which Swift tuples would not.

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>

#define PM_SMC_CMD_READ_BYTES   5
#define PM_SMC_CMD_READ_INDEX   8
#define PM_SMC_CMD_READ_KEYINFO 9
/// The AppleSMC user client exposes ONE struct-method selector; the command
/// travels in data8 (smcFanControl's KERNEL_INDEX_SMC convention).
#define PM_SMC_SELECTOR         2

typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved;
    uint16_t release;
} PM_SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} PM_SMCLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} PM_SMCKeyInfoData;

typedef struct {
    uint32_t          key;
    PM_SMCVersion     vers;
    PM_SMCLimitData   pLimitData;
    PM_SMCKeyInfoData keyInfo;
    uint8_t           result;
    uint8_t           status;
    uint8_t           data8;
    uint32_t          data32;
    uint8_t           bytes[32];
} PM_SMCParam;

static io_connect_t pm_smc_conn = 0;

/// Open a read connection to the AppleSMC service. Safe to call repeatedly.
static inline bool pm_smc_open(void) {
    if (pm_smc_conn != 0) return true;
    io_service_t svc = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return false;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &pm_smc_conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS;
}

/// Close the SMC connection (process exit also cleans up).
static inline void pm_smc_close(void) {
    if (pm_smc_conn != 0) {
        IOServiceClose(pm_smc_conn);
        pm_smc_conn = 0;
    }
}

/// Read a 4-byte key (raw wire order — echo the bytes pm_smc_key_at
/// returned; the SMC's wire order is reversed relative to the community's
/// ASCII convention) into out. Returns the byte count (1...32), or 0 on
/// any failure — key absent, SMC unavailable.
static inline uint32_t pm_smc_read(const void *key4, uint8_t *out, uint32_t outMax) {
    if (!pm_smc_open()) return 0;
    PM_SMCParam in;
    PM_SMCParam outp;
    memset(&in, 0, sizeof in);
    memset(&outp, 0, sizeof outp);
    memcpy(&in.key, key4, 4);
    in.data8 = PM_SMC_CMD_READ_KEYINFO;
    size_t sz = sizeof in;
    kern_return_t kr = IOConnectCallStructMethod(
        pm_smc_conn, PM_SMC_SELECTOR, &in, sizeof in, &outp, &sz);
    if (kr != KERN_SUCCESS || outp.result != 0) return 0;
    uint32_t dataSize = outp.keyInfo.dataSize;
    if (dataSize == 0 || dataSize > 32 || dataSize > outMax) return 0;

    memset(&in, 0, sizeof in);
    memset(&outp, 0, sizeof outp);
    memcpy(&in.key, key4, 4);
    in.keyInfo.dataSize = dataSize;
    in.data8 = PM_SMC_CMD_READ_BYTES;
    sz = sizeof in;
    kr = IOConnectCallStructMethod(
        pm_smc_conn, PM_SMC_SELECTOR, &in, sizeof in, &outp, &sz);
    if (kr != KERN_SUCCESS || outp.result != 0) return 0;
    memcpy(out, outp.bytes, dataSize);
    return dataSize;
}

/// Read a 4-byte key's type code into out4 (raw wire order). Returns 1 on
/// success.
static inline int pm_smc_read_type(const void *key4, char out4[4]) {
    if (!pm_smc_open()) return 0;
    PM_SMCParam in;
    PM_SMCParam outp;
    memset(&in, 0, sizeof in);
    memset(&outp, 0, sizeof outp);
    memcpy(&in.key, key4, 4);
    in.data8 = PM_SMC_CMD_READ_KEYINFO;
    size_t sz = sizeof in;
    kern_return_t kr = IOConnectCallStructMethod(
        pm_smc_conn, PM_SMC_SELECTOR, &in, sizeof in, &outp, &sz);
    if (kr != KERN_SUCCESS || outp.result != 0) return 0;
    memcpy(out4, &outp.keyInfo.dataType, 4);
    return 1;
}

/// Key name at enumeration index into out4 (not NUL-terminated, raw wire
/// order). Returns 1 on success.
static inline int pm_smc_key_at(uint32_t index, char out4[4]) {
    if (!pm_smc_open()) return 0;
    PM_SMCParam in;
    PM_SMCParam outp;
    memset(&in, 0, sizeof in);
    memset(&outp, 0, sizeof outp);
    in.data8 = PM_SMC_CMD_READ_INDEX;
    in.data32 = index;
    size_t sz = sizeof in;
    kern_return_t kr = IOConnectCallStructMethod(
        pm_smc_conn, PM_SMC_SELECTOR, &in, sizeof in, &outp, &sz);
    if (kr != KERN_SUCCESS || outp.result != 0) return 0;
    memcpy(out4, &outp.key, 4);
    return 1;
}

#endif // PM_SHIM_H
