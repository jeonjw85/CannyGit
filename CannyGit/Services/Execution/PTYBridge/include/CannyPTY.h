#ifndef CANNY_PTY_H
#define CANNY_PTY_H

#include <stdint.h>
#include <sys/types.h>

typedef struct {
    pid_t pid;
    int master_fd;
    int error_stage; /* 1: setup, 2: chdir, 3: exec */
    uint64_t start_seconds;
    uint64_t start_microseconds;
} CGPTYLaunch;

/* Returns errno on failure; never returns a live child on failure.
 * May wait for exec; callers must serialize launches on a background executor. */
int cg_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                 const char *directory, uint16_t columns, uint16_t rows,
                 CGPTYLaunch *result);
int cg_pty_resize(int fd, uint16_t columns, uint16_t rows);
int cg_wait_exited(int status);
int cg_wait_exit_code(int status);
int cg_wait_signaled(int status);
int cg_wait_signal(int status);

#endif
