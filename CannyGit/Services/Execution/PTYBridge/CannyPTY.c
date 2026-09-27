#include "include/CannyPTY.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

typedef struct { int stage; int code; } LaunchError;

/* Only async-signal-safe operations are used in the post-fork child. */
static void child_failed(int fd, int stage) {
    LaunchError error = { stage, errno };
    const char *bytes = (const char *)&error;
    size_t remaining = sizeof(error);
    while (remaining) {
        ssize_t count = write(fd, bytes, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        bytes += count;
        remaining -= (size_t)count;
    }
    _exit(127);
}

int cg_pty_spawn(const char *executable, char *const argv[], char *const envp[],
                 const char *directory, uint16_t columns, uint16_t rows,
                 CGPTYLaunch *result) {
    *result = (CGPTYLaunch){ .pid = -1, .master_fd = -1, .error_stage = 1 };
    int errors[2] = {-1, -1}, permit[2] = {-1, -1};
    int code = 0;
    /* The Swift launch queue serializes descriptor setup with other PTY forks. */
    if (pipe(errors) < 0 || socketpair(AF_UNIX, SOCK_STREAM, 0, permit) < 0) code = errno;
    int no_sigpipe = 1;
    if (!code && (fcntl(errors[0], F_SETFD, FD_CLOEXEC) < 0 ||
                  fcntl(errors[1], F_SETFD, FD_CLOEXEC) < 0 ||
                  fcntl(permit[0], F_SETFD, FD_CLOEXEC) < 0 ||
                  fcntl(permit[1], F_SETFD, FD_CLOEXEC) < 0 ||
                  setsockopt(permit[1], SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) < 0)) code = errno;
    if (code) {
        for (int i = 0; i < 2; i++) {
            if (errors[i] >= 0) close(errors[i]);
            if (permit[i] >= 0) close(permit[i]);
        }
        return code;
    }
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    int master;
    pid_t pid = forkpty(&master, NULL, NULL, &size);
    if (pid < 0) {
        int code = errno;
        close(errors[0]); close(errors[1]);
        close(permit[0]); close(permit[1]);
        return code;
    }
    if (pid == 0) {
        close(errors[0]);
        close(permit[1]);
        /* Parent records the kernel birth identity before a fast exec can exit. */
        char token;
        ssize_t count;
        do { count = read(permit[0], &token, 1); } while (count < 0 && errno == EINTR);
        close(permit[0]);
        if (count != 1) { errno = EIO; child_failed(errors[1], 1); }
        /* The GUI/test host may ignore or block signals. A terminal child
         * needs normal job-control dispositions, independent of its host. */
        struct sigaction action = { .sa_handler = SIG_DFL };
        sigemptyset(&action.sa_mask);
        for (int signal = 1; signal < NSIG; signal++) {
            if (signal != SIGKILL && signal != SIGSTOP) sigaction(signal, &action, NULL);
        }
        sigset_t mask;
        sigemptyset(&mask);
        sigprocmask(SIG_SETMASK, &mask, NULL);
        if (chdir(directory) < 0) child_failed(errors[1], 2);
        execve(executable, argv, envp);
        child_failed(errors[1], 3);
    }
    close(errors[1]);
    close(permit[0]);
    if (fcntl(master, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(master, F_SETFL, O_NONBLOCK) < 0) {
        code = errno;
    }
    struct proc_bsdinfo identity;
    if (!code) {
        int count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity, sizeof(identity));
        if (count != sizeof(identity)) code = errno ? errno : ESRCH;
        else {
            result->start_seconds = identity.pbi_start_tvsec;
            result->start_microseconds = identity.pbi_start_tvusec;
            char token = 1;
            ssize_t written;
            do { written = write(permit[1], &token, 1); } while (written < 0 && errno == EINTR);
            if (written != 1) code = errno ? errno : EIO;
        }
    }
    close(permit[1]);
    if (!code) {
        struct pollfd ready = { .fd = errors[0], .events = POLLIN | POLLHUP };
        int polled;
        do { polled = poll(&ready, 1, 5000); } while (polled < 0 && errno == EINTR);
        if (polled <= 0) {
            code = polled == 0 ? ETIMEDOUT : errno;
        } else {
            LaunchError error;
            ssize_t count;
            do { count = read(errors[0], &error, sizeof(error)); }
            while (count < 0 && errno == EINTR);
            if (count == sizeof(error)) {
                result->error_stage = error.stage;
                code = error.code;
            } else if (count != 0) {
                code = count < 0 ? errno : EIO;
            }
            /* EOF means exec closed the close-on-exec error pipe. */
        }
    }
    close(errors[0]);
    if (code) {
        kill(pid, SIGKILL);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        close(master);
        return code;
    }
    result->pid = pid;
    result->master_fd = master;
    result->error_stage = 0;
    return 0;
}

int cg_pty_resize(int fd, uint16_t columns, uint16_t rows) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    return ioctl(fd, TIOCSWINSZ, &size);
}
int cg_wait_exited(int status) { return WIFEXITED(status); }
int cg_wait_exit_code(int status) { return WEXITSTATUS(status); }
int cg_wait_signaled(int status) { return WIFSIGNALED(status); }
int cg_wait_signal(int status) { return WTERMSIG(status); }
