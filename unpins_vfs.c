/* See vfs.h for the API contract. Implementation notes:
 *
 *   miniz handles ZIP central-directory parsing and per-entry inflate.
 *   We never decompress eagerly — unpins_vfs_init only validates the archive
 *   and caches an mz_zip_archive handle.
 *
 *   unpins_vfs_fopen inflates one entry into a malloc'd cookie+buffer pair
 *   and returns a fopencookie FILE*. The cookie's close hook frees
 *   the buffer, so plain fclose() cleans up — vim doesn't need to
 *   know it's holding a virtual FILE*.
 *
 *   unpins_vfs_open uses memfd_create + write + lseek(0) to hand back a real
 *   kernel fd whose contents are the inflated entry. close()/read()/
 *   lseek() Just Work. The memfd is anonymous so it disappears when
 *   the last fd is closed.
 *
 *   Directory iteration is O(N) over the central directory filtered by
 *   prefix. N is ~2500 for vim's runtime; a sequential walk takes
 *   microseconds and avoids building a tree index.
 *
 *   Synthetic struct stat: mode is S_IFREG|0444 for files, S_IFDIR|0555
 *   for "directories" (any path that's a prefix of some entry). Sizes
 *   are the uncompressed size from the ZIP entry. Times are zero
 *   (vim doesn't depend on runtime file mtimes).
 */

/* _GNU_SOURCE comes from the Makefile so fopencookie + memfd_create
 * are visible. Don't redefine here — the build flags already provide it. */

#include "unpins_vfs.h"
#include "miniz.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
# include <io.h>
# include <windows.h>
# ifndef _O_TEMPORARY
#  define _O_TEMPORARY 0x0040
# endif
# define UVFS_LSEEK  _lseek
# define UVFS_WRITE  _write
# define UVFS_CLOSE  _close
# define UVFS_FDOPEN _fdopen
#else
# include <sys/param.h>     /* PATH_MAX/MAXPATHLEN on BSDs/darwin */
# include <unistd.h>
# ifdef __linux__
#  include <sys/syscall.h>  /* SYS_memfd_create */
# endif
# define UVFS_LSEEK  lseek
# define UVFS_WRITE  write
# define UVFS_CLOSE  close
# define UVFS_FDOPEN fdopen
#endif

/* darwin/BSDs put PATH_MAX in <sys/syslimits.h> (included transitively
 * by <sys/param.h> as MAXPATHLEN). Provide a fallback so the code is
 * the same shape regardless of which header defined the symbol. */
#ifndef PATH_MAX
# ifdef MAXPATHLEN
#  define PATH_MAX MAXPATHLEN
# else
#  define PATH_MAX 4096
# endif
#endif

/* ---- ZIP archive state ----------------------------------------------- */

static mz_zip_archive g_zip;
static int g_zip_ready = 0;

/* All ZIP entries have a "vim92/" prefix when we built the archive with
 * `zip -r runtime.zip vim92`. Strip the VFS_PREFIX from the user-facing
 * side and prepend "vim92/" before looking up in the ZIP. */
static const char zip_root[] = "vim92";

int unpins_vfs_init(const void *zip_data, size_t zip_size)
{
    memset(&g_zip, 0, sizeof g_zip);
    if (!mz_zip_reader_init_mem(&g_zip, zip_data, zip_size, 0)) {
        return -1;
    }
    g_zip_ready = 1;
    return 0;
}

/* ---- path classification --------------------------------------------- */

/* The unique marker `__unpins_vimruntime__` identifies a VFS path. We
 * locate it with strstr instead of a strict prefix match because vim on
 * Windows normalizes `/__unpins_vimruntime__/...` to
 * `C:\__unpins_vimruntime__\...` (prepends current drive + flips
 * separators) — the marker still appears unchanged inside the path. */
#define VFS_MARKER "__unpins_vimruntime__"

int unpins_vfs_is_virtual(const char *path)
{
    if (!path) return 0;
    return strstr(path, VFS_MARKER) != NULL;
}

/* Convert any path containing VFS_MARKER to the ZIP lookup key
 * "vim92/<rest>". Backslash separators (from vim on Windows) are
 * normalized to '/'. */
static int to_zip_path(const char *vpath, char *out, size_t cap)
{
    const char *marker = strstr(vpath, VFS_MARKER);
    if (!marker) return -1;
    const char *rest = marker + sizeof(VFS_MARKER) - 1;
    /* Skip leading slash/backslash from the rest part. */
    while (*rest == '/' || *rest == '\\') rest++;
    int n;
    if (*rest)
        n = snprintf(out, cap, "%s/%s", zip_root, rest);
    else
        n = snprintf(out, cap, "%s", zip_root);
    if (n < 0 || (size_t)n >= cap) return -1;
    /* Normalize separators inside the path tail. */
    for (char *p = out; *p; p++)
        if (*p == '\\') *p = '/';
    return 0;
}

/* ---- entry lookup ---------------------------------------------------- */

/* Returns ZIP file index, or -1 if not found. Tries exact match first,
 * then with a trailing slash (for directory queries). */
static int find_entry(const char *zip_path)
{
    int idx = mz_zip_reader_locate_file(&g_zip, zip_path, NULL, 0);
    if (idx >= 0) return idx;
    char with_slash[PATH_MAX];
    int n = snprintf(with_slash, sizeof with_slash, "%s/", zip_path);
    if (n < 0 || (size_t)n >= sizeof with_slash) return -1;
    return mz_zip_reader_locate_file(&g_zip, with_slash, NULL, 0);
}

/* Is `zip_path` the *implicit* parent of any entry? ZIP archives
 * sometimes omit directory records; if `zip_path/...` exists, we treat
 * it as a directory even without an explicit entry. */
static int is_implicit_dir(const char *zip_path)
{
    size_t plen = strlen(zip_path);
    mz_uint n = mz_zip_reader_get_num_files(&g_zip);
    char namebuf[PATH_MAX];
    for (mz_uint i = 0; i < n; i++) {
        mz_uint flen = mz_zip_reader_get_filename(&g_zip, i, namebuf,
                                                   sizeof namebuf);
        if (flen <= plen) continue;
        if (memcmp(namebuf, zip_path, plen) == 0 && namebuf[plen] == '/')
            return 1;
    }
    return 0;
}

/* ---- inflate-to-buffer helper --------------------------------------- */

/* Look up `vpath` in the ZIP, inflate into a fresh malloc'd buffer,
 * return (buf, size). Caller owns buf. Returns 0 on success.
 * Sets errno on failure and returns -1. */
static int inflate_entry(const char *vpath, void **out_buf, size_t *out_size)
{
    char zpath[PATH_MAX];
    if (to_zip_path(vpath, zpath, sizeof zpath) < 0) {
        errno = ENAMETOOLONG; return -1;
    }

    int idx = find_entry(zpath);
    if (idx < 0) { errno = ENOENT; return -1; }

    mz_zip_archive_file_stat st;
    if (!mz_zip_reader_file_stat(&g_zip, idx, &st)) {
        errno = EIO; return -1;
    }
    if (st.m_is_directory) { errno = EISDIR; return -1; }

    size_t size = st.m_uncomp_size;
    void *buf = malloc(size ? size : 1);
    if (!buf) { errno = ENOMEM; return -1; }

    if (size > 0 &&
        !mz_zip_reader_extract_to_mem(&g_zip, idx, buf, size, 0)) {
        free(buf);
        errno = EIO; return -1;
    }

    *out_buf = buf;
    *out_size = size;
    return 0;
}

/* ---- fopen via fopencookie ------------------------------------------ */

/* Why fdopen(memfd_create(...)) instead of fopencookie?
 *   fopencookie exists on glibc and musl, but the seek-callback signature
 *   differs (`off64_t *` on glibc vs `off_t *` on musl), forcing
 *   conditional compilation. Routing through a memfd gives us a real
 *   kernel fd that fdopen wraps as FILE*; plain fclose closes the fd,
 *   the kernel reclaims the anonymous memory. ~1 extra syscall per
 *   open vs cookie, trivial in the vim runtime read pattern. */

FILE *unpins_vfs_fopen(const char *path, const char *mode)
{
    int dbg = getenv("UNPINS_DEBUG") != NULL;
    int virt = unpins_vfs_is_virtual(path);
    if (dbg)
        fprintf(stderr, "[unpins_vfs_fopen] virt=%d path=%s\n", virt, path);
    if (!virt)
        return fopen(path, mode);
    if (!g_zip_ready) { errno = EIO; return NULL; }
    if (mode && mode[0] != 'r') { errno = EROFS; return NULL; }

    int fd = unpins_vfs_open(path, O_RDONLY);
    if (dbg)
        fprintf(stderr, "[unpins_vfs_fopen]   inner open returned fd=%d errno=%d (%s)\n",
                fd, errno, fd < 0 ? strerror(errno) : "ok");
    if (fd < 0) return NULL;

    FILE *fp = UVFS_FDOPEN(fd, "rb");
    if (!fp) {
        int saved = errno;
        UVFS_CLOSE(fd);
        errno = saved;
        return NULL;
    }
    return fp;
}

/* ---- open via memfd_create ------------------------------------------ */

int unpins_vfs_open(const char *path, int flags, ...)
{
    int dbg = getenv("UNPINS_DEBUG") != NULL;
    int virt = unpins_vfs_is_virtual(path);
    if (dbg && virt)
        fprintf(stderr, "[unpins_vfs_open] virt=%d path=%s\n", virt, path);
    if (!virt) {
        int mode = 0;
        if (flags & O_CREAT) {
            va_list ap;
            va_start(ap, flags);
            mode = va_arg(ap, int);
            va_end(ap);
        }
        return open(path, flags, mode);
    }
    if (!g_zip_ready) { errno = EIO; return -1; }
    if ((flags & O_ACCMODE) != O_RDONLY) { errno = EROFS; return -1; }

    void *buf;
    size_t size;
    if (inflate_entry(path, &buf, &size) < 0) return -1;

#ifdef _WIN32
    /* Windows: anonymous, auto-deleting temp file via _O_TEMPORARY. Closed
     * fd is removed from disk by the C runtime. Pays one disk round-trip
     * vs Linux's memfd; acceptable for small vim runtime reads. */
    char tmp_dir[MAX_PATH];
    char tmp_path[MAX_PATH];
    DWORD dn = GetTempPathA((DWORD)sizeof tmp_dir, tmp_dir);
    if (dn == 0 || dn >= sizeof tmp_dir) { free(buf); errno = EIO; return -1; }
    if (GetTempFileNameA(tmp_dir, "uvf", 0, tmp_path) == 0) {
        free(buf); errno = EIO; return -1;
    }
    /* GetTempFileNameA already created the file; reopen with _O_TEMPORARY
     * so the OS removes it on the final close. */
    int fd = _open(tmp_path,
                   _O_RDWR | _O_BINARY | _O_TEMPORARY,
                   _S_IREAD | _S_IWRITE);
    if (fd < 0) { DeleteFileA(tmp_path); free(buf); return -1; }
#elif defined(__linux__)
    /* Linux: memfd_create syscall — anonymous kernel-backed fd, no disk. */
    int fd = (int)syscall(SYS_memfd_create, "unpins_vfs", 0u);
    if (fd < 0) { free(buf); return -1; }
#else
    /* Other Unix (darwin, *BSD): no memfd. Use mkstemp + immediate unlink
     * for an anonymous file — the dirent is removed but the fd keeps the
     * file alive until the last close. Same lifetime semantics as a
     * memfd, plus one disk round-trip. */
    char tmpl[PATH_MAX];
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    int tn = snprintf(tmpl, sizeof tmpl, "%s/unpins_vfs.XXXXXX", tmp);
    if (tn < 0 || (size_t)tn >= sizeof tmpl) { free(buf); errno = EIO; return -1; }
    int fd = mkstemp(tmpl);
    if (fd < 0) { free(buf); return -1; }
    unlink(tmpl);
#endif

    /* Write the full buffer to the backing fd. Loop in case of partial
     * writes (rare on memfd, possible on Windows temp). */
    char *p = buf;
    size_t left = size;
    while (left > 0) {
        long w = (long)UVFS_WRITE(fd, p, (unsigned int)left);
        if (w < 0) {
#ifndef _WIN32
            if (errno == EINTR) continue;
#endif
            UVFS_CLOSE(fd); free(buf); return -1;
        }
        p += w;
        left -= (size_t)w;
    }
    free(buf);
    if (UVFS_LSEEK(fd, 0, SEEK_SET) < 0) { UVFS_CLOSE(fd); return -1; }
    return fd;
}

/* ---- opendir / readdir / closedir ------------------------------------ */

/* Custom DIR* for virtual directories. We piggyback on a private struct
 * and cast to/from DIR* — the real glibc DIR is opaque to callers, so
 * as long as our consumers only use readdir/closedir on the returned
 * pointer they can't tell the difference. We distinguish virtual vs
 * real DIR* via a tag word at the start. */

struct vfs_dir {
    /* Magic must be first so we can sniff DIR* origin by reading the
     * leading bytes. Real glibc DIR has a small int (fd) at the front
     * which can never equal our magic value. */
    uint64_t magic;
#define VFS_DIR_MAGIC 0x5546534456494d20ULL  /* "UFSDVIM " */

    /* Lookup key: ZIP-relative path without trailing slash. */
    char prefix[PATH_MAX];
    size_t prefix_len;

    /* Iteration cursor over central directory + dedup of immediate
     * children (we synthesize one entry per unique segment after the
     * prefix). For ~2500 entries the dedup set fits in a small array;
     * a 4 KiB stack-fixed hashset would be tighter but adds code. */
    mz_uint cursor;
    char last_emitted[256];

    struct dirent ent;
};

DIR *unpins_vfs_opendir(const char *path)
{
    int dbg = getenv("UNPINS_DEBUG") != NULL;
    int virt = unpins_vfs_is_virtual(path);
    if (dbg)
        fprintf(stderr, "[unpins_vfs_opendir] virt=%d path=%s\n", virt, path);
    if (!virt)
        return opendir(path);
    if (!g_zip_ready) { errno = EIO; return NULL; }

    char zpath[PATH_MAX];
    if (to_zip_path(path, zpath, sizeof zpath) < 0) {
        errno = ENAMETOOLONG; return NULL;
    }

    /* Validate that the path resolves to a directory (explicit entry
     * with trailing slash OR implicit via children). */
    int idx = find_entry(zpath);
    int is_dir = 0;
    if (idx >= 0) {
        is_dir = mz_zip_reader_is_file_a_directory(&g_zip, idx);
    }
    if (!is_dir && !is_implicit_dir(zpath)) {
        errno = ENOENT; return NULL;
    }

    struct vfs_dir *d = calloc(1, sizeof *d);
    if (!d) { errno = ENOMEM; return NULL; }
    d->magic = VFS_DIR_MAGIC;
    d->prefix_len = strlen(zpath);
    if (d->prefix_len >= sizeof d->prefix) {
        free(d); errno = ENAMETOOLONG; return NULL;
    }
    memcpy(d->prefix, zpath, d->prefix_len + 1);
    return (DIR *)d;
}

struct dirent *unpins_vfs_readdir(DIR *dir)
{
    if (!dir) { errno = EBADF; return NULL; }
    struct vfs_dir *d = (struct vfs_dir *)dir;
    if (d->magic != VFS_DIR_MAGIC)
        return readdir(dir);

    mz_uint n = mz_zip_reader_get_num_files(&g_zip);
    char namebuf[PATH_MAX];

    while (d->cursor < n) {
        mz_uint i = d->cursor++;
        mz_uint flen = mz_zip_reader_get_filename(&g_zip, i, namebuf,
                                                   sizeof namebuf);
        /* Skip entries shorter than "<prefix>/x". */
        if (flen <= d->prefix_len + 1) continue;
        /* Match prefix + slash. */
        if (memcmp(namebuf, d->prefix, d->prefix_len) != 0) continue;
        if (namebuf[d->prefix_len] != '/') continue;

        /* Find the first segment after the prefix slash. */
        const char *seg = namebuf + d->prefix_len + 1;
        const char *seg_end = strchr(seg, '/');
        size_t seg_len = seg_end ? (size_t)(seg_end - seg) : strlen(seg);
        if (seg_len == 0 || seg_len >= sizeof d->ent.d_name) continue;

        /* Dedup against the most recently emitted name. Because ZIPs
         * are typically stored in stable order, consecutive entries
         * under the same subdir cluster together — single-slot dedup
         * suffices. For pathological orderings we'd over-emit, which
         * vim handles fine. */
        if (d->last_emitted[0] &&
            strncmp(d->last_emitted, seg, seg_len) == 0 &&
            d->last_emitted[seg_len] == '\0')
            continue;

        memcpy(d->last_emitted, seg, seg_len);
        d->last_emitted[seg_len] = '\0';

        memcpy(d->ent.d_name, seg, seg_len);
        d->ent.d_name[seg_len] = '\0';
#ifndef _WIN32
        /* mingw's struct dirent has no d_ino / d_type field. POSIX
         * consumers rely on these; vim on Windows uses its own dir API. */
        d->ent.d_ino = i + 1;  /* nonzero, stable per archive entry */
        d->ent.d_type = seg_end ? DT_DIR : DT_REG;
#else
        (void)seg_end;
#endif
        return &d->ent;
    }

    return NULL;
}

int unpins_vfs_closedir(DIR *dir)
{
    if (!dir) { errno = EBADF; return -1; }
    struct vfs_dir *d = (struct vfs_dir *)dir;
    if (d->magic != VFS_DIR_MAGIC)
        return closedir(dir);
    free(d);
    return 0;
}

/* ---- stat / lstat ---------------------------------------------------- */

int unpins_vfs_stat(const char *path, unpins_stat_t *st)
{
    int dbg = getenv("UNPINS_DEBUG") != NULL;
    int virt = unpins_vfs_is_virtual(path);
    if (dbg && (virt || strstr(path, "vimrun") || strstr(path, "filetype") || strstr(path, "syntax")))
        fprintf(stderr, "[unpins_vfs_stat] virt=%d path=%s\n", virt, path);
    if (!virt) {
#ifdef _WIN32
        return _stat64(path, st);
#else
        return stat(path, st);
#endif
    }
    if (!g_zip_ready) { errno = EIO; return -1; }

    char zpath[PATH_MAX];
    if (to_zip_path(path, zpath, sizeof zpath) < 0) {
        errno = ENAMETOOLONG; return -1;
    }

    int idx = find_entry(zpath);
    if (idx >= 0) {
        mz_zip_archive_file_stat fs;
        if (!mz_zip_reader_file_stat(&g_zip, idx, &fs)) {
            errno = EIO; return -1;
        }
        memset(st, 0, sizeof *st);
        if (fs.m_is_directory) {
            st->st_mode = S_IFDIR | 0555;
            st->st_nlink = 2;
        } else {
            st->st_mode = S_IFREG | 0444;
            st->st_nlink = 1;
            st->st_size = (long long)fs.m_uncomp_size;
        }
        return 0;
    }

    if (is_implicit_dir(zpath)) {
        memset(st, 0, sizeof *st);
        st->st_mode = S_IFDIR | 0555;
        st->st_nlink = 2;
        return 0;
    }

    errno = ENOENT;
    return -1;
}

int unpins_vfs_lstat(const char *path, unpins_stat_t *st)
{
    if (!unpins_vfs_is_virtual(path)) {
#ifdef _WIN32
        /* Windows has no lstat; fall through to _stat64 (no symlink
         * special-case is expected for the upstream call sites). */
        return _stat64(path, st);
#else
        return lstat(path, st);
#endif
    }
    /* No symlinks in the ZIP — stat and lstat are equivalent. */
    return unpins_vfs_stat(path, st);
}
