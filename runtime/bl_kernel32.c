// kernel32 imports implemented natively. Arguments and results are guest values.
// Threads and synchronization are in bl_thread.c.
#include <copyfile.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "bl_bsp.h"
#include "bl_cocoa.h"
#include "bl_win32.h"

#define G(addr) ((void *)bl_g2h(addr))
#define U32(addr) (*(uint32_t *)bl_g2h(addr))
#define U16(addr) (*(uint16_t *)bl_g2h(addr))

static void put_str(uint32_t dst, uint32_t cap, const char *s)
{
    size_t n = strlen(s);
    if (cap) {
        size_t c = n < cap ? n : cap - 1;
        memcpy(G(dst), s, c);
        ((char *)G(dst))[c] = 0;
    }
}

// --- errors, handles, paths -------------------------------------------------

static _Thread_local uint32_t last_error;

void bl_set_last_error(uint32_t err) { last_error = err; }
uint32_t bl_k32_GetLastError_c(void) { return last_error; }
uint32_t bl_k32_SetLastError_c(uint32_t err) { last_error = err; return 0; }

uint32_t bl_errno_to_win32(int err)
{
    switch (err) {
    case ENOENT: return BL_ERROR_FILE_NOT_FOUND;
    case ENOTDIR: return BL_ERROR_PATH_NOT_FOUND;
    case EACCES: case EPERM: case EISDIR: return BL_ERROR_ACCESS_DENIED;
    case EEXIST: return BL_ERROR_FILE_EXISTS;
    case ENOMEM: return BL_ERROR_NOT_ENOUGH_MEMORY;
    case EBADF: return BL_ERROR_INVALID_HANDLE;
    case ENOSPC: case EDQUOT: return BL_ERROR_DISK_FULL;
    case ENOTEMPTY: return BL_ERROR_DIR_NOT_EMPTY;
    case EXDEV: return BL_ERROR_NOT_SAME_DEVICE;
    case ENAMETOOLONG: return BL_ERROR_FILENAME_EXCED_RANGE;
    default: return BL_ERROR_INVALID_PARAMETER;
    }
}

// errno of a call on host path `host`: ENOENT is ERROR_PATH_NOT_FOUND when the folder
// that would hold it is missing, as on Windows, and ERROR_FILE_NOT_FOUND otherwise.
static uint32_t path_error(const char *host, int err)
{
    if (err != ENOENT) return bl_errno_to_win32(err);
    char dir[1024];
    snprintf(dir, sizeof dir, "%s", host);
    size_t n = strlen(dir);
    while (n > 1 && dir[n - 1] == '/') dir[--n] = 0;  // "a/b/" names b
    char *slash = strrchr(dir, '/');
    if (!slash) return BL_ERROR_FILE_NOT_FOUND;  // in the current folder
    slash[slash == dir] = 0;  // keep "/" for a file at the root
    struct stat st;
    return stat(dir, &st) == 0 && S_ISDIR(st.st_mode) ? BL_ERROR_FILE_NOT_FOUND : BL_ERROR_PATH_NOT_FOUND;
}

#define MAX_HANDLES 4096
static struct { enum bl_handle_type type; void *obj; } handles[MAX_HANDLES];
static pthread_mutex_t handle_lock = PTHREAD_MUTEX_INITIALIZER;

// Handle values are small multiples of 4, like Windows'.
uint32_t bl_handle_new(enum bl_handle_type type, void *obj)
{
    pthread_mutex_lock(&handle_lock);
    for (uint32_t i = 1; i < MAX_HANDLES; i++)
        if (handles[i].type == BL_H_FREE) {
            handles[i].type = type;
            handles[i].obj = obj;
            pthread_mutex_unlock(&handle_lock);
            return i * 4;
        }
    bl_fatal("out of Win32 handles");
}

// Another handle to what `h` stands for (events and threads, which are never freed), or 0.
uint32_t bl_handle_dup(uint32_t h)
{
    uint32_t i = h / 4;
    pthread_mutex_lock(&handle_lock);
    int ok = h % 4 == 0 && i && i < MAX_HANDLES && handles[i].type != BL_H_FREE;
    enum bl_handle_type type = ok ? handles[i].type : BL_H_FREE;
    void *obj = ok ? handles[i].obj : NULL;
    pthread_mutex_unlock(&handle_lock);
    if (!ok) {
        bl_set_last_error(BL_ERROR_INVALID_HANDLE);
        return 0;
    }
    return bl_handle_new(type, obj);
}

void *bl_handle_get(uint32_t h, enum bl_handle_type type)
{
    uint32_t i = h / 4;
    if (h % 4 || i == 0 || i >= MAX_HANDLES || handles[i].type != type) return NULL;
    return handles[i].obj ? handles[i].obj : (void *)&handles[i];  // heaps carry no object
}

void bl_handle_free(uint32_t h)
{
    uint32_t i = h / 4;
    pthread_mutex_lock(&handle_lock);
    if (h % 4 == 0 && i < MAX_HANDLES) handles[i].type = BL_H_FREE, handles[i].obj = NULL;
    pthread_mutex_unlock(&handle_lock);
}

static char game_dir[1024];
static char cur_dir[260] = BL_WIN_ROOT;  // Windows form
static uint32_t command_line;

void bl_path_full(const char *win, char *out, size_t cap)
{
    char tmp[1024];
    if (win[0] && win[1] == ':')
        snprintf(tmp, sizeof tmp, "%s", win);
    else if (win[0] == '\\' || win[0] == '/')
        snprintf(tmp, sizeof tmp, "C:%s", win);
    else
        snprintf(tmp, sizeof tmp, "%s\\%s", cur_dir, win);
    // Normalize separators and resolve "." and "..".
    char *parts[128];
    int np = 0;
    for (char *s = tmp; *s; s++)
        if (*s == '/') *s = '\\';
    char *save, *tok = strtok_r(tmp + 2, "\\", &save);
    for (; tok; tok = strtok_r(NULL, "\\", &save)) {
        if (!strcmp(tok, ".")) continue;
        if (!strcmp(tok, "..")) { if (np) np--; continue; }
        if (np < 128) parts[np++] = tok;
    }
    size_t len = (size_t)snprintf(out, cap, "%c:", toupper((unsigned char)tmp[0]));
    for (int i = 0; i < np && len < cap; i++) len += (size_t)snprintf(out + len, cap - len, "\\%s", parts[i]);
    if (np == 0 && len < cap) snprintf(out + len, cap - len, "\\");
}

// Saves and settings live outside the game folder, per mod folder, in
// ~/Library/Application Support/Vampire The Masquerade - Bloodlines (BL_DATA_DIR,
// "off" keeps them in the game folder):
//   \<mod>\save\...         -> <data>/<mod>/save/...
//   \<mod>\cfg\config.cfg   -> <data>/<mod>/cfg/config.cfg
// Existing saves and config.cfg are copied there on the first start.
static char data_dir[1024];

const char *bl_data_dir(void) { return data_dir; }

static void make_data_dirs(const char *mod)
{
    static char last[256];
    if (!strcasecmp(last, mod)) return;
    snprintf(last, sizeof last, "%s", mod);
    char p[1300];
    mkdir(data_dir, 0755);
    snprintf(p, sizeof p, "%s/%s", data_dir, mod);
    mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/%s/save", data_dir, mod);
    mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/%s/cfg", data_dir, mod);
    mkdir(p, 0755);
}

// `rest` is the path below the game folder, starting with a backslash.
static int data_path(const char *rest, char *host, size_t cap)
{
    if (!data_dir[0] || rest[0] != '\\') return 0;
    const char *mod = rest + 1, *sub = strchr(mod, '\\');
    if (!sub || sub == mod || (size_t)(sub - mod) >= 256) return 0;
    sub++;
    const char *tail;
    if (!strncasecmp(sub, "save", 4) && (sub[4] == 0 || sub[4] == '\\'))
        tail = sub + 4;
    else if (!strcasecmp(sub, "cfg\\config.cfg"))
        tail = NULL;
    else
        return 0;
    char name[256];
    snprintf(name, sizeof name, "%.*s", (int)(sub - 1 - mod), mod);
    make_data_dirs(name);
    size_t n = tail ? (size_t)snprintf(host, cap, "%s/%s/save%s", data_dir, name, tail)
                    : (size_t)snprintf(host, cap, "%s/%s/cfg/config.cfg", data_dir, name);
    if (n >= cap) return 0;
    for (char *s = host + strlen(data_dir); *s; s++)
        if (*s == '\\') *s = '/';
    return 1;
}

static void migrate_data(void)
{
    const char *env = getenv("BL_DATA_DIR"), *home = getenv("HOME");
    if (env && !strcmp(env, "off")) return;
    if (env && *env)
        snprintf(data_dir, sizeof data_dir, "%s", env);
    else if (home)
        snprintf(data_dir, sizeof data_dir, "%s/Library/Application Support/Vampire The Masquerade - Bloodlines", home);
    else
        return;
    DIR *d = opendir(game_dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.' || e->d_type != DT_DIR) continue;
        char from[1300], to[1300];
        struct stat st;
        static const char *const items[2] = {"save", "cfg/config.cfg"};
        for (int i = 0; i < 2; i++) {
            snprintf(from, sizeof from, "%s/%s/%s", game_dir, e->d_name, items[i]);
            if (stat(from, &st)) continue;
            snprintf(to, sizeof to, "%s/%s/%s", data_dir, e->d_name, items[i]);
            struct stat dst;
            int fresh = stat(to, &dst) != 0;
            if (i == 0 && !fresh && S_ISDIR(dst.st_mode)) {  // created empty by an earlier run?
                DIR *sd = opendir(to);
                struct dirent *se;
                fresh = 1;
                while (sd && (se = readdir(sd)))
                    if (se->d_name[0] != '.') { fresh = 0; break; }
                if (sd) closedir(sd);
            }
            if (!fresh) continue;
            make_data_dirs(e->d_name);
            if (i == 0) rmdir(to);  // copyfile would copy into an existing folder, not onto it
            if (copyfile(from, to, NULL, COPYFILE_ALL | (i == 0 ? COPYFILE_RECURSIVE : 0)) == 0)
                fprintf(stderr, "[files] copied %s/%s to %s\n", e->d_name, items[i], data_dir);
        }
    }
    closedir(d);
}

int bl_path_to_host(const char *win, char *host, size_t cap)
{
    char full[1024];
    bl_path_full(win, full, sizeof full);
    size_t rl = strlen(BL_WIN_ROOT);
    const char *rest;
    if (!strncasecmp(full, BL_WIN_ROOT, rl) && (full[rl] == '\\' || full[rl] == 0))
        rest = full + rl;
    else
        rest = full + 2;  // other folders and drives: also under the game directory
    const char *last = strrchr(rest, '\\');
    if (last && !strcasecmp(last + 1, "nul")) {  // the null device, not a file called nul
        snprintf(host, cap, "/dev/null");
        return 1;
    }
    if (data_path(rest, host, cap)) return 1;
    size_t n = (size_t)snprintf(host, cap, "%s%s", game_dir, rest);
    if (n >= cap) return 0;
    for (char *s = host + strlen(game_dir); *s; s++)
        if (*s == '\\') *s = '/';
    return 1;
}

uint32_t bl_k32_GetCurrentDirectoryA_c(uint32_t len, uint32_t buf)
{
    uint32_t n = (uint32_t)strlen(cur_dir);
    if (len <= n) return n + 1;
    put_str(buf, len, cur_dir);
    return n;
}

uint32_t bl_k32_SetCurrentDirectoryA_c(uint32_t path)
{
    char full[260], host[1024];
    struct stat st;
    bl_path_full(G(path), full, sizeof full);
    if (!bl_path_to_host(full, host, sizeof host) || stat(host, &st) || !S_ISDIR(st.st_mode)) {
        bl_set_last_error(BL_ERROR_PATH_NOT_FOUND);
        return 0;
    }
    snprintf(cur_dir, sizeof cur_dir, "%s", full);
    return 1;
}

uint32_t bl_k32_GetFullPathNameA_c(uint32_t name, uint32_t len, uint32_t buf, uint32_t file_part)
{
    char full[1024];
    bl_path_full(G(name), full, sizeof full);
    uint32_t n = (uint32_t)strlen(full);
    if (len <= n) return n + 1;
    put_str(buf, len, full);
    if (file_part) {
        char *slash = strrchr(full, '\\');
        U32(file_part) = slash && slash[1] ? buf + (uint32_t)(slash + 1 - full) : 0;
    }
    return n;
}

uint32_t bl_k32_GetDriveTypeA_c(uint32_t root)
{
    (void)root;
    return 3;  // DRIVE_FIXED
}

// --- files ------------------------------------------------------------------

struct file { int fd; int pipe; };

#define STD_BASE 0x10000000u  // GetStdHandle values, distinct from table handles
static uint32_t std_handles[3] = { STD_BASE, STD_BASE + 4, STD_BASE + 8 };

static int file_fd(uint32_t h)
{
    if (h >= STD_BASE && h < STD_BASE + 12 && h % 4 == 0) return (int)((h - STD_BASE) / 4);
    struct file *f = bl_handle_get(h, BL_H_FILE);
    return f ? f->fd : -1;
}

uint32_t bl_k32_GetStdHandle_c(uint32_t which)
{
    int i = -(int32_t)which - 10;  // STD_INPUT_HANDLE = -10 ... STD_ERROR_HANDLE = -12
    return i >= 0 && i < 3 ? std_handles[i] : BL_INVALID_HANDLE;
}

uint32_t bl_k32_SetStdHandle_c(uint32_t which, uint32_t h)
{
    int i = -(int32_t)which - 10;
    if (i < 0 || i >= 3) return 0;
    std_handles[i] = h;
    return 1;
}

uint32_t bl_k32_GetFileType_c(uint32_t h)
{
    int fd = file_fd(h);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) return 0;  // FILE_TYPE_UNKNOWN
    return S_ISREG(st.st_mode) || S_ISDIR(st.st_mode) ? 1 : S_ISFIFO(st.st_mode) ? 3 : 2;
}

#define SKIP_INTRO_KEY "HKCU\\Software\\Troika\\Vampire\\Native"
int bl_skip_intro_movies(void) { return bl_reg_get_dword(SKIP_INTRO_KEY, "SkipIntroMovies", 0) != 0; }

void bl_skip_intro_movies_set(int on)
{
    bl_reg_set_dword(SKIP_INTRO_KEY, "SkipIntroMovies", on != 0);
    fprintf(stderr, "[movies] intro movies %s\n", on ? "skipped" : "played");
}

// A Bink movie in the game's media folder: the intro movies, the only ones there.
static int intro_movie(const char *host)
{
    size_t n = strlen(host);
    const char *slash = strrchr(host, '/');
    return n > 4 && !strcasecmp(host + n - 4, ".bik") && slash && slash - host >= 6 &&
           !strncasecmp(slash - 6, "/media", 6);
}

uint32_t bl_k32_CreateFileA_c(uint32_t name, uint32_t access, uint32_t share, uint32_t sec, uint32_t disposition,
                              uint32_t flags, uint32_t tmpl)
{
    (void)share, (void)sec, (void)tmpl;
    char host[1024];
    if (!bl_path_to_host(G(name), host, sizeof host)) {
        bl_set_last_error(BL_ERROR_PATH_NOT_FOUND);
        return BL_INVALID_HANDLE;
    }
    // BinkOpen then fails, and the engine goes on to the next movie, then the menu.
    if (intro_movie(host) && bl_skip_intro_movies()) {
        bl_set_last_error(BL_ERROR_FILE_NOT_FOUND);
        return BL_INVALID_HANDLE;
    }
    int rd = (access & 0x80000000u) != 0, wr = (access & 0x40000000u) != 0;
    int oflags = wr ? (rd ? O_RDWR : O_WRONLY) : O_RDONLY;
    switch (disposition) {
    case 1: oflags |= O_CREAT | O_EXCL; break;   // CREATE_NEW
    case 2: oflags |= O_CREAT | O_TRUNC; break;  // CREATE_ALWAYS
    case 3: break;                               // OPEN_EXISTING
    case 4: oflags |= O_CREAT; break;            // OPEN_ALWAYS
    case 5: oflags |= O_TRUNC; break;            // TRUNCATE_EXISTING
    default: bl_set_last_error(BL_ERROR_INVALID_PARAMETER); return BL_INVALID_HANDLE;
    }
    struct stat st;
    int existed = stat(host, &st) == 0;
    if (existed && S_ISDIR(st.st_mode)) {
        // Windows opens a folder only with FILE_FLAG_BACKUP_SEMANTICS; the file system
        // tries "sound\" as a file and must be refused, as on Windows.
        if (!(flags & 0x02000000u)) {
            bl_set_last_error(BL_ERROR_ACCESS_DENIED);
            return BL_INVALID_HANDLE;
        }
        oflags = O_RDONLY;
    }
    int fd = open(host, oflags | O_CLOEXEC, 0644);
    if (fd < 0) {
        bl_set_last_error(path_error(host, errno));
        return BL_INVALID_HANDLE;
    }
    if (!wr) bl_bsp_note_open(host);  // a map: its lights, for the volumetric lighting
    struct file *f = calloc(1, sizeof *f);
    f->fd = fd;
    bl_set_last_error(existed && (disposition == 2 || disposition == 4) ? BL_ERROR_ALREADY_EXISTS : 0);
    return bl_handle_new(BL_H_FILE, f);
}

uint32_t bl_k32_ReadFile_c(uint32_t h, uint32_t buf, uint32_t n, uint32_t nread, uint32_t ov)
{
    (void)ov;
    int fd = file_fd(h);
    if (fd < 0) { bl_set_last_error(BL_ERROR_INVALID_HANDLE); return 0; }
    uint32_t done = 0;
    while (done < n) {
        ssize_t r = read(fd, (char *)G(buf) + done, n - done);
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) { bl_set_last_error(bl_errno_to_win32(errno)); if (nread) U32(nread) = done; return 0; }
        if (r == 0) break;
        done += (uint32_t)r;
        if (h < STD_BASE || h >= STD_BASE + 12) {
            struct file *f = bl_handle_get(h, BL_H_FILE);
            if (f && f->pipe) break;  // a pipe read returns what is there
        }
    }
    if (nread) U32(nread) = done;
    return 1;
}

uint32_t bl_k32_WriteFile_c(uint32_t h, uint32_t buf, uint32_t n, uint32_t nwritten, uint32_t ov)
{
    (void)ov;
    int fd = file_fd(h);
    if (fd < 0) { bl_set_last_error(BL_ERROR_INVALID_HANDLE); return 0; }
    uint32_t done = 0;
    while (done < n) {
        ssize_t r = write(fd, (const char *)G(buf) + done, n - done);
        if (r < 0 && errno == EINTR) continue;
        if (r < 0 && errno == EAGAIN) break;  // full pipe nobody drains: drop the rest
        if (r < 0) { bl_set_last_error(bl_errno_to_win32(errno)); if (nwritten) U32(nwritten) = done; return 0; }
        done += (uint32_t)r;
    }
    if (nwritten) U32(nwritten) = done;
    return 1;
}

// Anonymous pipes. The write end does not block: the game writes and reads its pipes
// from one thread (Python's console output), so a full pipe drops data instead.
uint32_t bl_k32_CloseHandle_c(uint32_t h);

static uint32_t pipe_end(int fd)
{
    struct file *f = calloc(1, sizeof *f);
    f->fd = fd;
    f->pipe = 1;
    return bl_handle_new(BL_H_FILE, f);
}

uint32_t bl_k32_CreatePipe_c(uint32_t prd, uint32_t pwr, uint32_t sec, uint32_t size)
{
    (void)sec, (void)size;
    int fds[2];
    if (pipe(fds)) { bl_set_last_error(bl_errno_to_win32(errno)); return 0; }
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFL, O_NONBLOCK);
    U32(prd) = pipe_end(fds[0]);
    U32(pwr) = pipe_end(fds[1]);
    return 1;
}

uint32_t bl_k32_PeekNamedPipe_c(uint32_t h, uint32_t buf, uint32_t size, uint32_t pread, uint32_t pavail,
                                uint32_t pleft)
{
    int fd = file_fd(h), avail = 0;
    if (fd < 0 || ioctl(fd, FIONREAD, &avail)) { bl_set_last_error(BL_ERROR_INVALID_HANDLE); return 0; }
    uint32_t got = 0;
    if (buf && size && avail > 0) {
        // Peeking without consuming is not possible on a POSIX pipe; nothing reads this way here.
        bl_fatal("PeekNamedPipe with a buffer");
    }
    if (pread) U32(pread) = got;
    if (pavail) U32(pavail) = (uint32_t)avail;
    if (pleft) U32(pleft) = 0;
    return 1;
}

uint32_t bl_k32_DuplicateHandle_c(uint32_t sproc, uint32_t h, uint32_t tproc, uint32_t out, uint32_t access,
                                  uint32_t inherit, uint32_t options)
{
    (void)sproc, (void)tproc, (void)access, (void)inherit;
    // GetCurrentProcess()'s handle stands for the process wherever it is; GetCurrentThread()'s
    // becomes a real handle to the thread (one that works from other threads too).
    if (h == 0xffffffffu) {
        if (out) U32(out) = h;
        return 1;
    }
    if (h == 0xfffffffeu) {
        uint32_t t = bl_thread_current_handle();
        if (out) U32(out) = t;
        return t != 0;
    }
    if (bl_handle_get(h, BL_H_THREAD) || bl_handle_get(h, BL_H_EVENT)) {
        uint32_t d = bl_handle_dup(h);
        if (out) U32(out) = d;
        if (d && (options & 1)) bl_k32_CloseHandle_c(h);  // DUPLICATE_CLOSE_SOURCE
        return d != 0;
    }
    int fd = file_fd(h);
    if (fd < 0) { bl_set_last_error(BL_ERROR_INVALID_HANDLE); return 0; }
    int nfd = dup(fd);
    if (nfd < 0) { bl_set_last_error(bl_errno_to_win32(errno)); return 0; }
    fcntl(nfd, F_SETFD, FD_CLOEXEC);
    struct file *src = h >= STD_BASE && h < STD_BASE + 12 ? NULL : bl_handle_get(h, BL_H_FILE);
    struct file *f = calloc(1, sizeof *f);
    f->fd = nfd;
    f->pipe = src && src->pipe;
    if (out) U32(out) = bl_handle_new(BL_H_FILE, f);
    if (options & 1) bl_k32_CloseHandle_c(h);  // DUPLICATE_CLOSE_SOURCE
    return 1;
}

uint32_t bl_k32_SetFilePointer_c(uint32_t h, uint32_t lo, uint32_t phigh, uint32_t method)
{
    int fd = file_fd(h);
    if (fd < 0) { bl_set_last_error(BL_ERROR_INVALID_HANDLE); return 0xffffffffu; }
    int64_t off = phigh ? (int64_t)(((uint64_t)U32(phigh) << 32) | lo) : (int64_t)(int32_t)lo;
    off_t r = lseek(fd, off, method == 0 ? SEEK_SET : method == 1 ? SEEK_CUR : SEEK_END);
    if (r < 0) { bl_set_last_error(BL_ERROR_INVALID_PARAMETER); return 0xffffffffu; }
    if (phigh) U32(phigh) = (uint32_t)((uint64_t)r >> 32);
    bl_set_last_error(0);
    return (uint32_t)r;
}

uint32_t bl_k32_SetEndOfFile_c(uint32_t h)
{
    int fd = file_fd(h);
    off_t pos = fd < 0 ? -1 : lseek(fd, 0, SEEK_CUR);
    if (pos < 0 || ftruncate(fd, pos)) { bl_set_last_error(BL_ERROR_INVALID_HANDLE); return 0; }
    return 1;
}

uint32_t bl_k32_FlushFileBuffers_c(uint32_t h)
{
    return file_fd(h) >= 0;
}

uint32_t bl_k32_CloseHandle_c(uint32_t h)
{
    struct file *f = bl_handle_get(h, BL_H_FILE);
    if (f) {
        close(f->fd);
        free(f);
    } else if (bl_sync_close(h)) {
        return 1;
    } else if (h >= STD_BASE && h < STD_BASE + 12) {
        return 1;
    } else {
        bl_set_last_error(BL_ERROR_INVALID_HANDLE);
        return 0;
    }
    bl_handle_free(h);
    return 1;
}

// The result of a call on host path `host` (0 succeeded, else errno says why).
static uint32_t path_op_result(const char *host, int r)
{
    if (r == 0) return 1;
    bl_set_last_error(path_error(host, errno));
    return 0;
}

// A path with no place under the game directory.
static uint32_t bad_path(void)
{
    bl_set_last_error(BL_ERROR_PATH_NOT_FOUND);
    return 0;
}

uint32_t bl_k32_DeleteFileA_c(uint32_t name)
{
    char host[1024];
    return bl_path_to_host(G(name), host, sizeof host) ? path_op_result(host, unlink(host)) : bad_path();
}

uint32_t bl_k32_MoveFileA_c(uint32_t from, uint32_t to)
{
    char a[1024], b[1024];
    struct stat st;
    if (!bl_path_to_host(G(from), a, sizeof a) || !bl_path_to_host(G(to), b, sizeof b)) return bad_path();
    if (stat(b, &st) == 0) { bl_set_last_error(BL_ERROR_ALREADY_EXISTS); return 0; }
    // A missing destination folder is the destination's error, anything else the source's.
    if (rename(a, b) == 0) return 1;
    int err = errno;
    bl_set_last_error(err == ENOENT && access(a, F_OK) == 0 ? path_error(b, err) : path_error(a, err));
    return 0;
}

uint32_t bl_k32_CreateDirectoryA_c(uint32_t name, uint32_t sec)
{
    (void)sec;
    char host[1024];
    if (!bl_path_to_host(G(name), host, sizeof host)) return bad_path();
    if (mkdir(host, 0755) == 0) return 1;
    bl_set_last_error(errno == EEXIST ? BL_ERROR_ALREADY_EXISTS : path_error(host, errno));
    return 0;
}

// --- FindFirstFile ------------------------------------------------------------

struct find {
    DIR *dir;
    char dir_path[1024];
    char pattern[260];
};

static uint64_t unix_to_filetime(time_t t, long nsec)
{
    return (uint64_t)t * 10000000ull + (uint64_t)nsec / 100 + 116444736000000000ull;
}

static void put_filetime(uint32_t at, uint64_t ft)
{
    U32(at) = (uint32_t)ft;
    U32(at + 4) = (uint32_t)(ft >> 32);
}

// Fills WIN32_FIND_DATAA from the next matching entry; 0 when there is none.
static int find_next(struct find *f, uint32_t data)
{
    struct dirent *de;
    int all = !strcmp(f->pattern, "*.*") || !strcmp(f->pattern, "*");  // "*.*" also matches names without a dot
    while ((de = readdir(f->dir))) {
        if (!all && fnmatch(f->pattern, de->d_name, FNM_CASEFOLD)) continue;
        char path[2048];
        struct stat st;
        snprintf(path, sizeof path, "%s/%s", f->dir_path, de->d_name);
        if (stat(path, &st)) continue;
        memset(G(data), 0, 320);
        U32(data) = S_ISDIR(st.st_mode) ? 0x10 : 0x80;  // DIRECTORY / NORMAL
        put_filetime(data + 4, unix_to_filetime(st.st_birthtimespec.tv_sec, st.st_birthtimespec.tv_nsec));
        put_filetime(data + 12, unix_to_filetime(st.st_atimespec.tv_sec, st.st_atimespec.tv_nsec));
        put_filetime(data + 20, unix_to_filetime(st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec));
        U32(data + 28) = (uint32_t)((uint64_t)st.st_size >> 32);
        U32(data + 32) = (uint32_t)st.st_size;
        put_str(data + 44, 260, de->d_name);
        return 1;
    }
    return 0;
}

uint32_t bl_k32_FindFirstFileA_c(uint32_t name, uint32_t data)
{
    char win[1024], host[1024];
    snprintf(win, sizeof win, "%s", (const char *)G(name));
    char *sep = strrchr(win, '\\'), *sep2 = strrchr(win, '/');
    if (sep2 > sep) sep = sep2;
    struct find *f = calloc(1, sizeof *f);
    snprintf(f->pattern, sizeof f->pattern, "%s", sep ? sep + 1 : win);
    if (sep)
        *sep = 0;
    else
        snprintf(win, sizeof win, ".");
    if (!bl_path_to_host(win[0] ? win : "\\", host, sizeof host) || !(f->dir = opendir(host))) {
        free(f);
        bl_set_last_error(BL_ERROR_PATH_NOT_FOUND);
        return BL_INVALID_HANDLE;
    }
    snprintf(f->dir_path, sizeof f->dir_path, "%s", host);
    if (!find_next(f, data)) {
        closedir(f->dir);
        free(f);
        bl_set_last_error(BL_ERROR_FILE_NOT_FOUND);
        return BL_INVALID_HANDLE;
    }
    return bl_handle_new(BL_H_FIND, f);
}

uint32_t bl_k32_FindNextFileA_c(uint32_t h, uint32_t data)
{
    struct find *f = bl_handle_get(h, BL_H_FIND);
    if (!f) { bl_set_last_error(BL_ERROR_INVALID_HANDLE); return 0; }
    if (find_next(f, data)) return 1;
    bl_set_last_error(BL_ERROR_NO_MORE_FILES);
    return 0;
}

uint32_t bl_k32_FindClose_c(uint32_t h)
{
    struct find *f = bl_handle_get(h, BL_H_FIND);
    if (!f) return 0;
    closedir(f->dir);
    free(f);
    bl_handle_free(h);
    return 1;
}

// --- memory -------------------------------------------------------------------

#define HEAP_ZERO_MEMORY 0x08
#define HEAP_REALLOC_IN_PLACE_ONLY 0x10

// One shared guest heap behind every heap handle.
uint32_t bl_k32_HeapCreate_c(uint32_t opts, uint32_t initial, uint32_t max)
{
    (void)opts, (void)initial, (void)max;
    return bl_handle_new(BL_H_HEAP, NULL);
}

uint32_t bl_k32_HeapDestroy_c(uint32_t heap)
{
    bl_handle_free(heap);
    return 1;
}

uint32_t bl_k32_HeapAlloc_c(uint32_t heap, uint32_t flags, uint32_t size)
{
    (void)heap;
    uint32_t p = flags & HEAP_ZERO_MEMORY ? bl_guest_calloc(1, size) : bl_guest_malloc(size);
    if (!p) bl_set_last_error(BL_ERROR_NOT_ENOUGH_MEMORY);
    return p;
}

uint32_t bl_k32_HeapFree_c(uint32_t heap, uint32_t flags, uint32_t p)
{
    (void)heap, (void)flags;
    bl_guest_free(p);
    return 1;
}

uint32_t bl_k32_HeapReAlloc_c(uint32_t heap, uint32_t flags, uint32_t p, uint32_t size)
{
    (void)heap;
    // In place only: a block too small for the new size fails and stays where it is.
    if ((flags & HEAP_REALLOC_IN_PLACE_ONLY) && (!p || !bl_guest_fits(p, size))) {
        bl_set_last_error(BL_ERROR_NOT_ENOUGH_MEMORY);
        return 0;
    }
    uint32_t old = bl_guest_size(p);
    uint32_t n = bl_guest_realloc(p, size);  // stays in place whenever the block fits
    if (!n) {
        bl_set_last_error(BL_ERROR_NOT_ENOUGH_MEMORY);
        return 0;
    }
    if ((flags & HEAP_ZERO_MEMORY) && size > old) memset((char *)G(n) + old, 0, size - old);
    return n;
}

uint32_t bl_k32_HeapSize_c(uint32_t heap, uint32_t flags, uint32_t p)
{
    (void)heap, (void)flags;
    return bl_guest_size(p);
}

// VirtualAlloc: reservations are zeroed, 64 KiB aligned blocks of the guest heap;
// committing inside a reservation is a no-op.
#define MAX_REGIONS 1024
static struct { uint32_t base, size, block; } regions[MAX_REGIONS];
static pthread_mutex_t region_lock = PTHREAD_MUTEX_INITIALIZER;

static uint32_t virtual_alloc(uint32_t addr, uint32_t size, uint32_t type, uint32_t protect)
{
    (void)protect;
    if (addr) {
        for (int i = 0; i < MAX_REGIONS; i++)
            if (regions[i].size && addr >= regions[i].base && addr - regions[i].base < regions[i].size)
                return addr & ~0xfffu;
        bl_set_last_error(BL_ERROR_INVALID_PARAMETER);  // fixed addresses outside our reservations
        return 0;
    }
    (void)type;
    uint32_t len = (size + 0xffffu) & ~0xffffu;  // size <= 0xffff0000: does not wrap
    if ((uint64_t)len + 0x10000u > UINT32_MAX) { bl_set_last_error(BL_ERROR_NOT_ENOUGH_MEMORY); return 0; }
    uint32_t block = bl_guest_malloc(len + 0x10000u);
    if (!block) { bl_set_last_error(BL_ERROR_NOT_ENOUGH_MEMORY); return 0; }
    uint32_t base = (block + 0xffffu) & ~0xffffu;
    memset(G(base), 0, len);
    for (int i = 0; i < MAX_REGIONS; i++)
        if (!regions[i].size) {
            regions[i].base = base, regions[i].size = len, regions[i].block = block;
            return base;
        }
    bl_fatal("too many VirtualAlloc regions");
}

static uint32_t virtual_free(uint32_t addr, uint32_t size, uint32_t type)
{
    (void)size;
    if (!(type & 0x8000)) return 1;  // MEM_DECOMMIT: keep the memory
    for (int i = 0; i < MAX_REGIONS; i++)
        if (regions[i].size && regions[i].base == addr) {
            bl_guest_free(regions[i].block);
            regions[i].size = 0;
            return 1;
        }
    bl_set_last_error(BL_ERROR_INVALID_PARAMETER);
    return 0;
}

uint32_t bl_k32_VirtualAlloc_c(uint32_t addr, uint32_t size, uint32_t type, uint32_t protect)
{
    if (size == 0 || size > 0xffff0000u) {  // nothing, or so big the page rounding wraps
        bl_set_last_error(BL_ERROR_INVALID_PARAMETER);
        return 0;
    }
    pthread_mutex_lock(&region_lock);
    uint32_t r = virtual_alloc(addr, size, type, protect);
    pthread_mutex_unlock(&region_lock);
    return r;
}

uint32_t bl_k32_VirtualFree_c(uint32_t addr, uint32_t size, uint32_t type)
{
    pthread_mutex_lock(&region_lock);
    uint32_t r = virtual_free(addr, size, type);
    pthread_mutex_unlock(&region_lock);
    return r;
}

uint32_t bl_k32_IsBadWritePtr_c(uint32_t p, uint32_t n)
{
    (void)n;
    return p == 0;
}

// TLS slots, per host thread. Each allocation of a slot bumps its generation; a value
// stored under an older one reads as 0, so a reused index starts at 0 in every thread,
// as on Windows.
#define TLS_SLOTS 64
static uint8_t tls_used[TLS_SLOTS];
static uint32_t tls_gen[TLS_SLOTS];
static pthread_mutex_t tls_lock = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local struct { uint32_t gen, value; } tls_values[TLS_SLOTS];

uint32_t bl_k32_TlsAlloc_c(void)
{
    pthread_mutex_lock(&tls_lock);
    for (uint32_t i = 0; i < TLS_SLOTS; i++)
        if (!tls_used[i]) {
            tls_used[i] = 1;
            __atomic_add_fetch(&tls_gen[i], 1, __ATOMIC_RELEASE);
            pthread_mutex_unlock(&tls_lock);
            return i;
        }
    pthread_mutex_unlock(&tls_lock);
    bl_set_last_error(259);  // ERROR_NO_MORE_ITEMS
    return 0xffffffffu;  // TLS_OUT_OF_INDEXES
}

uint32_t bl_k32_TlsFree_c(uint32_t i)
{
    pthread_mutex_lock(&tls_lock);
    int ok = i < TLS_SLOTS && tls_used[i];
    if (ok) tls_used[i] = 0;
    pthread_mutex_unlock(&tls_lock);
    if (!ok) bl_set_last_error(BL_ERROR_INVALID_PARAMETER);
    return ok;
}

uint32_t bl_k32_TlsGetValue_c(uint32_t i)
{
    if (i >= TLS_SLOTS) {
        bl_set_last_error(BL_ERROR_INVALID_PARAMETER);
        return 0;
    }
    bl_set_last_error(0);
    uint32_t gen = __atomic_load_n(&tls_gen[i], __ATOMIC_ACQUIRE);
    return tls_values[i].gen == gen ? tls_values[i].value : 0;
}

uint32_t bl_k32_TlsSetValue_c(uint32_t i, uint32_t v)
{
    if (i >= TLS_SLOTS) {
        bl_set_last_error(BL_ERROR_INVALID_PARAMETER);
        return 0;
    }
    tls_values[i].gen = __atomic_load_n(&tls_gen[i], __ATOMIC_ACQUIRE);
    tls_values[i].value = v;
    return 1;
}

// --- process, environment, system ---------------------------------------------

uint32_t bl_k32_GetCurrentProcess_c(void) { return 0xffffffffu; }
uint32_t bl_k32_GetCurrentThread_c(void) { return 0xfffffffeu; }
uint32_t bl_k32_GetCurrentProcessId_c(void) { return (uint32_t)getpid(); }

// GetCurrentThreadId is in bl_thread.c, with the ids CreateThread hands out.

uint32_t bl_k32_ExitProcess_c(uint32_t code)
{
    fflush(stdout);
    exit((int)code);
}

uint32_t bl_k32_TerminateProcess_c(uint32_t h, uint32_t code)
{
    if (h == 0xffffffffu) bl_k32_ExitProcess_c(code);
    return 0;
}

uint32_t bl_k32_FatalAppExitA_c(uint32_t action, uint32_t msg)
{
    (void)action;
    bl_fatal("FatalAppExit: %s", msg ? (const char *)G(msg) : "");
}

uint32_t bl_k32_UnhandledExceptionFilter_c(uint32_t info)
{
    uint32_t rec = info ? U32(info) : 0;
    bl_fatal("unhandled guest exception 0x%08x at 0x%08x", rec ? U32(rec) : 0, rec ? U32(rec + 12) : 0);
}

uint32_t bl_k32_OutputDebugStringA_c(uint32_t s)
{
    fprintf(stderr, "[debug] %s", s ? (const char *)G(s) : "");
    return 0;
}

uint32_t bl_k32_GetCommandLineA_c(void) { return command_line; }

uint32_t bl_k32_GetStartupInfoA_c(uint32_t si)
{
    memset(G(si), 0, 68);
    U32(si) = 68;
    return 0;
}

uint32_t bl_k32_SetHandleCount_c(uint32_t n) { return n; }

uint32_t bl_k32_SetConsoleCtrlHandler_c(uint32_t fn, uint32_t add)
{
    (void)fn, (void)add;
    return 1;
}

uint32_t bl_k32_GetNumberOfConsoleInputEvents_c(uint32_t h, uint32_t n)
{
    (void)h;
    if (n) U32(n) = 0;
    return 1;
}

uint32_t bl_k32_ReadConsoleInputA_c(uint32_t h, uint32_t buf, uint32_t len, uint32_t n)
{
    (void)h, (void)buf, (void)len;
    if (n) U32(n) = 0;
    return 1;
}

// Environment: the game sees an empty environment plus what it sets itself (any thread).
#define MAX_ENV 64
static char *env_names[MAX_ENV], *env_values[MAX_ENV];
static pthread_mutex_t env_lock = PTHREAD_MUTEX_INITIALIZER;

uint32_t bl_k32_GetEnvironmentStrings_c(void) { return bl_guest_calloc(1, 4); }
uint32_t bl_k32_GetEnvironmentStringsW_c(void) { return bl_guest_calloc(1, 4); }
uint32_t bl_k32_FreeEnvironmentStringsA_c(uint32_t p) { bl_guest_free(p); return 1; }
uint32_t bl_k32_FreeEnvironmentStringsW_c(uint32_t p) { bl_guest_free(p); return 1; }

uint32_t bl_k32_GetEnvironmentVariableA_c(uint32_t name, uint32_t buf, uint32_t size)
{
    pthread_mutex_lock(&env_lock);
    for (int i = 0; i < MAX_ENV; i++)
        if (env_names[i] && !strcasecmp(env_names[i], G(name))) {
            uint32_t n = (uint32_t)strlen(env_values[i]);
            if (size > n) put_str(buf, size, env_values[i]);
            pthread_mutex_unlock(&env_lock);
            return size <= n ? n + 1 : n;
        }
    pthread_mutex_unlock(&env_lock);
    bl_set_last_error(BL_ERROR_ENVVAR_NOT_FOUND);
    return 0;
}

static uint32_t set_env(uint32_t name, uint32_t value);
uint32_t bl_k32_SetEnvironmentVariableA_c(uint32_t name, uint32_t value)
{
    pthread_mutex_lock(&env_lock);
    uint32_t r = set_env(name, value);
    pthread_mutex_unlock(&env_lock);
    return r;
}

static uint32_t set_env(uint32_t name, uint32_t value)
{
    int slot = -1;
    for (int i = 0; i < MAX_ENV; i++) {
        if (env_names[i] && !strcasecmp(env_names[i], G(name))) {
            slot = i;
            break;
        }
        if (!env_names[i] && slot < 0) slot = i;
    }
    if (slot < 0) return 0;
    free(env_values[slot]);
    env_values[slot] = NULL;
    if (!value) {
        free(env_names[slot]);
        env_names[slot] = NULL;
        return 1;
    }
    if (!env_names[slot]) env_names[slot] = strdup(G(name));
    env_values[slot] = strdup(G(value));
    return 1;
}

uint32_t bl_k32_GetVersion_c(void) { return 0x0a280105u; }  // Windows XP, build 2600

uint32_t bl_k32_GetVersionExA_c(uint32_t info)
{
    uint32_t size = U32(info);
    memset((char *)G(info) + 4, 0, size > 4 ? size - 4 : 0);
    U32(info + 4) = 5;      // major
    U32(info + 8) = 1;      // minor
    U32(info + 12) = 2600;  // build
    U32(info + 16) = 2;     // VER_PLATFORM_WIN32_NT
    return 1;
}

uint32_t bl_k32_GetSystemInfo_c(uint32_t si)
{
    memset(G(si), 0, 36);
    U32(si + 4) = 4096;
    U32(si + 8) = 0x10000;
    U32(si + 12) = 0x7ffeffff;
    U32(si + 16) = 1;
    U32(si + 20) = 1;
    U32(si + 24) = 586;  // PROCESSOR_INTEL_PENTIUM
    U32(si + 28) = 0x10000;
    U16(si + 32) = 15;
    return 0;
}

// --- time -----------------------------------------------------------------------

static void put_systemtime(uint32_t st, const struct tm *tm, long ms)
{
    uint16_t v[8] = { (uint16_t)(tm->tm_year + 1900), (uint16_t)(tm->tm_mon + 1), (uint16_t)tm->tm_wday,
                      (uint16_t)tm->tm_mday, (uint16_t)tm->tm_hour, (uint16_t)tm->tm_min, (uint16_t)tm->tm_sec,
                      (uint16_t)ms };
    memcpy(G(st), v, sizeof v);
}

uint32_t bl_k32_GetSystemTime_c(uint32_t st)
{
    struct timespec ts;
    struct tm tm;
    clock_gettime(CLOCK_REALTIME, &ts);
    gmtime_r(&ts.tv_sec, &tm);
    put_systemtime(st, &tm, ts.tv_nsec / 1000000);
    return 0;
}

uint32_t bl_k32_GetLocalTime_c(uint32_t st)
{
    struct timespec ts;
    struct tm tm;
    clock_gettime(CLOCK_REALTIME, &ts);
    localtime_r(&ts.tv_sec, &tm);
    put_systemtime(st, &tm, ts.tv_nsec / 1000000);
    return 0;
}

static int32_t local_offset_seconds(void)
{
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    return (int32_t)tm.tm_gmtoff;
}

uint32_t bl_k32_GetTimeZoneInformation_c(uint32_t tzi)
{
    memset(G(tzi), 0, 172);
    U32(tzi) = (uint32_t)(-local_offset_seconds() / 60);  // Bias, minutes
    return 0;  // TIME_ZONE_ID_UNKNOWN
}

uint32_t bl_k32_FileTimeToLocalFileTime_c(uint32_t in, uint32_t out)
{
    uint64_t ft = U32(in) | (uint64_t)U32(in + 4) << 32;
    put_filetime(out, ft + (uint64_t)((int64_t)local_offset_seconds() * 10000000));
    return 1;
}

uint32_t bl_k32_FileTimeToSystemTime_c(uint32_t in, uint32_t st)
{
    uint64_t ft = U32(in) | (uint64_t)U32(in + 4) << 32;
    uint64_t t100 = ft - 116444736000000000ull;
    time_t t = (time_t)(t100 / 10000000);
    struct tm tm;
    gmtime_r(&t, &tm);
    put_systemtime(st, &tm, (long)(t100 % 10000000 / 10000));
    return 1;
}

uint32_t bl_k32_QueryPerformanceCounter_c(uint32_t out)
{
    bl_cocoa_pump_if_idle();
    uint64_t t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    U32(out) = (uint32_t)t;
    U32(out + 4) = (uint32_t)(t >> 32);
    return 1;
}

uint32_t bl_k32_QueryPerformanceFrequency_c(uint32_t out)
{
    U32(out) = 1000000000u;
    U32(out + 4) = 0;
    return 1;
}

// --- code pages and locale (Windows-1252 treated as Latin-1) ----------------------

uint32_t bl_k32_GetACP_c(void) { return 1252; }
uint32_t bl_k32_GetOEMCP_c(void) { return 437; }
uint32_t bl_k32_IsValidCodePage_c(uint32_t cp) { return cp == 1252 || cp == 437; }
uint32_t bl_k32_GetUserDefaultLCID_c(void) { return 0x409; }

uint32_t bl_k32_IsValidLocale_c(uint32_t lcid, uint32_t flags)
{
    (void)flags;
    return (lcid & 0x3ff) == 9;  // English
}

uint32_t bl_k32_EnumSystemLocalesA_c(uint32_t fn, uint32_t flags)
{
    (void)fn, (void)flags;
    return 1;
}

uint32_t bl_k32_GetCPInfo_c(uint32_t cp, uint32_t info)
{
    (void)cp;
    memset(G(info), 0, 20);
    U32(info) = 1;  // MaxCharSize
    *((uint8_t *)G(info) + 4) = '?';
    return 1;
}

static const char *locale_info(uint32_t type)
{
    switch (type & 0xffff) {
    case 0x01: return "0409";             // LOCALE_ILANGUAGE
    case 0x03: return "ENU";              // LOCALE_SABBREVLANGNAME
    case 0x07: return "USA";              // LOCALE_SABBREVCTRYNAME
    case 0x0b: return "437";              // LOCALE_IDEFAULTCODEPAGE
    case 0x0e: return ".";                // LOCALE_SDECIMAL
    case 0x0f: return ",";                // LOCALE_STHOUSAND
    case 0x1001: return "English";        // LOCALE_SENGLANGUAGE
    case 0x1002: return "United States";  // LOCALE_SENGCOUNTRY
    case 0x1004: return "1252";           // LOCALE_IDEFAULTANSICODEPAGE
    default: return NULL;
    }
}

uint32_t bl_k32_GetLocaleInfoA_c(uint32_t lcid, uint32_t type, uint32_t buf, uint32_t len)
{
    (void)lcid;
    const char *s = locale_info(type);
    if (!s) { bl_set_last_error(BL_ERROR_INVALID_PARAMETER); return 0; }
    uint32_t n = (uint32_t)strlen(s) + 1;
    if (!len) return n;
    if (len < n) { bl_set_last_error(BL_ERROR_INSUFFICIENT_BUFFER); return 0; }
    memcpy(G(buf), s, n);
    return n;
}

uint32_t bl_k32_GetLocaleInfoW_c(uint32_t lcid, uint32_t type, uint32_t buf, uint32_t len)
{
    (void)lcid;
    const char *s = locale_info(type);
    if (!s) { bl_set_last_error(BL_ERROR_INVALID_PARAMETER); return 0; }
    uint32_t n = (uint32_t)strlen(s) + 1;
    if (!len) return n;
    if (len < n) { bl_set_last_error(BL_ERROR_INSUFFICIENT_BUFFER); return 0; }
    for (uint32_t i = 0; i < n; i++) U16(buf + 2 * i) = (uint8_t)s[i];
    return n;
}

static uint16_t ctype1(unsigned c)
{
    if (c > 0x7f) return c > 0xff ? 0 : 0x100;  // Latin-1 letters count as alpha
    uint16_t t = 0;
    if (isupper((int)c)) t |= 0x001;
    if (islower((int)c)) t |= 0x002;
    if (isdigit((int)c)) t |= 0x004;
    if (isspace((int)c)) t |= 0x008;
    if (ispunct((int)c)) t |= 0x010;
    if (iscntrl((int)c)) t |= 0x020;
    if (c == ' ' || c == '\t') t |= 0x040;
    if (isxdigit((int)c)) t |= 0x080;
    if (isalpha((int)c)) t |= 0x100;
    return t;
}

uint32_t bl_k32_GetStringTypeA_c(uint32_t lcid, uint32_t info, uint32_t src, uint32_t n, uint32_t out)
{
    (void)lcid;
    if (info != 1) return 0;  // CT_CTYPE1 only
    const uint8_t *s = G(src);
    if ((int32_t)n < 0) n = (uint32_t)strlen((const char *)s) + 1;
    for (uint32_t i = 0; i < n; i++) U16(out + 2 * i) = ctype1(s[i]);
    return 1;
}

uint32_t bl_k32_GetStringTypeW_c(uint32_t info, uint32_t src, uint32_t n, uint32_t out)
{
    if (info != 1) return 0;
    if ((int32_t)n < 0)
        for (n = 0; U16(src + 2 * n); n++) {}
    for (uint32_t i = 0; i < n; i++) U16(out + 2 * i) = ctype1(U16(src + 2 * i));
    return 1;
}

static unsigned map_char(unsigned c, uint32_t flags)
{
    if (c > 0x7f) return c;
    if (flags & 0x100) return (unsigned)tolower((int)c);  // LCMAP_LOWERCASE
    if (flags & 0x200) return (unsigned)toupper((int)c);  // LCMAP_UPPERCASE
    return c;
}

uint32_t bl_k32_LCMapStringA_c(uint32_t lcid, uint32_t flags, uint32_t src, uint32_t n, uint32_t dst, uint32_t cap)
{
    (void)lcid;
    const uint8_t *s = G(src);
    if ((int32_t)n < 0) n = (uint32_t)strlen((const char *)s) + 1;
    if (!cap) return n;
    if (cap < n) { bl_set_last_error(BL_ERROR_INSUFFICIENT_BUFFER); return 0; }
    for (uint32_t i = 0; i < n; i++) ((uint8_t *)G(dst))[i] = (uint8_t)map_char(s[i], flags);
    return n;
}

uint32_t bl_k32_LCMapStringW_c(uint32_t lcid, uint32_t flags, uint32_t src, uint32_t n, uint32_t dst, uint32_t cap)
{
    (void)lcid;
    if ((int32_t)n < 0) {
        for (n = 0; U16(src + 2 * n); n++) {}
        n++;
    }
    if (!cap) return n;
    if (cap < n) { bl_set_last_error(BL_ERROR_INSUFFICIENT_BUFFER); return 0; }
    for (uint32_t i = 0; i < n; i++) U16(dst + 2 * i) = (uint16_t)map_char(U16(src + 2 * i), flags);
    return n;
}

static unsigned at8(uint32_t s, uint32_t i) { return ((const uint8_t *)G(s))[i]; }
static unsigned at16(uint32_t s, uint32_t i) { return U16(s + 2 * i); }

static uint32_t compare(unsigned (*at)(uint32_t, uint32_t), uint32_t flags, uint32_t s1, uint32_t n1, uint32_t s2,
                        uint32_t n2)
{
    for (uint32_t i = 0;; i++) {
        if (i >= n1 || i >= n2) return n1 == n2 ? 2 : n1 < n2 ? 1 : 3;
        unsigned a = at(s1, i), b = at(s2, i);
        if (flags & 1) a = map_char(a, 0x100), b = map_char(b, 0x100);  // NORM_IGNORECASE
        if (a != b) return a < b ? 1 : 3;  // CSTR_LESS_THAN / CSTR_GREATER_THAN
    }
}

uint32_t bl_k32_CompareStringA_c(uint32_t lcid, uint32_t flags, uint32_t s1, uint32_t n1, uint32_t s2, uint32_t n2)
{
    (void)lcid;
    if ((int32_t)n1 < 0) n1 = (uint32_t)strlen(G(s1));
    if ((int32_t)n2 < 0) n2 = (uint32_t)strlen(G(s2));
    return compare(at8, flags, s1, n1, s2, n2);
}

uint32_t bl_k32_CompareStringW_c(uint32_t lcid, uint32_t flags, uint32_t s1, uint32_t n1, uint32_t s2, uint32_t n2)
{
    (void)lcid;
    if ((int32_t)n1 < 0)
        for (n1 = 0; U16(s1 + 2 * n1); n1++) {}
    if ((int32_t)n2 < 0)
        for (n2 = 0; U16(s2 + 2 * n2); n2++) {}
    return compare(at16, flags, s1, n1, s2, n2);
}

static int is_cp1252(uint32_t cp) { return cp == 0 || cp == 3 || cp == 1252; }  // CP_ACP, CP_THREAD_ACP

uint32_t bl_k32_MultiByteToWideChar_c(uint32_t cp, uint32_t flags, uint32_t src, uint32_t n, uint32_t dst,
                                      uint32_t cap)
{
    (void)flags;
    const uint8_t *s = G(src);
    if ((int32_t)n < 0) n = (uint32_t)strlen((const char *)s) + 1;
    if (!cap) return n;
    if (cap < n) { bl_set_last_error(BL_ERROR_INSUFFICIENT_BUFFER); return 0; }
    for (uint32_t i = 0; i < n; i++) U16(dst + 2 * i) = is_cp1252(cp) ? bl_cp1252_to_wide(s[i]) : s[i];
    return n;
}

uint32_t bl_k32_WideCharToMultiByte_c(uint32_t cp, uint32_t flags, uint32_t src, uint32_t n, uint32_t dst,
                                      uint32_t cap, uint32_t defchar, uint32_t used_default)
{
    (void)flags;
    if ((int32_t)n < 0) {
        for (n = 0; U16(src + 2 * n); n++) {}
        n++;
    }
    if (used_default) U32(used_default) = 0;
    if (!cap) return n;
    if (cap < n) { bl_set_last_error(BL_ERROR_INSUFFICIENT_BUFFER); return 0; }
    for (uint32_t i = 0; i < n; i++) {
        int c = U16(src + 2 * i);
        if (is_cp1252(cp)) c = bl_wide_to_cp1252((uint16_t)c);
        else if (c > 0xff) c = -1;
        if (c < 0) {
            c = defchar ? *(const uint8_t *)G(defchar) : '?';
            if (used_default) U32(used_default) = 1;
        }
        ((uint8_t *)G(dst))[i] = (uint8_t)c;
    }
    return n;
}

uint32_t bl_k32_lstrlenA_c(uint32_t s) { return s ? (uint32_t)strlen(G(s)) : 0; }

uint32_t bl_k32_DisableThreadLibraryCalls_c(uint32_t module)
{
    (void)module;
    return 1;
}

void bl_win32_init(const char *dir, const char *cmdline)
{
    snprintf(game_dir, sizeof game_dir, "%s", dir);
    size_t n = strlen(game_dir);
    if (n && game_dir[n - 1] == '/') game_dir[n - 1] = 0;
    migrate_data();
    char buf[1024];
    snprintf(buf, sizeof buf, "\"%s\\vampire.exe\"%s%s", BL_WIN_ROOT, cmdline && *cmdline ? " " : "",
             cmdline ? cmdline : "");
    command_line = bl_guest_strdup(buf);
}

// --- more kernel32 (milestone 3 modules) ------------------------------------------

uint32_t bl_k32_GetTickCount_c(void)
{
    bl_cocoa_pump_if_idle();
    return (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000);
}

uint32_t bl_k32_GetSystemTimeAsFileTime_c(uint32_t out)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    put_filetime(out, unix_to_filetime(ts.tv_sec, ts.tv_nsec));
    return 0;
}

uint32_t bl_k32_IsProcessorFeaturePresent_c(uint32_t feature)
{
    return feature == 0 ? 0 : 0;  // no MMX/SSE/3DNow (matches bl_cpuid)
}

uint32_t bl_k32_SetUnhandledExceptionFilter_c(uint32_t fn) { (void)fn; return 0; }
uint32_t bl_k32_SetErrorMode_c(uint32_t mode) { (void)mode; return 0; }

static uint32_t attributes_of(const struct stat *st)
{
    uint32_t a = S_ISDIR(st->st_mode) ? 0x10 : 0x80;  // DIRECTORY / NORMAL
    if (!(st->st_mode & S_IWUSR)) a = (a & ~0x80u) | 0x01;  // READONLY
    return a;
}

uint32_t bl_k32_GetFileAttributesA_c(uint32_t name)
{
    char host[1024];
    struct stat st;
    if (!bl_path_to_host(G(name), host, sizeof host) || stat(host, &st)) {
        bl_set_last_error(BL_ERROR_FILE_NOT_FOUND);
        return 0xffffffffu;  // INVALID_FILE_ATTRIBUTES
    }
    return attributes_of(&st);
}

uint32_t bl_k32_SetFileAttributesA_c(uint32_t name, uint32_t attrs)
{
    char host[1024];
    struct stat st;
    if (!bl_path_to_host(G(name), host, sizeof host) || stat(host, &st)) {
        bl_set_last_error(BL_ERROR_FILE_NOT_FOUND);
        return 0;
    }
    mode_t m = (attrs & 0x01) ? st.st_mode & ~(mode_t)0222 : st.st_mode | S_IWUSR;
    return path_op_result(host, chmod(host, m));
}

uint32_t bl_k32_RemoveDirectoryA_c(uint32_t name)
{
    char host[1024];
    return bl_path_to_host(G(name), host, sizeof host) ? path_op_result(host, rmdir(host)) : bad_path();
}

uint32_t bl_k32_GetFileSize_c(uint32_t h, uint32_t high)
{
    struct stat st;
    int fd = file_fd(h);
    if (fd < 0 || fstat(fd, &st)) {
        bl_set_last_error(BL_ERROR_INVALID_HANDLE);
        return 0xffffffffu;
    }
    if (high) U32(high) = (uint32_t)((uint64_t)st.st_size >> 32);
    return (uint32_t)st.st_size;
}

uint32_t bl_k32_GetFileTime_c(uint32_t h, uint32_t created, uint32_t accessed, uint32_t written)
{
    struct stat st;
    int fd = file_fd(h);
    if (fd < 0 || fstat(fd, &st)) return 0;
    if (created) put_filetime(created, unix_to_filetime(st.st_birthtimespec.tv_sec, st.st_birthtimespec.tv_nsec));
    if (accessed) put_filetime(accessed, unix_to_filetime(st.st_atimespec.tv_sec, st.st_atimespec.tv_nsec));
    if (written) put_filetime(written, unix_to_filetime(st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec));
    return 1;
}

// BY_HANDLE_FILE_INFORMATION (52 bytes).
uint32_t bl_k32_GetFileInformationByHandle_c(uint32_t h, uint32_t info)
{
    struct stat st;
    int fd = file_fd(h);
    if (fd < 0 || fstat(fd, &st)) {
        bl_set_last_error(BL_ERROR_INVALID_HANDLE);
        return 0;
    }
    memset(G(info), 0, 52);
    U32(info) = attributes_of(&st);
    put_filetime(info + 4, unix_to_filetime(st.st_birthtimespec.tv_sec, st.st_birthtimespec.tv_nsec));
    put_filetime(info + 12, unix_to_filetime(st.st_atimespec.tv_sec, st.st_atimespec.tv_nsec));
    put_filetime(info + 20, unix_to_filetime(st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec));
    U32(info + 28) = (uint32_t)st.st_dev;
    U32(info + 32) = (uint32_t)((uint64_t)st.st_size >> 32);
    U32(info + 36) = (uint32_t)st.st_size;
    U32(info + 40) = st.st_nlink;
    U32(info + 44) = (uint32_t)(st.st_ino >> 32);
    U32(info + 48) = (uint32_t)st.st_ino;
    return 1;
}

static uint32_t put_path(uint32_t buf, uint32_t len, const char *s)
{
    uint32_t n = (uint32_t)strlen(s);
    if (len <= n) return n + 1;
    put_str(buf, len, s);
    return n;
}

uint32_t bl_k32_GetTempPathA_c(uint32_t len, uint32_t buf) { return put_path(buf, len, BL_WIN_ROOT "\\temp\\"); }
uint32_t bl_k32_GetWindowsDirectoryA_c(uint32_t buf, uint32_t len) { return put_path(buf, len, "C:\\WINDOWS"); }
uint32_t bl_k32_GetSystemDirectoryA_c(uint32_t buf, uint32_t len) { return put_path(buf, len, "C:\\WINDOWS\\system32"); }
uint32_t bl_k32_GetLogicalDrives_c(void) { return 1u << 2; }  // C:

uint32_t bl_k32_GetDiskFreeSpaceA_c(uint32_t root, uint32_t spc, uint32_t bps, uint32_t freec, uint32_t total)
{
    (void)root;
    if (spc) U32(spc) = 8;
    if (bps) U32(bps) = 512;
    if (freec) U32(freec) = 0x00100000;  // 4 GiB free
    if (total) U32(total) = 0x00200000;
    return 1;
}

uint32_t bl_k32_lstrcpyA_c(uint32_t dst, uint32_t src)
{
    memmove(G(dst), G(src), strlen(G(src)) + 1);
    return dst;
}

uint32_t bl_k32_lstrcatA_c(uint32_t dst, uint32_t src)
{
    size_t n = strlen(G(dst));
    memmove((char *)G(dst) + n, G(src), strlen(G(src)) + 1);
    return dst;
}

uint32_t bl_k32_lstrlenW_c(uint32_t s)
{
    uint32_t n = 0;
    if (s)
        while (U16(s + 2 * n)) n++;
    return n;
}

// Local/Global memory: fixed blocks on the guest heap (handle == pointer).
uint32_t bl_k32_LocalAlloc_c(uint32_t flags, uint32_t size)
{
    return flags & 0x40 ? bl_guest_calloc(1, size) : bl_guest_malloc(size);  // LMEM_ZEROINIT
}

uint32_t bl_k32_LocalFree_c(uint32_t p) { bl_guest_free(p); return 0; }
uint32_t bl_k32_GlobalAlloc_c(uint32_t flags, uint32_t size) { return bl_k32_LocalAlloc_c(flags, size); }
uint32_t bl_k32_GlobalFree_c(uint32_t p) { bl_guest_free(p); return 0; }
uint32_t bl_k32_GlobalLock_c(uint32_t p) { return p; }
uint32_t bl_k32_GlobalUnlock_c(uint32_t p) { (void)p; return 0; }
uint32_t bl_k32_GlobalSize_c(uint32_t p) { return p ? bl_guest_size(p) : 0; }

// MEMORYSTATUS (32 bytes): report 1 GiB physical, 2 GiB virtual.
uint32_t bl_k32_GlobalMemoryStatus_c(uint32_t ms)
{
    uint32_t v[8] = { 32, 10, 1u << 30, 1u << 29, 2u << 30, 1u << 30, 2u << 30, 1u << 30 };
    v[7] = (2u << 30) - (256u << 20);
    memcpy(G(ms), v, sizeof v);
    return 0;
}

uint32_t bl_k32_VirtualProtect_c(uint32_t addr, uint32_t size, uint32_t prot, uint32_t old)
{
    (void)addr, (void)size, (void)prot;
    if (old) U32(old) = 0x04;  // PAGE_READWRITE: guest memory is always readable and writable
    return 1;
}

// MEMORY_BASIC_INFORMATION (28 bytes): everything looks like committed read/write memory.
uint32_t bl_k32_VirtualQuery_c(uint32_t addr, uint32_t info, uint32_t len)
{
    if (len < 28) return 0;
    uint32_t page = addr & ~0xfffu;
    uint32_t v[7] = { page, page, 0x04, 0x1000, 0x1000, 0x04, 0x20000 };  // MEM_COMMIT, MEM_PRIVATE
    memcpy(G(info), v, sizeof v);
    return 28;
}

uint32_t bl_k32_IsBadReadPtr_c(uint32_t p, uint32_t n) { (void)n; return p == 0; }
uint32_t bl_k32_IsBadCodePtr_c(uint32_t p) { return p == 0; }
uint32_t bl_k32_HeapValidate_c(uint32_t h, uint32_t f, uint32_t p) { (void)h, (void)f, (void)p; return 1; }
uint32_t bl_k32_HeapCompact_c(uint32_t h, uint32_t f) { (void)h, (void)f; return 1u << 20; }

uint32_t bl_k32_LoadLibraryExA_c(uint32_t name, uint32_t file, uint32_t flags)
{
    (void)file, (void)flags;
    extern uint32_t bl_k32_LoadLibraryA_c(uint32_t);
    return bl_k32_LoadLibraryA_c(name);
}

uint32_t bl_k32_FormatMessageA_c(uint32_t flags, uint32_t src, uint32_t id, uint32_t lang, uint32_t buf,
                                 uint32_t size, uint32_t args)
{
    (void)src, (void)lang, (void)args;
    char msg[64];
    snprintf(msg, sizeof msg, "Win32 error %u\r\n", id);
    uint32_t n = (uint32_t)strlen(msg);
    if (flags & 0x100) {  // FORMAT_MESSAGE_ALLOCATE_BUFFER: buf receives a LocalAlloc'd pointer
        uint32_t p = bl_guest_strdup(msg);
        U32(buf) = p;
        return n;
    }
    if (size <= n) return 0;
    put_str(buf, size, msg);
    return n;
}

uint32_t bl_k32_SystemTimeToFileTime_c(uint32_t st, uint32_t ft)
{
    const uint16_t *v = G(st);
    struct tm tm = { .tm_year = v[0] - 1900, .tm_mon = v[1] - 1, .tm_mday = v[3], .tm_hour = v[4],
                     .tm_min = v[5], .tm_sec = v[6] };
    put_filetime(ft, unix_to_filetime(timegm(&tm), (long)v[7] * 1000000));
    return 1;
}

uint32_t bl_k32_LocalFileTimeToFileTime_c(uint32_t in, uint32_t out)
{
    uint64_t ft = U32(in) | (uint64_t)U32(in + 4) << 32;
    put_filetime(out, ft - (uint64_t)((int64_t)local_offset_seconds() * 10000000));
    return 1;
}

uint32_t bl_k32_FileTimeToDosDateTime_c(uint32_t in, uint32_t date, uint32_t tim)
{
    uint64_t ft = U32(in) | (uint64_t)U32(in + 4) << 32;
    time_t t = (time_t)((ft - 116444736000000000ull) / 10000000);
    struct tm tm;
    gmtime_r(&t, &tm);
    if (date) U16(date) = (uint16_t)(((tm.tm_year - 80) << 9) | ((tm.tm_mon + 1) << 5) | tm.tm_mday);
    if (tim) U16(tim) = (uint16_t)((tm.tm_hour << 11) | (tm.tm_min << 5) | (tm.tm_sec / 2));
    return 1;
}

uint32_t bl_k32_GetProcessTimes_c(uint32_t h, uint32_t created, uint32_t exited, uint32_t kernel, uint32_t user)
{
    (void)h;
    put_filetime(created, unix_to_filetime(0, 0));
    put_filetime(exited, 0);
    uint64_t cpu = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) / 100;
    put_filetime(kernel, 0);
    put_filetime(user, cpu);
    return 1;
}
