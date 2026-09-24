#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <errno.h>
#include <signal.h>
#include <sys/mman.h>
#include <elf.h>

#ifndef NT_PRSTATUS
#define NT_PRSTATUS 1
#endif

#ifndef NT_ARM_SYSTEM_CALL
#define NT_ARM_SYSTEM_CALL 0x404
#endif

#ifndef PTRACE_O_EXITKILL
#define PTRACE_O_EXITKILL 0x00100000
#endif

struct custom_pt_regs {
    unsigned long long regs[31]; // x0 to x30
    unsigned long long sp;
    unsigned long long pc;
    unsigned long long pstate;
};

#define MAX_THREADS 1024

struct ThreadState {
    pid_t pid;
    int in_syscall;
} threads[MAX_THREADS];

int find_thread_index(pid_t pid) {
    for (int i = 0; i < MAX_THREADS; i++) {
        if (threads[i].pid == pid) {
            return i;
        }
    }
    return -1;
}

int get_thread_index(pid_t pid) {
    int idx = find_thread_index(pid);
    if (idx != -1) {
        return idx;
    }
    for (int i = 0; i < MAX_THREADS; i++) {
        if (threads[i].pid == 0) {
            threads[i].pid = pid;
            // Phase 0: a freshly seen thread's next syscall stop is an ENTRY
            // stop, so the toggle in the SIGTRAP|0x80 handler turns this into
            // in_syscall == 1 (entry) correctly. Seeding it with 1 would
            // invert entry/exit for the whole lifetime of that thread.
            threads[i].in_syscall = 0;
            return i;
        }
    }
    return -1;
}

void remove_thread(pid_t pid) {
    for (int i = 0; i < MAX_THREADS; i++) {
        if (threads[i].pid == pid) {
            threads[i].pid = 0;
            threads[i].in_syscall = 0;
            break;
        }
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <program> [args...]\n", argv[0]);
        return 1;
    }

    pid_t child = fork();
    if (child < 0) {
        perror("fork");
        return 1;
    }

    if (child == 0) {
        if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) < 0) {
            perror("ptrace TRACEME");
            exit(1);
        }
        raise(SIGSTOP);
        
        execvp(argv[1], &argv[1]);
        perror("execvp");
        exit(1);
    }

    int status;
    if (waitpid(child, &status, 0) < 0) {
        perror("waitpid");
        return 1;
    }

    long options = PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACECLONE | 
                   PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK | 
                   PTRACE_O_TRACEEXEC | PTRACE_O_TRACEEXIT |
                   PTRACE_O_EXITKILL;
    if (ptrace(PTRACE_SETOPTIONS, child, NULL, (void *)options) < 0) {
        perror("[TRACER ERROR] ptrace SETOPTIONS failed");
    }

    if (ptrace(PTRACE_SYSCALL, child, NULL, NULL) < 0) {
        perror("[TRACER ERROR] Initial ptrace SYSCALL failed");
    }

    memset(threads, 0, sizeof(threads));
    get_thread_index(child);

    while (1) {
        pid_t pid = waitpid(-1, &status, __WALL);
        if (pid < 0) {
            if (errno == ECHILD) {
                break;
            }
            if (errno == EINTR) {
                continue;
            }
            perror("waitpid");
            break;
        }

        if (WIFEXITED(status) || WIFSIGNALED(status)) {
            remove_thread(pid);
            if (pid == child) {
                if (WIFEXITED(status)) {
                    return WEXITSTATUS(status);
                } else {
                    return 128 + WTERMSIG(status);
                }
            }
            continue;
        }

        if (WIFSTOPPED(status)) {
            int sig = WSTOPSIG(status);
            int event = status >> 16;
            
            // --- DEFENSE LINE 2: Catch and swallow Seccomp SIGSYS crash signals ---
            if (sig == SIGSYS) {
                struct custom_pt_regs regs;
                struct iovec iov_regs;
                iov_regs.iov_base = &regs;
                iov_regs.iov_len = sizeof(regs);
                
                if (ptrace(PTRACE_GETREGSET, pid, (void *)NT_PRSTATUS, &iov_regs) == 0) {
                    regs.regs[0] = -38ULL; // Force return -ENOSYS
                    ptrace(PTRACE_SETREGSET, pid, (void *)NT_PRSTATUS, &iov_regs);
                }
                
                // Resume child with signal suppressed (0 instead of SIGSYS)
                if (ptrace(PTRACE_SYSCALL, pid, NULL, (void *)0) < 0) {
                    perror("[TRACER ERROR] ptrace SYSCALL failed to suppress SIGSYS");
                }
                continue;
            }
            
            if (sig == SIGTRAP && event == PTRACE_EVENT_EXEC) {
                memset(threads, 0, sizeof(threads));
                int idx = get_thread_index(pid);
                if (idx != -1) {
                    // After exec, the next stop is the first syscall ENTRY of the new image.
                    threads[idx].in_syscall = 0;
                }
                if (ptrace(PTRACE_SYSCALL, pid, NULL, NULL) < 0) {
                    perror("[TRACER ERROR] ptrace SYSCALL failed after EXEC");
                }
                continue;
            }
            
            if (sig == (SIGTRAP | 0x80)) {
                int idx = get_thread_index(pid);
                if (idx != -1) {
                    threads[idx].in_syscall = !threads[idx].in_syscall;
                    
                    if (threads[idx].in_syscall) {
                        // --- DEFENSE LINE 1: Intercept ENTRY stop for faccessat2 ---
                        int syscall_num;
                        struct iovec iov;
                        iov.iov_base = &syscall_num;
                        iov.iov_len = sizeof(syscall_num);
                        
                        if (ptrace(PTRACE_GETREGSET, pid, (void *)NT_ARM_SYSTEM_CALL, &iov) == 0) {
                            if (syscall_num == 439) { // __NR_faccessat2 on ARM64
                                syscall_num = -1;
                                if (ptrace(PTRACE_SETREGSET, pid, (void *)NT_ARM_SYSTEM_CALL, &iov) == 0) {
                                    struct custom_pt_regs regs;
                                    struct iovec iov_regs;
                                    iov_regs.iov_base = &regs;
                                    iov_regs.iov_len = sizeof(regs);
                                    
                                    if (ptrace(PTRACE_GETREGSET, pid, (void *)NT_PRSTATUS, &iov_regs) == 0) {
                                        regs.regs[0] = -38ULL; // -ENOSYS
                                        regs.regs[8] = -1ULL;
                                        ptrace(PTRACE_SETREGSET, pid, (void *)NT_PRSTATUS, &iov_regs);
                                    }
                                }
                            }
                        }
                    }
                }
                if (ptrace(PTRACE_SYSCALL, pid, NULL, NULL) < 0) {
                    if (errno != ESRCH) {
                        perror("[TRACER ERROR] ptrace SYSCALL failed after sysgood stop");
                    }
                }
                continue;
            }
            
            int deliver_sig = sig;
            if (sig == SIGTRAP) {
                // PTRACE event stops (clone/fork/vfork/exit) must NOT be delivered
                // to the tracee. A genuine SIGTRAP (event == 0) is a real trap and
                // must pass through, otherwise breakpoint/crash handling is masked.
                deliver_sig = (event != 0) ? 0 : sig;
            } else if (sig == SIGSTOP) {
                // Swallow ONLY the synthetic creation stop of a brand-new thread
                // (a pid we have never seen). A SIGSTOP aimed at an already-known
                // thread is a genuine signal (e.g. job control) and is delivered.
                deliver_sig = (find_thread_index(pid) < 0) ? 0 : sig;
            }

            if (ptrace(PTRACE_SYSCALL, pid, NULL, (void *)(long)deliver_sig) < 0) {
                if (errno != ESRCH) {
                    perror("[TRACER ERROR] ptrace SYSCALL failed for signal");
                }
            }
        }
    }

    return 0;
}
