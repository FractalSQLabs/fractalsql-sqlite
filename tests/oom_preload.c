/* tests/oom_preload.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * LD_PRELOAD fault-injection shim for the fault gates against fractalsqld.
 * It wraps malloc/calloc/realloc/strdup, and the stdio and file calls the
 * daemon uses for its ledger and configuration files, and makes one chosen
 * call fail the way the real call would under memory or disk pressure
 * (NULL, a short count, EOF or -1). Every other call passes through to the
 * real implementation unchanged.
 *
 * Three ways to choose the failing call:
 *
 *   FSQL_OOM_FAIL_AT=N   the Nth allocation of the whole process fails
 *                        (NULL with errno set to ENOMEM, as the real
 *                        allocator reports it, which glibc's own thread
 *                        creation relies on; for realloc the original block
 *                        is left untouched, per realloc(3)). Read once at
 *                        load time, so a fresh process is started per trial.
 *   FSQL_IO_FAIL_AT=M    the Mth stdio/file call of the whole process fails.
 *                        Also read once at load time (boot-path trials).
 *   FSQL_OOM_WORKERS_ONLY=1  count and fail only calls made off the main thread
 *   FSQL_SYS_FAIL_AT=K   the Kth socket or thread call of the whole process
 *                        fails with errno FSQL_SYS_ERRNO (EIO by default).
 *                        Read once at load time (boot-path trials).
 *   FSQL_OOM_ONLY_SO=<substring>  count and fail only allocations whose CALLER lives in a shared object whose
 *                        path contains the substring (dladdr on the return address): the extension's own
 *                        allocations, not the engine's. With FSQL_OOM_CTL, SIGUSR2 (disarm) also writes
 *                        "<allocations counted> <failures injected>" to <ctl file>.res, which is how a driver
 *                        learns how many allocation sites a statement has.
 *   FSQL_OOM_LINEBUF=1   line-buffer stdout (a driver that talks to a CLI over a pipe)
 *   FSQL_OOM_CTL=<file>  for a long-lived process: SIGUSR1 reads "N M K E"
 *                        from the file (any may be 0 or missing for "no
 *                        fault"), restarts the counters at zero and arms the
 *                        Nth allocation, Mth file call and Kth socket or
 *                        thread call after the signal (K fails with errno
 *                        E, EIO when absent); SIGUSR2 disarms. This lets one daemon be swept across many
 *                        calls without a restart per trial.
 *
 * With none of these set, or with N and M at 0, every call is a pure
 * passthrough.
 *
 * Every LD_PRELOAD allocator shim needs the same two things this one has:
 * real_malloc/etc. resolved LAZILY (a constructor can't safely call dlsym
 * for them, because dlsym/the dynamic linker's own startup work may itself
 * need to allocate before our constructor has even run, let alone before
 * dlsym(RTLD_NEXT, "malloc") has returned; calling our own malloc() from
 * inside that resolution would recurse into dlsym again, forever); and a
 * small preinit scratch buffer to satisfy any allocation that lands before
 * the real allocator has been resolved, so that first call has somewhere
 * else to get memory from.
 *
 * Build: cc -O2 -fPIC -shared -o oom_preload.so tests/oom_preload.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <execinfo.h>

static void *(*real_malloc)(size_t)          = NULL;
static void *(*real_calloc)(size_t, size_t)  = NULL;
static void *(*real_realloc)(void *, size_t) = NULL;

#define PREINIT_CAP (64u * 1024u)
static unsigned char preinit_buf[PREINIT_CAP];
static size_t        preinit_off = 0;

static void *
preinit_alloc(size_t n)
{
    size_t aligned = (preinit_off + 15u) & ~(size_t) 15u;
    if (aligned + n > PREINIT_CAP) return NULL;
    void *p = preinit_buf + aligned;
    preinit_off = aligned + n;
    return p;
}

static int
is_preinit_ptr(const void *p)
{
    return (const unsigned char *) p >= preinit_buf &&
           (const unsigned char *) p <  preinit_buf + PREINIT_CAP;
}

static long g_fail_at = 0;   /* 0 = injection disabled (pure passthrough) */
static long g_count   = 0;
static long g_io_fail_at = 0;   /* 0 = no stdio/file fault */
static long g_io_count   = 0;
static long g_sys_fail_at = 0;  /* 0 = no socket/thread fault */
static long g_sys_count   = 0;
static int  g_sys_errno   = EIO;
static int  g_workers_only = 0;   /* FSQL_OOM_WORKERS_ONLY: spare the main thread */
static const char *g_ctl_path = NULL;
static const char *g_only_so = NULL;   /* FSQL_OOM_ONLY_SO */
static long g_fired = 0;               /* failures injected since the last arming */

/* True on the process's main thread, which is spared when FSQL_OOM_WORKERS_ONLY
 * is set: a server's reader loop has no recovery from a failed allocation, but
 * each request's worker thread does. */
static int
spared_thread(void)
{
    return g_workers_only && (pid_t) syscall(SYS_gettid) == getpid();
}

/* Control-file mode (FSQL_OOM_CTL=<path>): a long-lived process is armed
 * between calls instead of being restarted per trial. SIGUSR1 reads the
 * integer N from the file, restarts the allocation count at zero and makes
 * the Nth allocation after the signal fail; SIGUSR2 disarms. Only open(2),
 * read(2) and close(2) are used inside the handler. */
static void
oom_arm(int sig)
{
    (void) sig;
    char buf[48];
    long n = 0, m = 0, k = 0, e = 0;
    int  fd = open(g_ctl_path, O_RDONLY);
    if (fd >= 0) {
        ssize_t r = read(fd, buf, sizeof buf - 1);
        close(fd);
        if (r > 0) {
            ssize_t i = 0;
            for (; i < r && buf[i] >= '0' && buf[i] <= '9'; i++) n = n * 10 + (buf[i] - '0');
            while (i < r && buf[i] == ' ') i++;
            for (; i < r && buf[i] >= '0' && buf[i] <= '9'; i++) m = m * 10 + (buf[i] - '0');
            while (i < r && buf[i] == ' ') i++;
            for (; i < r && buf[i] >= '0' && buf[i] <= '9'; i++) k = k * 10 + (buf[i] - '0');
            while (i < r && buf[i] == ' ') i++;
            for (; i < r && buf[i] >= '0' && buf[i] <= '9'; i++) e = e * 10 + (buf[i] - '0');
        }
    }
    __atomic_store_n(&g_count, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_fired, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_io_count, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_sys_count, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_sys_errno, e > 0 ? (int) e : EIO, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_fail_at, n, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_io_fail_at, m, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_sys_fail_at, k, __ATOMIC_SEQ_CST);
    if (g_only_so) {                          /* ack: "<ctl>.armed" exists once the new arming is in force */
        char path[600];
        size_t pl = strlen(g_ctl_path);
        if (pl + 7 < sizeof path) {
            memcpy(path, g_ctl_path, pl); memcpy(path + pl, ".armed", 7);
            int afd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (afd >= 0) close(afd);
        }
    }
}

static void
oom_disarm(int sig)
{
    (void) sig;
    if (g_ctl_path && g_only_so) {            /* report: "<counted> <injected>" (async-signal-safe: open/write/close) */
        char path[600], out[48];
        size_t pl = strlen(g_ctl_path);
        if (pl + 5 < sizeof path) {
            memcpy(path, g_ctl_path, pl); memcpy(path + pl, ".res", 5);
            long c = __atomic_load_n(&g_count, __ATOMIC_SEQ_CST), f = __atomic_load_n(&g_fired, __ATOMIC_SEQ_CST);
            char tmp[24]; int ti = 0, oi = 0;
            long v[2] = { c, f };
            for (int k = 0; k < 2; k++) {
                long x = v[k]; ti = 0;
                if (x == 0) tmp[ti++] = '0';
                while (x > 0) { tmp[ti++] = (char) ('0' + x % 10); x /= 10; }
                while (ti > 0) out[oi++] = tmp[--ti];
                out[oi++] = k ? '\n' : ' ';
            }
            int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) { (void) !write(fd, out, (size_t) oi); close(fd); }
        }
    }
    __atomic_store_n(&g_fail_at, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_io_fail_at, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_sys_fail_at, 0, __ATOMIC_SEQ_CST);
}

/* In-process control, for a test program that links against its own code and
 * wants to sweep failures without signals: arm the Nth allocation and Mth file
 * call (0 = none) after zeroing both counters; read how many of each were seen
 * since arming (counting needs N or M above zero, so arm with a very large
 * value to count a clean run); disarm. */
void fsql_oom_arm(long n, long m)
{
    __atomic_store_n(&g_count, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_io_count, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_fail_at, n, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_io_fail_at, m, __ATOMIC_SEQ_CST);
}
void fsql_oom_disarm(void) { fsql_oom_arm(0, 0); }
long fsql_oom_allocs(void) { return __atomic_load_n(&g_count, __ATOMIC_SEQ_CST); }
long fsql_oom_ios(void) { return __atomic_load_n(&g_io_count, __ATOMIC_SEQ_CST); }

/* FSQL_OOM_BT=1: print a backtrace to stderr when the process dies on SIGABRT/SIGSEGV/SIGBUS, to find
 * which code a failed allocation took down (a value starting with / is a file to append to). Off by default. */
static const char *g_bt_path = NULL;   /* FSQL_OOM_BT=<path>: append there instead of stderr */

static void
oom_bt(int sig)
{
    void *fr[48];
    int   n = backtrace(fr, 48);
    int   fd = g_bt_path ? open(g_bt_path, O_WRONLY | O_CREAT | O_APPEND, 0644) : 2;
    if (fd < 0) fd = 2;
    static const char hdr[] = "oom_preload backtrace:\n";
    (void) !write(fd, hdr, sizeof hdr - 1);
    backtrace_symbols_fd(fr, n, fd);
    signal(sig, SIG_DFL);
    raise(sig);
}

__attribute__((constructor))
static void
oom_preload_init(void)
{
    const char *bt = getenv("FSQL_OOM_BT");
    if (bt && *bt && strcmp(bt, "0") != 0) {
        void *warm[2];
        if (bt[0] == '/') g_bt_path = bt;
        (void) backtrace(warm, 2);       /* load libgcc now, not inside the handler */
        signal(SIGABRT, oom_bt); signal(SIGSEGV, oom_bt); signal(SIGBUS, oom_bt);
    }
    const char *v = getenv("FSQL_OOM_FAIL_AT");
    if (v && *v) {
        long n = strtol(v, NULL, 10);
        if (n > 0) g_fail_at = n;
    }
    v = getenv("FSQL_IO_FAIL_AT");
    if (v && *v) {
        long m = strtol(v, NULL, 10);
        if (m > 0) g_io_fail_at = m;
    }
    v = getenv("FSQL_SYS_FAIL_AT");
    if (v && *v) {
        long k = strtol(v, NULL, 10);
        if (k > 0) g_sys_fail_at = k;
    }
    v = getenv("FSQL_SYS_ERRNO");
    if (v && *v && strtol(v, NULL, 10) > 0) g_sys_errno = (int) strtol(v, NULL, 10);
    v = getenv("FSQL_OOM_WORKERS_ONLY");
    g_workers_only = (v && *v && strcmp(v, "0") != 0);
    if (getenv("FSQL_OOM_LINEBUF")) setvbuf(stdout, NULL, _IOLBF, 0);   /* an interactive driver reads answers as they come */
    g_only_so = getenv("FSQL_OOM_ONLY_SO");
    if (g_only_so && !*g_only_so) g_only_so = NULL;
    g_ctl_path = getenv("FSQL_OOM_CTL");
    if (g_ctl_path && *g_ctl_path) {
        signal(SIGUSR1, oom_arm);
        signal(SIGUSR2, oom_disarm);
    }
}

/* Counts this call; true on exactly the Nth one (N = FSQL_OOM_FAIL_AT).
 * Every call that reaches here -- including ones that will go on to
 * pass through -- still counts, so the Nth allocation ACROSS THE WHOLE
 * PROCESS is what fails, not the Nth call to any one specific wrapper. */
/* True when the allocation's caller is in the shared object FSQL_OOM_ONLY_SO names (always true without it). */
static int
caller_in_target(void *ra)
{
    if (!g_only_so) return 1;
    Dl_info di;
    return dladdr(ra, &di) && di.dli_fname && strstr(di.dli_fname, g_only_so) != NULL;
}

static int
should_fail(void *ra)
{
    long at = __atomic_load_n(&g_fail_at, __ATOMIC_SEQ_CST);
    if (at <= 0 || spared_thread()) return 0;
    if (!caller_in_target(ra)) return 0;
    long c = __atomic_add_fetch(&g_count, 1, __ATOMIC_SEQ_CST);
    if (c == at) { __atomic_add_fetch(&g_fired, 1, __ATOMIC_SEQ_CST); return 1; }
    return 0;
}

void *
malloc(size_t size)
{
    if (real_malloc == NULL) {
        real_malloc = (void *(*)(size_t)) dlsym(RTLD_NEXT, "malloc");
        if (real_malloc == NULL) return preinit_alloc(size);
    }
    if (should_fail(__builtin_return_address(0))) { errno = ENOMEM; return NULL; }
    return real_malloc(size);
}

void *
calloc(size_t nmemb, size_t size)
{
    if (real_calloc == NULL) {
        real_calloc = (void *(*)(size_t, size_t)) dlsym(RTLD_NEXT, "calloc");
        if (real_calloc == NULL) {
            void *p = preinit_alloc(nmemb * size);
            if (p) memset(p, 0, nmemb * size);
            return p;
        }
    }
    if (should_fail(__builtin_return_address(0))) { errno = ENOMEM; return NULL; }
    return real_calloc(nmemb, size);
}

void *
realloc(void *ptr, size_t size)
{
    if (real_realloc == NULL) {
        real_realloc = (void *(*)(void *, size_t)) dlsym(RTLD_NEXT, "realloc");
        if (real_realloc == NULL) return preinit_alloc(size);
    }
    if (is_preinit_ptr(ptr)) {
        /* A pointer our own preinit_alloc handed out before the real
         * allocator resolved: the real realloc() has never heard of
         * it, so grow by copy instead of passing it through. Only the
         * handful of allocations made before our own resolution
         * completes ever take this path. */
        void *p = real_realloc(NULL, size);
        if (p && ptr) memcpy(p, ptr, size);
        return p;
    }
    if (should_fail(__builtin_return_address(0))) { errno = ENOMEM; return NULL; }   /* `ptr` is left valid, per realloc(3) */
    return real_realloc(ptr, size);
}

char *
strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    /* One counted allocation, attributed to strdup's own caller (not to this shim). */
    if (real_malloc == NULL) {
        real_malloc = (void *(*)(size_t)) dlsym(RTLD_NEXT, "malloc");
        if (real_malloc == NULL) return NULL;
    }
    if (should_fail(__builtin_return_address(0))) { errno = ENOMEM; return NULL; }
    char *p = (char *) real_malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}


/* ---- stdio / file-system faults (control-file mode only) --------------
 * The Mth call, after arming, to any of the wrappers below fails the way the
 * real call would on a bad disk: fopen/fdopen NULL, fread/fwrite a short count,
 * fflush/fseek/fsync/fchmod/ftruncate -1 or EOF, ftell -1, mkstemp -1. */
static int
io_should_fail(void)
{
    long at = __atomic_load_n(&g_io_fail_at, __ATOMIC_SEQ_CST);
    if (at <= 0 || spared_thread()) return 0;
    return __atomic_add_fetch(&g_io_count, 1, __ATOMIC_SEQ_CST) == at;
}

FILE *fopen(const char *path, const char *mode)
{ static FILE *(*r)(const char *, const char *); if (!r) r = dlsym(RTLD_NEXT, "fopen");
  if (io_should_fail()) { errno = EIO; return NULL; } return r(path, mode); }
FILE *fdopen(int fd, const char *mode)
{ static FILE *(*r)(int, const char *); if (!r) r = dlsym(RTLD_NEXT, "fdopen");
  if (io_should_fail()) { errno = EIO; return NULL; } return r(fd, mode); }
size_t fread(void *p, size_t sz, size_t n, FILE *f)
{ static size_t (*r)(void *, size_t, size_t, FILE *); if (!r) r = dlsym(RTLD_NEXT, "fread");
  if (io_should_fail()) { errno = EIO; return 0; } return r(p, sz, n, f); }
size_t fwrite(const void *p, size_t sz, size_t n, FILE *f)
{ static size_t (*r)(const void *, size_t, size_t, FILE *); if (!r) r = dlsym(RTLD_NEXT, "fwrite");
  if (io_should_fail()) { errno = EIO; return 0; } return r(p, sz, n, f); }
int fflush(FILE *f)
{ static int (*r)(FILE *); if (!r) r = dlsym(RTLD_NEXT, "fflush");
  if (f != NULL && f != stderr && f != stdout && io_should_fail()) { errno = EIO; return EOF; } return r(f); }
int fseek(FILE *f, long off, int wh)
{ static int (*r)(FILE *, long, int); if (!r) r = dlsym(RTLD_NEXT, "fseek");
  if (io_should_fail()) { errno = EIO; return -1; } return r(f, off, wh); }
long ftell(FILE *f)
{ static long (*r)(FILE *); if (!r) r = dlsym(RTLD_NEXT, "ftell");
  if (io_should_fail()) { errno = EIO; return -1L; } return r(f); }
int fgetc(FILE *f)
{ static int (*r)(FILE *); if (!r) r = dlsym(RTLD_NEXT, "fgetc");
  if (io_should_fail()) { errno = EIO; return EOF; } return r(f); }
int fputc(int c, FILE *f)
{ static int (*r)(int, FILE *); if (!r) r = dlsym(RTLD_NEXT, "fputc");
  if (f != stderr && f != stdout && io_should_fail()) { errno = EIO; return EOF; } return r(c, f); }
int fsync(int fd)
{ static int (*r)(int); if (!r) r = dlsym(RTLD_NEXT, "fsync");
  if (io_should_fail()) { errno = EIO; return -1; } return r(fd); }
int ftruncate(int fd, off_t len)
{ static int (*r)(int, off_t); if (!r) r = dlsym(RTLD_NEXT, "ftruncate");
  if (io_should_fail()) { errno = EIO; return -1; } return r(fd, len); }
int fchmod(int fd, mode_t m)
{ static int (*r)(int, mode_t); if (!r) r = dlsym(RTLD_NEXT, "fchmod");
  if (io_should_fail()) { errno = EIO; return -1; } return r(fd, m); }
int mkstemp(char *t)
{ static int (*r)(char *); if (!r) r = dlsym(RTLD_NEXT, "mkstemp");
  if (io_should_fail()) { errno = EIO; return -1; } return r(t); }

/* ---- socket and thread faults (control-file mode only) ----------------
 * The Kth call, after arming, to any wrapper below fails with the errno the
 * control file's fourth number names (EIO when it is absent): socket, bind,
 * listen, accept, recv, send, setsockopt, getsockopt, chmod return -1 and
 * pthread_create returns the errno value, as each real call reports. */
static int
sys_should_fail(void)
{
    long at = __atomic_load_n(&g_sys_fail_at, __ATOMIC_SEQ_CST);
    if (at <= 0 || spared_thread()) return 0;
    return __atomic_add_fetch(&g_sys_count, 1, __ATOMIC_SEQ_CST) == at;
}

#define SYS_FAIL() do { errno = __atomic_load_n(&g_sys_errno, __ATOMIC_SEQ_CST); return -1; } while (0)

int socket(int d, int t, int p)
{ static int (*r)(int, int, int); if (!r) r = dlsym(RTLD_NEXT, "socket");
  if (sys_should_fail()) SYS_FAIL();
  return r(d, t, p); }
int bind(int fd, const struct sockaddr *a, socklen_t l)
{ static int (*r)(int, const struct sockaddr *, socklen_t); if (!r) r = dlsym(RTLD_NEXT, "bind");
  if (sys_should_fail()) SYS_FAIL();
  return r(fd, a, l); }
int listen(int fd, int b)
{ static int (*r)(int, int); if (!r) r = dlsym(RTLD_NEXT, "listen");
  if (sys_should_fail()) SYS_FAIL();
  return r(fd, b); }
int accept(int fd, struct sockaddr *a, socklen_t *l)
{ static int (*r)(int, struct sockaddr *, socklen_t *); if (!r) r = dlsym(RTLD_NEXT, "accept");
  if (sys_should_fail()) SYS_FAIL();
  return r(fd, a, l); }
ssize_t recv(int fd, void *b, size_t n, int f)
{ static ssize_t (*r)(int, void *, size_t, int); if (!r) r = dlsym(RTLD_NEXT, "recv");
  if (sys_should_fail()) SYS_FAIL();
  return r(fd, b, n, f); }
ssize_t send(int fd, const void *b, size_t n, int f)
{ static ssize_t (*r)(int, const void *, size_t, int); if (!r) r = dlsym(RTLD_NEXT, "send");
  if (sys_should_fail()) SYS_FAIL();
  return r(fd, b, n, f); }
int setsockopt(int fd, int lv, int on, const void *v, socklen_t l)
{ static int (*r)(int, int, int, const void *, socklen_t); if (!r) r = dlsym(RTLD_NEXT, "setsockopt");
  if (sys_should_fail()) SYS_FAIL();
  return r(fd, lv, on, v, l); }
int getsockopt(int fd, int lv, int on, void *v, socklen_t *l)
{ static int (*r)(int, int, int, void *, socklen_t *); if (!r) r = dlsym(RTLD_NEXT, "getsockopt");
  if (sys_should_fail()) SYS_FAIL();
  return r(fd, lv, on, v, l); }
int chmod(const char *p, mode_t m)
{ static int (*r)(const char *, mode_t); if (!r) r = dlsym(RTLD_NEXT, "chmod");
  if (sys_should_fail()) SYS_FAIL();
  return r(p, m); }
int pthread_create(pthread_t *t, const pthread_attr_t *a, void *(*f)(void *), void *arg)
{ static int (*r)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
  if (!r) r = dlsym(RTLD_NEXT, "pthread_create");
  if (sys_should_fail()) return __atomic_load_n(&g_sys_errno, __ATOMIC_SEQ_CST);
  return r(t, a, f, arg); }
