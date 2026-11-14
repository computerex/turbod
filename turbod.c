/*
 * turbod -- root daemon + privileged helper for TurboLock.kext
 *
 * WHAT THIS IS
 * ------------
 * Intel Turbo Boost is switched by one bit of one model-specific register
 * (Intel SDM Vol. 4, IA32_MISC_ENABLE, MSR 0x1A0, bit 38 "Turbo Mode
 * Disable"). MSRs are ring-0, and macOS exposes no sysctl, no pmset knob and
 * no IOKit user-space API for it, so kernel code is mandatory.
 *
 * That kernel code is ours: kext/TurboLock.c, ~40 lines. This daemon owns its
 * load/unload state:
 *
 *     loaded   => bit 38 set   => Turbo Boost disabled
 *     unloaded => bit 38 clear => Turbo Boost enabled
 *
 * Because the daemon runs as root under launchd and stays resident, toggling
 * never prompts for a password, and a wake is handled in-process instead of
 * relaunching a privileged helper.
 *
 * ONE-TIME APPROVAL
 * -----------------
 * The kext is built locally and is therefore unsigned. macOS will only load
 * it once it has been approved -- either with a Developer ID signature, or by
 * loading it while kext signing is relaxed (`csrutil enable --without kext`).
 * Approval is recorded per machine in
 * /var/db/SystemPolicyConfiguration/KextPolicy and stashed into the auxiliary
 * kernel collection, and it survives re-enabling SIP afterwards.
 *
 * install.sh walks through that once. After it, nothing here needs privileges
 * from the user again.
 *
 * Usage:
 *   turbod                     run as daemon (what launchd starts)
 *   turbod --once off|on       do one change and exit (needs root)
 *   turbod --once status       print state and exit
 *   turbod --apply-saved       re-apply the stored state and exit
 *   turbod --probe             read-only diagnostics (no root required)
 */

#define _DARWIN_C_SOURCE

#include <errno.h>
#include <grp.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>

/* Overridable at compile time so the daemon can be exercised in a sandbox
 * (see test-sandbox.sh) without root. */
#ifndef RUN_DIR
#define RUN_DIR "/usr/local/libexec/turbodisable"
#endif
#ifndef VAR_DIR
#define VAR_DIR "/usr/local/var/turbodisable"
#endif
#ifndef SOCK_PATH
#define SOCK_PATH "/var/run/turbodisable.sock"
#endif
#define STATE_FILE VAR_DIR "/state"
#define LOG_FILE   VAR_DIR "/turbod.log"

/* --------------------------------------------------------------- backends --
 *
 * The ring-0 half can be either kext. turbod does not care which: it loads and
 * unloads one by bundle identifier, and both kexts do the same thing (set or
 * clear IA32_MISC_ENABLE bit 38 on every core).
 *
 * TBS's comes first on purpose. It is covered by an existing per-machine
 * allowance for com.rugarciap.DisableTurboBoost, so on a machine where Turbo
 * Boost Switcher has been installed it loads on a stock system with no
 * `csrutil` change at all. That is the whole point of depending on it.
 *
 * TurboLock is ours and is the fallback. It is unsigned, so it needs either a
 * Developer ID or a one-time `csrutil enable --without kext`.
 *
 * See README "Backends".
 */
struct kext_backend {
    const char *id;
    const char *name;
    const char *paths[4];
};

static const struct kext_backend backends[] = {
    { "com.rugarciap.DisableTurboBoost", "TBS", {
          "/Applications/tbswitcher_resources/DisableTurboBoost.64bits.kext",
          "/Library/StagedExtensions/Applications/tbswitcher_resources/"
          "DisableTurboBoost.64bits.kext",
          "/Library/Extensions/DisableTurboBoost.64bits.kext",
          NULL } },
    { "com.turbodisable.TurboLock", "TurboLock", {
          "/Library/Extensions/TurboLock.kext",
          RUN_DIR "/kext/TurboLock.kext",
          NULL } },
    { NULL, NULL, { NULL } }
};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

/* ------------------------------------------------------------------ utils */

static void logmsg(int echo, const char *fmt, ...) {
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);

    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char stamp[32];
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", &tm);

    FILE *f = fopen(LOG_FILE, "a");
    if (f) {
        fprintf(f, "%s [%d] %s\n", stamp, (int)getpid(), line);
        fclose(f);
    }
    if (echo) fprintf(stderr, "%s\n", line);
}

static void mkdir_p(const char *path) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
}

/* Run a shell command, capture stdout+stderr, return its exit status. */
static int run(const char *cmd, char *out, size_t outlen) {
    FILE *f = popen(cmd, "r");
    if (!f) return -1;
    size_t used = 0;
    if (out && outlen) out[0] = '\0';
    char buf[512];
    size_t r;
    while ((r = fread(buf, 1, sizeof buf, f)) > 0) {
        if (out && used + 1 < outlen) {
            size_t c = r;
            if (c > outlen - 1 - used) c = outlen - 1 - used;
            memcpy(out + used, buf, c);
            used += c;
            out[used] = '\0';
        }
    }
    int st = pclose(f);
    if (st == -1) return -1;
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    return 128;
}

/* --------------------------------------------------------------- kext glue */

static int id_loaded(const char *id) {
    /* Filter server-side: the unfiltered table is hundreds of lines and would
     * silently truncate any fixed buffer. */
    char out[4096];
    char cmd[600];
    snprintf(cmd, sizeof cmd,
             "/usr/bin/kmutil showloaded --list-only --bundle-identifier %s 2>&1",
             id);
    if (run(cmd, out, sizeof out) != 0) return 0;
    return strstr(out, id) != NULL;
}

static const char *backend_path(const struct kext_backend *b) {
    for (int j = 0; b->paths[j]; j++)
        if (access(b->paths[j], F_OK) == 0) return b->paths[j];
    return NULL;
}

/* A backend that is already loaded wins; otherwise the first one present on
 * disk. This is what lets one daemon serve either kext. */
static const struct kext_backend *active_backend(void) {
    for (int i = 0; backends[i].id; i++)
        if (id_loaded(backends[i].id)) return &backends[i];
    for (int i = 0; backends[i].id; i++)
        if (backend_path(&backends[i])) return &backends[i];
    return NULL;
}

/* For either backend, "kext loaded" and "turbo disabled" are the same thing. */
static int kext_loaded(void) {
    for (int i = 0; backends[i].id; i++)
        if (id_loaded(backends[i].id)) return 1;
    return 0;
}

static int kext_present(void) {
    for (int i = 0; backends[i].id; i++)
        if (backend_path(&backends[i])) return 1;
    return 0;
}

/* Is kext signing relaxed? Then an unsigned kext may load. */
static int signing_relaxed(void) {
    char out[2048] = "";
    run("/usr/bin/csrutil status 2>&1", out, sizeof out);
    if (strstr(out, "Kext Signing: disabled")) return 1;
    if (strstr(out, "System Integrity Protection status: disabled")) return 1;
    return 0;
}

static void append_err(char *dst, size_t dstlen, const char *src) {
    if (!dst || !dstlen || !src || !*src) return;
    size_t used = strlen(dst);
    if (used >= dstlen - 1) return;
    snprintf(dst + used, dstlen - used, "%s", src);
}

static int load_kext(char *err, size_t errlen) {
    if (kext_loaded()) return 0;
    if (err && errlen) err[0] = '\0';

    for (int i = 0; backends[i].id; i++) {
        const struct kext_backend *b = &backends[i];
        const char *path = backend_path(b);
        if (!path) continue;

        char cmd[1200], out[4096] = "", out2[4096] = "";

        snprintf(cmd, sizeof cmd, "/sbin/kextload -v %s 2>&1", path);
        run(cmd, out, sizeof out);
        if (id_loaded(b->id)) return 0;

        snprintf(cmd, sizeof cmd,
                 "/usr/bin/kmutil load --no-authorization --bundle-path %s 2>&1",
                 path);
        run(cmd, out2, sizeof out2);
        if (id_loaded(b->id)) return 0;

        append_err(err, errlen, out);
        append_err(err, errlen, out2);
    }

    if (err && errlen && !*err) {
        snprintf(err, errlen,
                 "No usable kernel extension found.\n"
                 "Install Turbo Boost Switcher -- its DisableTurboBoost.64bits"
                 ".kext is the\npreferred backend -- or install our own with:"
                 " sudo ./install.sh");
    }

    if (err && errlen &&
        (strstr(err, "Bad code signature") || strstr(err, "not authentic"))) {
        size_t used = strlen(err);
        if (used < errlen) {
            snprintf(err + used, errlen - used,
                     "\n\nThat kext is unsigned and is not approved on this "
                     "machine yet.\n"
                     "  - TurboLock.kext: sudo ./install.sh --recovery\n"
                     "  - TBS kext: reinstall Turbo Boost Switcher, then retry");
        }
    }
    return -1;
}

static int unload_kext(char *err, size_t errlen) {
    const struct kext_backend *b = active_backend();
    if (!b || !id_loaded(b->id)) return 0;

    char cmd[600];
    char out[4096] = "", out2[4096] = "";

    snprintf(cmd, sizeof cmd, "/sbin/kextunload -b %s 2>&1", b->id);
    run(cmd, out, sizeof out);
    if (!id_loaded(b->id)) return 0;

    snprintf(cmd, sizeof cmd,
             "/usr/bin/kmutil unload --no-authorization --bundle-identifier %s"
             " 2>&1", b->id);
    run(cmd, out2, sizeof out2);
    if (!id_loaded(b->id)) return 0;

    if (err && errlen) snprintf(err, errlen, "%s%s", out, out2);
    return -1;
}

/* ------------------------------------------------------------ state/apply */

static void write_state(int off) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, STATE_FILE ".tmp");
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "%s\n", off ? "off" : "on");
    if (fclose(f) == 0) rename(tmp, STATE_FILE);
}

static int read_state(void) {          /* 1 = off (turbo disabled) */
    FILE *f = fopen(STATE_FILE, "r");
    if (!f) return 1;                  /* default: turbo disabled */
    char b[16] = "";
    if (!fgets(b, sizeof b, f)) b[0] = '\0';
    fclose(f);
    return strncmp(b, "off", 3) == 0;
}

/* 0 = success, -1 = error */
static int apply(int off, int echo) {
    pthread_mutex_lock(&g_lock);

    char err[8192];
    err[0] = '\0';
    int rc = off ? load_kext(err, sizeof err) : unload_kext(err, sizeof err);

    if (rc == 0) {
        write_state(off);
        logmsg(echo, "turbo %s (kext %s)", off ? "disabled" : "enabled",
               off ? "loaded" : "unloaded");
    } else {
        logmsg(1, "FAILED to turn turbo %s: %s", off ? "off" : "on", err);
    }

    pthread_mutex_unlock(&g_lock);
    return rc == 0 ? 0 : -1;
}

/* Bring reality in line with the stored state. Cheap: only shells out when
 * something actually drifted. */
static int ensure_applied(int echo) {
    int want_off = read_state();
    if (want_off && !kext_loaded())  return apply(1, echo);
    if (!want_off && kext_loaded())  return apply(0, echo);
    return 0;
}

/* After an S3 resume, "the kext is loaded" is NOT proof that turbo is still
 * off. Firmware is permitted to rewrite IA32_MISC_ENABLE while suspended, and
 * only the kext's start() ever sets bit 38 -- a kext that is merely still
 * resident will not re-apply it. So on wake we cycle the kext: unload then
 * load, which re-runs start() and rewrites the bit on every core. */
static int reapply_after_wake(int echo) {
    if (!read_state()) return 0;       /* user wants turbo on: nothing to do */

    char err[4096];
    err[0] = '\0';

    if (!kext_loaded()) return apply(1, echo);

    pthread_mutex_lock(&g_lock);
    int rc = unload_kext(err, sizeof err);
    if (rc == 0) rc = load_kext(err, sizeof err);
    if (rc == 0) logmsg(echo, "turbo disabled (re-applied after wake)");
    else         logmsg(1, "wake re-apply failed: %s", err);
    pthread_mutex_unlock(&g_lock);
    return rc == 0 ? 0 : -1;
}

/* ------------------------------------------------------- power management */

static io_connect_t          g_root_port;
static IONotificationPortRef g_notify_port;
static io_object_t           g_notifier;

static void *wake_worker(void *arg) {
    (void)arg;
    sleep(2);                 /* let power management settle after resume */
    if (reapply_after_wake(0) != 0)
        logmsg(0, "wake re-apply failed; will retry on next poll");
    return NULL;
}

static void power_callback(void *refcon, io_service_t service,
                           natural_t messageType, void *messageArgument) {
    (void)refcon;
    (void)service;
    switch (messageType) {
    case kIOMessageCanSystemSleep:
    case kIOMessageSystemWillSleep:
        IOAllowPowerChange(g_root_port, (long)messageArgument);
        break;
    case kIOMessageSystemHasPoweredOn: {
        pthread_t t;
        if (pthread_create(&t, NULL, wake_worker, NULL) == 0) pthread_detach(t);
        break;
    }
    default:
        break;
    }
}

static void *poll_worker(void *arg)   { (void)arg; ensure_applied(0); return NULL; }
static void *boot_worker(void *arg)   { (void)arg; ensure_applied(0); return NULL; }

/* A silent reset that produced no wake notification still has to be repaired,
 * and only a kext cycle rewrites the MSR. Do that every 5th tick (10 min). */
static void *deep_check_worker(void *arg) { (void)arg; reapply_after_wake(0); return NULL; }

static void poll_timer(CFRunLoopTimerRef timer, void *info) {
    static int n;
    (void)timer;
    (void)info;
    pthread_t t;
    void *(*fn)(void *) = ((++n % 5) == 0) ? deep_check_worker : poll_worker;
    if (pthread_create(&t, NULL, fn, NULL) == 0) pthread_detach(t);
}

/* --------------------------------------------------------- control socket */

static gid_t staff_gid(void) {
    struct group *g = getgrnam("staff");
    return g ? g->gr_gid : 0;
}

static void handle_line(const char *line, char *reply, size_t replylen) {
    if (strcmp(line, "off") == 0) {
        if (apply(1, 0) == 0) snprintf(reply, replylen, "ok off\n");
        else                  snprintf(reply, replylen, "error could not disable turbo\n");
    } else if (strcmp(line, "on") == 0) {
        if (apply(0, 0) == 0) snprintf(reply, replylen, "ok on\n");
        else                  snprintf(reply, replylen, "error could not enable turbo\n");
    } else if (strcmp(line, "status") == 0) {
        snprintf(reply, replylen, "ok %s\n", kext_loaded() ? "off" : "on");
    } else if (strcmp(line, "ping") == 0) {
        snprintf(reply, replylen, "ok pong\n");
    } else {
        snprintf(reply, replylen, "error unknown command\n");
    }
}

static void *listener(void *arg) {
    int fd = (int)(long)arg;
    for (;;) {
        int c = accept(fd, NULL, NULL);
        if (c < 0) {
            if (errno == EINTR) continue;
            logmsg(0, "accept: %s", strerror(errno));
            sleep(1);
            continue;
        }
        char buf[128] = "";
        ssize_t n = read(c, buf, sizeof buf - 1);
        if (n > 0) {
            buf[n] = '\0';
            char *nl = strpbrk(buf, "\r\n");
            if (nl) *nl = '\0';
            char reply[256];
            handle_line(buf, reply, sizeof reply);
            if (write(c, reply, strlen(reply)) < 0) { /* client gone */ }
        }
        close(c);
    }
    return NULL;
}

static int start_listener(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { logmsg(1, "socket: %s", strerror(errno)); return -1; }

    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strncpy(sa.sun_path, SOCK_PATH, sizeof sa.sun_path - 1);

    unlink(SOCK_PATH);
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
        logmsg(1, "bind %s: %s", SOCK_PATH, strerror(errno));
        close(fd);
        return -1;
    }
    chmod(SOCK_PATH, 0660);
    if (chown(SOCK_PATH, 0, staff_gid()) != 0)
        logmsg(0, "chown %s: %s", SOCK_PATH, strerror(errno));
    if (listen(fd, 16) != 0) {
        logmsg(1, "listen: %s", strerror(errno));
        close(fd);
        return -1;
    }

    pthread_t t;
    if (pthread_create(&t, NULL, listener, (void *)(long)fd) != 0) {
        logmsg(1, "pthread_create: %s", strerror(errno));
        close(fd);
        return -1;
    }
    pthread_detach(t);
    return 0;
}

/* ------------------------------------------------------------------- main */

static void usage(void) {
    fprintf(stderr,
            "usage: turbod [--once off|on|status] [--apply-saved] [--probe]\n"
            "       turbod                      (daemon mode)\n");
}

int main(int argc, char **argv) {
    mkdir_p(VAR_DIR);
    mkdir_p(RUN_DIR);
    umask(022);

    /* Read-only diagnostics: no root required. */
    if (argc > 1 && strcmp(argv[1], "--probe") == 0) {
        const struct kext_backend *ab = active_backend();
        printf("euid           : %d\n", (int)geteuid());
        printf("active backend : %s\n", ab ? ab->name : "NONE");
        printf("kext id        : %s\n", ab ? ab->id : "-");
        printf("kext loaded    : %s\n", kext_loaded() ? "yes" : "no");
        printf("kext on disk   : %s\n", kext_present() ? "yes" : "NO");
        printf("kext signing   : %s\n", signing_relaxed() ? "relaxed" : "enforced");
        printf("stored state   : %s\n", read_state() ? "off" : "on");
        printf("socket         : %s\n", SOCK_PATH);
        for (int i = 0; backends[i].id; i++) {
            const char *p = backend_path(&backends[i]);
            printf("candidate      : %-9s %-9s %s\n", backends[i].name,
                   id_loaded(backends[i].id) ? "loaded" : "notloaded",
                   p ? p : "(not on disk)");
        }
        return 0;
    }

    if (argc > 2 && strcmp(argv[1], "--once") == 0) {
        if (geteuid() != 0) {
            fprintf(stderr, "turbod: must be run as root\n");
            return 1;
        }
        const char *w = argv[2];
        if (strcmp(w, "off") == 0) return apply(1, 1) == 0 ? 0 : 1;
        if (strcmp(w, "on") == 0)  return apply(0, 1) == 0 ? 0 : 1;
        if (strcmp(w, "status") == 0) {
            printf("%s\n", kext_loaded() ? "off" : "on");
            return 0;
        }
        usage();
        return 2;
    }

    if (argc > 1 && strcmp(argv[1], "--apply-saved") == 0) {
        if (geteuid() != 0) {
            fprintf(stderr, "turbod: must be run as root\n");
            return 1;
        }
        return ensure_applied(1) == 0 ? 0 : 1;
    }

    if (argc > 1 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)) {
        usage();
        return 0;
    }

    /* ---------------- daemon ---------------- */
    signal(SIGPIPE, SIG_IGN);

    /* Bring the control socket up *before* touching kernel state so that a
     * slow or failing kext operation can never make the daemon unreachable. */
    if (start_listener() != 0)
        logmsg(0, "control socket unavailable; daemon still enforcing state");

    logmsg(0, "turbod starting (state=%s, kext=%s, on disk=%s, signing=%s)",
           read_state() ? "off" : "on",
           kext_loaded() ? "loaded" : "unloaded",
           kext_present() ? "yes" : "no",
           signing_relaxed() ? "relaxed" : "enforced");

    pthread_t boot;
    if (pthread_create(&boot, NULL, boot_worker, NULL) == 0) pthread_detach(boot);

    g_root_port = IORegisterForSystemPower(NULL, &g_notify_port,
                                           power_callback, &g_notifier);
    if (g_root_port) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           IONotificationPortGetRunLoopSource(g_notify_port),
                           kCFRunLoopDefaultMode);
    } else {
        logmsg(0, "IORegisterForSystemPower failed; falling back to polling only");
    }

    /* Safety net: firmware is free to restore IA32_MISC_ENABLE with no wake
     * notification at all. Cheap to check, so check periodically. */
    CFRunLoopTimerRef timer =
        CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 120.0, 120.0,
                             0, 0, poll_timer, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);

    CFRunLoopRun();
    return 0;
}
