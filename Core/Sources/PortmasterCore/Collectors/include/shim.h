// Minimal C shim: libproc / sysctl APIs not exposed to Swift.
#ifndef PORTMASTER_SHIM_H
#define PORTMASTER_SHIM_H

#include <sys/types.h>
#include <sys/sysctl.h>
#include <libproc.h>

/// PROC_PIDVNODEPATHINFO current-working-directory path into a caller buffer.
/// Returns >0 on success (bytes copied), 0 or -1 on failure.
static inline int pm_cwd_path(pid_t pid, char *buf, uint32_t buflen) {
    struct proc_vnodepathinfo vpi;
    int rc = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (rc <= 0) return 0;
    if (vpi.pvi_cdir.vip_path[0] == '\0') return 0;
    strlcpy(buf, vpi.pvi_cdir.vip_path, buflen);
    return (int)strnlen(buf, buflen);
}

/// Full executable path via proc_pidpath.
static inline int pm_exec_path(pid_t pid, char *buf, uint32_t buflen) {
    return proc_pidpath(pid, buf, buflen);
}

/// Cumulative disk I/O byte counts for a process via proc_pid_rusage
/// (RUSAGE_INFO_CURRENT, public libproc API). Returns 0 on success.
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
/// Returns count >= 0 on success, -1 on failure (permission, short-lived pid, ...).
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

    // Skip padding NULs up to alignment, then env strings (until double NUL).
    while (p < end && *p == '\0') p++;
    while (p < end) {
        size_t l = strnlen(p, (size_t)(end - p));
        if (l == 0) break;      // empty string = end of env block
        p += l + 1;
    }
    p++; // skip the NUL terminator of the env block

    // Collect argv.
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

#endif // PORTMASTER_SHIM_H
