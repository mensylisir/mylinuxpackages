/*
 * mylinuxpackages: execvp() environment guard for oversized env strings.
 *
 * Some Electron apps serialise large config blobs into a single environment
 * variable. Linux caps one envp string at MAX_ARG_STRLEN (128 KiB); once such
 * a variable is set, every execve() from the browser process fails E2BIG and
 * child renderers die. We intercept execvp() (used by Chromium's LaunchProcess
 * and libuv's uv_spawn) and strip over-long entries from the CHILD environment
 * only; the browser process still reads the value in-process.
 */
#define _GNU_SOURCE
#include <string.h>
#include <unistd.h>

extern char **environ;

#define MAX_ENV_STRING 131000   /* kernel limit 131072 including NUL */
#define MAX_ENV 2048

static __thread char *clean_env[MAX_ENV + 1];

static int oversized(const char *entry) { return strlen(entry) >= MAX_ENV_STRING; }

int execvp(const char *file, char *const argv[])
{
  char **entry;
  int n = 0;
  for (entry = environ; *entry; entry++)
    if (oversized(*entry)) break;
  if (*entry == NULL) return execvpe(file, argv, environ);   /* nothing to drop */
  for (entry = environ; *entry && n < MAX_ENV; entry++)
    if (!oversized(*entry)) clean_env[n++] = *entry;
  if (n == MAX_ENV) return execvpe(file, argv, environ);     /* safety fallback */
  clean_env[n] = NULL;
  return execvpe(file, argv, clean_env);
}
