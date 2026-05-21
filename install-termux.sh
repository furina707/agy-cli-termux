#!/usr/bin/env bash
#
# Antigravity CLI - Termux Bootstrapper Script
#
# A custom-engineered installer designed specifically for Android/Termux environments.
# It automatically installs glibc-runner (grun), downloads the official glibc Linux ARM64
# dynamic binary, stages it, verifies checksum integrity, and creates a wrapper for execution.
#

set -euo pipefail

# 1. Color and Output Theme
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0;0m' # No Color

info() { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1" >&2; }

echo -e "${CYAN}==================================================${NC}"
echo -e "${CYAN}        Antigravity CLI - Termux Installer        ${NC}"
echo -e "${CYAN}==================================================${NC}"
echo ""

# 2. Check Architecture & OS
info "Detecting system environment..."
if [[ "$(uname -s)" != "Linux" ]]; then
    error "This script is customized specifically for Linux (Termux on Android). For standard OS, use the official script."
    exit 1
fi

case "$(uname -m)" in
    aarch64|arm64) arch="arm64" ;;
    *)
        error "Unsupported architecture: $(uname -m). Antigravity Termux adapter is optimized for 64-bit ARM CPUs (aarch64)."
        exit 1
        ;;
esac
success "Device architecture verified: aarch64 (ARM64)"

# 3. Resolve Termux Directories
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
STAGING_DIR="$HOME/.cache/antigravity/staging"
INSTALL_DIR="$PREFIX/lib/antigravity"
WRAPPER_PATH="$PREFIX/bin/agy"

# Ensure crucial directories exist
mkdir -p "$PREFIX/bin" "$STAGING_DIR" "$INSTALL_DIR"

# 4. Install & Verify glibc-runner (grun)
if ! command -v grun &>/dev/null; then
    info "glibc-runner (grun) not found. Attempting automatic installation..."
    if command -v pkg &>/dev/null; then
        info "Updating and upgrading Termux packages (this may take a moment)..."
        pkg update -y || true
        pkg upgrade -y -o Dpkg::Options::="--force-confold" || true
        
        # Install glibc-repo first to make glibc-runner package available
        info "Installing glibc-repo repository dependency..."
        pkg install -y glibc-repo || true
        pkg update -y || true
        
        info "Installing glibc-runner package..."
        if pkg install -y glibc-runner || pkg install -y grun; then
            if command -v grun &>/dev/null; then
                success "glibc-runner (grun) installed successfully."
            else
                error "Package appeared to install, but 'grun' command is still not found."
                exit 1
            fi
        else
            echo ""
            error "Failed to install 'glibc-runner' automatically."
            echo -e "${YELLOW}💡 Troubleshooting Steps:${NC}"
            echo -e "  1. Your current Termux mirror might be outdated or unreachable."
            echo -e "     Please run ${CYAN}termux-change-repo${NC} and select an official, updated mirror (e.g., Tsinghua, BFSU, or F-Droid)."
            echo -e "  2. Perform a complete package upgrade:"
            echo -e "     ${CYAN}pkg update && pkg upgrade -y${NC}"
            echo -e "  3. Manually try to install glibc-runner:"
            echo -e "     ${CYAN}pkg install -y glibc-repo && pkg install -y glibc-runner${NC}"
            echo ""
            exit 1
        fi
    else
        error "Package manager 'pkg' not found. Are you sure you are inside Termux?"
        exit 1
    fi
else
    success "glibc-runner (grun) is already installed."
fi

# 4.5 Install & Verify Clang compiler
if ! command -v clang &>/dev/null; then
    info "Clang compiler not found. Attempting automatic installation..."
    if pkg install -y clang; then
        success "Clang compiler installed successfully."
    else
        error "Failed to install 'clang' automatically."
        exit 1
    fi
else
    success "Clang compiler is already installed."
fi

# 5. Fetch Manifest
DOWNLOAD_BASE_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app"
MANIFEST_URL="$DOWNLOAD_BASE_URL/manifests/linux_arm64.json"

info "Querying release repository manifest..."
DOWNLOADER=""
if command -v curl &>/dev/null; then
    DOWNLOADER="curl"
elif command -v wget &>/dev/null; then
    DOWNLOADER="wget"
else
    error "Either curl or wget is required but neither is installed."
    exit 1
fi

fetch_url() {
    if [ "$DOWNLOADER" = "curl" ]; then
        curl -fsSL "$1"
    else
        wget -q -O - "$1"
    fi
}

manifest_json=$(fetch_url "$MANIFEST_URL" 2>/dev/null || true)
if [ -z "$manifest_json" ]; then
    error "Could not connect to the release server to download the manifest."
    exit 1
fi

parse_json_key() {
    local payload="$1"
    local key="$2"
    echo "$payload" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

version=$(parse_json_key "$manifest_json" "version")
url=$(parse_json_key "$manifest_json" "url")
sha512=$(parse_json_key "$manifest_json" "sha512")

if [ -z "$url" ] || [ -z "$sha512" ]; then
    error "Failed to parse release manifest. The manifest may be corrupted or malformed."
    exit 1
fi

success "Latest available Antigravity CLI version: $version"

# 6. Download & SHA512 Verification
staging_payload="$STAGING_DIR/agy.tar.gz"

cleanup() {
    rm -f "$staging_payload" 2>/dev/null || true
}
trap cleanup EXIT

info "Downloading release package..."
if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL -o "$staging_payload" "$url"
else
    wget -q -O "$staging_payload" "$url"
fi

info "Verifying package integrity..."
actual_hash=$(sha512sum "$staging_payload" | cut -d' ' -f1 || true)

if [ "$actual_hash" != "$sha512" ]; then
    error "Security Halt: The downloaded payload checksum does not match the manifest."
    exit 1
fi
success "Download complete and checksum verified."

# 7. Extract Binary
info "Extracting binary..."
if ! tar -xzf "$staging_payload" -C "$INSTALL_DIR" antigravity 2>/dev/null; then
    error "Failed to extract binary from archive."
    exit 1
fi
chmod +x "$INSTALL_DIR/antigravity"
success "Binary staged successfully."

# 8. Compile TCMalloc 48-bit Virtual Address Tracer
info "Engineering self-contained ptrace syscall interception tracer..."
cat << 'EOF' > "$INSTALL_DIR/agy_ptrace_tracer.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <errno.h>
#include <signal.h>

#ifndef NT_PRSTATUS
#define NT_PRSTATUS 1
#endif

// ARM64 register structure as defined by the ARM64 Linux ABI
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

int get_thread_index(pid_t pid) {
    for (int i = 0; i < MAX_THREADS; i++) {
        if (threads[i].pid == pid) {
            return i;
        }
    }
    for (int i = 0; i < MAX_THREADS; i++) {
        if (threads[i].pid == 0) {
            threads[i].pid = pid;
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
        // Child: attach and stop before executing
        if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) < 0) {
            perror("ptrace TRACEME");
            exit(1);
        }
        raise(SIGSTOP);
        
        execvp(argv[1], &argv[1]);
        perror("execvp");
        exit(1);
    }

    // Parent
    int status;
    if (waitpid(child, &status, 0) < 0) {
        perror("waitpid");
        return 1;
    }

    // Configure options to trace child, clones, forks, and enable sysgood stops (SIGTRAP | 0x80)
    long options = PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACECLONE | 
                   PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK | 
                   PTRACE_O_TRACEEXEC | PTRACE_O_TRACEEXIT;
    ptrace(PTRACE_SETOPTIONS, child, NULL, (void *)options);

    // Start system call tracing
    ptrace(PTRACE_SYSCALL, child, NULL, NULL);

    memset(threads, 0, sizeof(threads));

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
            
            if (sig == (SIGTRAP | 0x80)) {
                int idx = get_thread_index(pid);
                if (idx != -1) {
                    threads[idx].in_syscall = !threads[idx].in_syscall;
                    
                    if (threads[idx].in_syscall) {
                        struct custom_pt_regs regs;
                        struct iovec iov;
                        iov.iov_base = &regs;
                        iov.iov_len = sizeof(regs);
                        
                        if (ptrace(PTRACE_GETREGSET, pid, (void *)NT_PRSTATUS, &iov) == 0) {
                            // On AArch64:
                            // regs.regs[8] is x8 (syscall number)
                            // regs.regs[0] is x0 (first argument - hint address)
                            // __NR_mmap is 222
                            if (regs.regs[8] == 222) {
                                unsigned long long hint = regs.regs[0];
                                if (hint >= 0x8000000000ULL) { // 39-bit VA space limit (512GB)
                                    regs.regs[0] = 0; // Strip the high address hint to NULL
                                    ptrace(PTRACE_SETREGSET, pid, (void *)NT_PRSTATUS, &iov);
                                }
                            }
                        }
                    }
                }
                ptrace(PTRACE_SYSCALL, pid, NULL, NULL);
                continue;
            }
            
            // Forward signal to the tracee
            int deliver_sig = (sig == SIGTRAP || sig == (SIGTRAP | 0x80)) ? 0 : sig;
            ptrace(PTRACE_SYSCALL, pid, NULL, (void *)(long)deliver_sig);
        }
    }

    return 0;
}
EOF

info "Compiling virtual address tracer on-device..."
if clang -O3 -Wall -o "$INSTALL_DIR/agy_ptrace_tracer" "$INSTALL_DIR/agy_ptrace_tracer.c"; then
    success "Self-contained ptrace tracer compiled successfully."
else
    error "Failed to compile the ptrace tracer. Verify your Termux compiler setup."
    exit 1
fi

# Remove temporary source file to keep installation clean
rm -f "$INSTALL_DIR/agy_ptrace_tracer.c"

# 9. Create Launcher Wrapper
info "Locating glibc dynamic linker and library path..."
GLIBC_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}/glibc"
LD_SO=""
if [ -f "$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1" ]; then
    LD_SO="$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1"
elif [ -f "$GLIBC_PREFIX/lib/ld.so" ]; then
    LD_SO="$GLIBC_PREFIX/lib/ld.so"
else
    # Fallback search
    LD_SO=$(find "$GLIBC_PREFIX" -name "ld-linux-aarch64.so.1" -o -name "ld.so" 2>/dev/null | head -n 1 || true)
fi

GLIBC_LIB_DIR=""
if [ -n "$LD_SO" ]; then
    GLIBC_LIB_DIR=$(dirname "$LD_SO")
else
    GLIBC_LIB_DIR="$GLIBC_PREFIX/lib"
fi

info "Creating dynamic launch wrapper at $WRAPPER_PATH..."
if [ -z "$LD_SO" ]; then
    warn "Could not dynamically locate glibc dynamic linker. Falling back to 'grun'..."
    cat << EOF > "$WRAPPER_PATH"
#!/data/data/com.termux/files/usr/bin/bash
#
# Termux dynamic glibc-runner bridge wrapper for Antigravity CLI
# using native ptrace-based syscall interception for TCMalloc mapping correction.
#
exec "$INSTALL_DIR/agy_ptrace_tracer" grun "$INSTALL_DIR/antigravity" "\$@"
EOF
else
    success "Located glibc dynamic linker at $LD_SO"
    cat << EOF > "$WRAPPER_PATH"
#!/data/data/com.termux/files/usr/bin/bash
#
# Termux dynamic glibc-runner bridge wrapper for Antigravity CLI
# using native ptrace-based syscall interception for TCMalloc mapping correction.
#
exec "$INSTALL_DIR/agy_ptrace_tracer" "$LD_SO" --library-path "$GLIBC_LIB_DIR" "$INSTALL_DIR/antigravity" "\$@"
EOF
fi

chmod +x "$WRAPPER_PATH"
success "Wrapper created and executable bits set."

# 10. Initialization Handoff
info "Configuring Termux environment dependencies..."
# Execute native configuration with the syscall tracer active
if [ -n "$LD_SO" ]; then
    if "$INSTALL_DIR/agy_ptrace_tracer" "$LD_SO" --library-path "$GLIBC_LIB_DIR" "$INSTALL_DIR/antigravity" install --dir "$PREFIX/bin" 2>/dev/null || true; then
        success "Shell configurations initialized."
    else
        warn "Soft-warning: Initial configuration setup threw non-fatal warnings."
    fi
else
    if "$INSTALL_DIR/agy_ptrace_tracer" grun "$INSTALL_DIR/antigravity" install --dir "$PREFIX/bin" 2>/dev/null || true; then
        success "Shell configurations initialized."
    else
        warn "Soft-warning: Initial configuration setup threw non-fatal warnings."
    fi
fi

echo ""
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}🎉 Antigravity CLI successfully installed on Termux!${NC}"
echo -e "${GREEN}==================================================${NC}"
echo ""
echo -e "You can now run the tool directly using:"
echo -e "  ${CYAN}agy${NC}"
echo ""
echo -e "To verify installation, run:"
echo -e "  ${CYAN}agy --version${NC}"
echo ""
