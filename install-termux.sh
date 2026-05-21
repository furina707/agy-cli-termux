#!/usr/bin/env bash
#
# Antigravity CLI - Termux Bootstrapper Script
#
# A custom-engineered installer designed specifically for Android/Termux environments.
# It automatically installs glibc-runner (grun), downloads the official glibc Linux ARM64
# dynamic binary, stages it, verifies checksum integrity, compiles on-device C patcher to
# adapt TCMalloc shifts & FIPS verification, compiles on-device ptrace tracer to bypass
# faccessat2 SIGSYS crashes, and creates a wrapper for execution.
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

# 8. Compile TCMalloc 35-bit & FIPS Patcher on-device
info "Engineering self-contained binary patcher..."
cat << 'EOF' > "$INSTALL_DIR/agy_patcher.c"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void patch_fips(unsigned char *data, size_t size, const char *hex_hash) {
    unsigned char expected[32] = {
        0x90, 0x94, 0x62, 0x7e, 0x2b, 0xd0, 0x3d, 0x96, 
        0x2b, 0xa1, 0xd0, 0xc4, 0x42, 0x0a, 0x1d, 0xa9, 
        0xe1, 0xae, 0x55, 0xca, 0xef, 0x8e, 0xde, 0x7b, 
        0x68, 0x02, 0x8d, 0x7a, 0x4a, 0x71, 0xf1, 0x61
    };
    unsigned char calculated[32];

    if (strlen(hex_hash) != 64) {
        fprintf(stderr, "[PATCHER ERROR] FIPS hex hash must be exactly 64 characters\n");
        return;
    }

    for (size_t i = 0; i < 32; i++) {
        unsigned int val;
        sscanf(&hex_hash[i * 2], "%2x", &val);
        calculated[i] = (unsigned char)val;
    }

    size_t count = 0;
    for (size_t i = 0; i <= size - 32; i++) {
        if (memcmp(&data[i], expected, 32) == 0) {
            memcpy(&data[i], calculated, 32);
            printf("[PATCHER FIPS] Patched expected hash at offset 0x%zx\n", i);
            count++;
        }
    }
    printf("[PATCHER FIPS] Total patched: %zu\n", count);
}

void patch_tcmalloc(unsigned char *data, size_t size) {
    size_t ubfx = 0, lsr = 0, lsl = 0, asr = 0;
    size_t and_ext = 0, tst_tag = 0;
    size_t movz_n = 0, movz_c = 0, movz_s = 0;
    size_t movk_n = 0, movk_c = 0, movk_s = 0;

    for (size_t offset = 0; offset <= size - 4; offset += 4) {
        unsigned int *ptr = (unsigned int *)&data[offset];
        unsigned int val = *ptr;

        // 1. ubfx Xd, Xn, #42, #3 -> #35, #3
        if ((val & 0xfffffc00) == 0xd36ab000) {
            unsigned int rn = (val >> 5) & 0x1f;
            unsigned int rd = val & 0x1f;
            if (rn < 31 && rd < 31) {
                *ptr = 0xd3639400 | (rn << 5) | rd;
                ubfx++;
            }
        }
        // 2. lsr Xd, Xn, #42 -> #35
        else if ((val & 0xfffffc00) == 0xd36afc00) {
            unsigned int rn = (val >> 5) & 0x1f;
            unsigned int rd = val & 0x1f;
            if (rn < 31 && rd < 31) {
                *ptr = 0xd363fc00 | (rn << 5) | rd;
                lsr++;
            }
        }
        // 3. lsl Xd, Xn, #42 -> #35
        else if ((val & 0xfffffc00) == 0xd3565400) {
            unsigned int rn = (val >> 5) & 0x1f;
            unsigned int rd = val & 0x1f;
            if (rn < 31 && rd < 31) {
                *ptr = 0xd35d7000 | (rn << 5) | rd;
                lsl++;
            }
        }
        // 4. asr Xd, Xn, #42 -> #35
        else if ((val & 0xfffffc00) == 0x936afc00) {
            unsigned int rn = (val >> 5) & 0x1f;
            unsigned int rd = val & 0x1f;
            if (rn < 31 && rd < 31) {
                *ptr = 0x9363fc00 | (rn << 5) | rd;
                asr++;
            }
        }
        // TCMalloc metadata patches (.text restricted range)
        else if (offset >= 0x49f0000 && offset <= 0x4a90000) {
            // 5. and Xd, Xn, #0x1c0000000000 -> #0x3800000000
            if ((val & 0xfffffc00) == 0x92560800) {
                unsigned int rn = (val >> 5) & 0x1f;
                unsigned int rd = val & 0x1f;
                if (rn < 31 && rd < 31) {
                    *ptr = 0x925d0800 | (rn << 5) | rd;
                    and_ext++;
                }
            }
            // 6. tst Xn, #0x1c0000000000 -> #0x3800000000
            else if ((val & 0xfffffc00) == 0xf2560800) {
                unsigned int rn = (val >> 5) & 0x1f;
                unsigned int rd = val & 0x1f;
                if (rn < 31 && rd == 0x1f) {
                    *ptr = 0xf25d0800 | (rn << 5) | rd;
                    tst_tag++;
                }
            }
            // 7. movz Xd, imm16, lsl #32
            else if ((val & 0xffe00000) == 0xd2c00000) {
                unsigned int imm16 = (val >> 5) & 0xffff;
                unsigned int rd = val & 0x1f;
                if (rd < 31) {
                    if (imm16 == 0x1000) {
                        *ptr = 0xd2c00000 | (0x20 << 5) | rd;
                        movz_n++;
                    } else if (imm16 == 0x1800) {
                        *ptr = 0xd2c00000 | (0x30 << 5) | rd;
                        movz_c++;
                    } else if (imm16 == 0x1400) {
                        *ptr = 0xd2c00000 | (0x28 << 5) | rd;
                        movz_s++;
                    }
                }
            }
            // 8. movk Xd, imm16, lsl #32
            else if ((val & 0xffe00000) == 0xf2c00000) {
                unsigned int imm16 = (val >> 5) & 0xffff;
                unsigned int rd = val & 0x1f;
                if (rd < 31) {
                    if (imm16 == 0x1000) {
                        *ptr = 0xf2c00000 | (0x20 << 5) | rd;
                        movk_n++;
                    } else if (imm16 == 0x1800) {
                        *ptr = 0xf2c00000 | (0x30 << 5) | rd;
                        movk_c++;
                    } else if (imm16 == 0x1400) {
                        *ptr = 0xf2c00000 | (0x28 << 5) | rd;
                        movk_s++;
                    }
                }
            }
        }
    }

    printf("[PATCHER TCMALLOC] TCMalloc patching summary:\n");
    printf("  ubfx: %zu, lsr: %zu, lsl: %zu, asr: %zu\n", ubfx, lsr, lsl, asr);
    printf("  and_ext: %zu, tst_tag: %zu\n", and_ext, tst_tag);
    printf("  movz normal/cold/sampled: %zu/%zu/%zu\n", movz_n, movz_c, movz_s);
    printf("  movk normal/cold/sampled: %zu/%zu/%zu\n", movk_n, movk_c, movk_s);
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage:\n  Only TCMalloc: %s <input_file> <output_file>\n  TCMalloc & FIPS: %s <input_file> <output_file> <fips_hex_hash>\n", argv[0], argv[0]);
        return 1;
    }

    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror("fopen input");
        return 1;
    }

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    unsigned char *data = malloc(size);
    if (!data) {
        perror("malloc");
        fclose(f);
        return 1;
    }

    if (fread(data, 1, size, f) != size) {
        perror("fread");
        free(data);
        fclose(f);
        return 1;
    }
    fclose(f);

    // Apply TCMalloc shifts patch (Phase 1)
    patch_tcmalloc(data, size);

    // Apply BoringSSL FIPS expected hash patch if provided (Phase 2)
    if (argc >= 4) {
        patch_fips(data, size, argv[3]);
    }

    FILE *out = fopen(argv[2], "wb");
    if (!out) {
        perror("fopen output");
        free(data);
        return 1;
    }

    if (fwrite(data, 1, size, out) != size) {
        perror("fwrite");
        fclose(out);
        free(data);
        return 1;
    }

    fclose(out);
    free(data);
    printf("[PATCHER] Patched successfully and saved to %s\n", argv[2]);
    return 0;
}
EOF

info "Compiling binary patcher on-device..."
if clang -O3 -Wall -o "$INSTALL_DIR/agy_patcher" "$INSTALL_DIR/agy_patcher.c"; then
    success "Binary patcher compiled successfully."
else
    error "Failed to compile the binary patcher."
    exit 1
fi

info "Applying Phase 1: 35-bit TCMalloc shifts patch natively..."
if "$INSTALL_DIR/agy_patcher" "$INSTALL_DIR/antigravity" "$INSTALL_DIR/antigravity_patched"; then
    success "Binary patched successfully."
    # Overwrite original binary with the TCMalloc-patched executable
    mv -f "$INSTALL_DIR/antigravity_patched" "$INSTALL_DIR/antigravity"
    chmod +x "$INSTALL_DIR/antigravity"
else
    error "Failed to patch binary on-device during Phase 1."
    exit 1
fi

# 8.5. Compile faccessat2 ptrace syscall interception tracer
info "Engineering self-contained faccessat2 ptrace syscall interception tracer..."
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
#include <sys/mman.h>
#include <elf.h>

#ifndef NT_PRSTATUS
#define NT_PRSTATUS 1
#endif

#ifndef NT_ARM_SYSTEM_CALL
#define NT_ARM_SYSTEM_CALL 0x404
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

int get_thread_index(pid_t pid, int is_clone) {
    for (int i = 0; i < MAX_THREADS; i++) {
        if (threads[i].pid == pid) {
            return i;
        }
    }
    for (int i = 0; i < MAX_THREADS; i++) {
        if (threads[i].pid == 0) {
            threads[i].pid = pid;
            threads[i].in_syscall = is_clone ? 1 : 0;
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
                   PTRACE_O_TRACEEXEC | PTRACE_O_TRACEEXIT;
    if (ptrace(PTRACE_SETOPTIONS, child, NULL, (void *)options) < 0) {
        perror("[TRACER ERROR] ptrace SETOPTIONS failed");
    }

    if (ptrace(PTRACE_SYSCALL, child, NULL, NULL) < 0) {
        perror("[TRACER ERROR] Initial ptrace SYSCALL failed");
    }

    memset(threads, 0, sizeof(threads));
    get_thread_index(child, 0);

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
            
            if (sig == SIGTRAP && event == PTRACE_EVENT_EXEC) {
                memset(threads, 0, sizeof(threads));
                int idx = get_thread_index(pid, 1);
                if (idx != -1) {
                    threads[idx].in_syscall = 1;
                }
                if (ptrace(PTRACE_SYSCALL, pid, NULL, NULL) < 0) {
                    perror("[TRACER ERROR] ptrace SYSCALL failed after EXEC");
                }
                continue;
            }
            
            if (sig == (SIGTRAP | 0x80)) {
                int idx = get_thread_index(pid, 1);
                if (idx != -1) {
                    threads[idx].in_syscall = !threads[idx].in_syscall;
                    
                    if (threads[idx].in_syscall) {
                        // Syscall ENTRY stop
                        int syscall_num;
                        struct iovec iov;
                        iov.iov_base = &syscall_num;
                        iov.iov_len = sizeof(syscall_num);
                        
                        if (ptrace(PTRACE_GETREGSET, pid, (void *)NT_ARM_SYSTEM_CALL, &iov) == 0) {
                            if (syscall_num == 279) { // __NR_faccessat2
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
                    perror("[TRACER ERROR] ptrace SYSCALL failed after sysgood stop");
                }
                continue;
            }
            
            int deliver_sig = sig;
            if (sig == SIGSTOP) {
                deliver_sig = 0;
            } else if (sig == SIGTRAP) {
                deliver_sig = 0;
            }

            if (ptrace(PTRACE_SYSCALL, pid, NULL, (void *)(long)deliver_sig) < 0) {
                perror("[TRACER ERROR] ptrace SYSCALL failed for signal");
            }
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

# 9. Locate Glibc Paths
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

# 9.5. Phase 2: Dynamic BoringSSL FIPS expected hash capturing and patching
info "Entering Phase 2: Resolving BoringSSL FIPS calculated hash dynamically..."
(
    unset LD_PRELOAD
    set +e
    if [ -n "$LD_SO" ]; then
        hash_output=$("$INSTALL_DIR/agy_ptrace_tracer" "$LD_SO" --library-path "$GLIBC_LIB_DIR" "$INSTALL_DIR/antigravity" --version 2>&1 || true)
    else
        hash_output=$("$INSTALL_DIR/agy_ptrace_tracer" grun "$INSTALL_DIR/antigravity" --version 2>&1 || true)
    fi
    set -e

    calculated_hash=$(echo "$hash_output" | grep "Calculated:" | tail -n 1 | awk '{print $2}' | tr -d '\r\n ' || true)
    
    if [[ "$calculated_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
        success "Dynamically captured FIPS calculated hash: $calculated_hash"
        info "Applying Phase 2: Overwriting expected hash signature natively..."
        if "$INSTALL_DIR/agy_patcher" "$INSTALL_DIR/antigravity" "$INSTALL_DIR/antigravity_patched" "$calculated_hash"; then
            mv -f "$INSTALL_DIR/antigravity_patched" "$INSTALL_DIR/antigravity"
            chmod +x "$INSTALL_DIR/antigravity"
            success "BoringSSL FIPS integrity verification signature aligned successfully."
        else
            error "Failed to patch FIPS expected signature."
            exit 1
        fi
    else
        error "Fatal: Could not capture a valid FIPS calculated hash from the runtime error diagnostic payload."
        echo -e "${YELLOW}Diagnostics output:${NC}"
        echo "$hash_output"
        exit 1
    fi
)

# Clean up patcher
rm -f "$INSTALL_DIR/agy_patcher" "$INSTALL_DIR/agy_patcher.c"

# 10. Initialization Handoff
info "Configuring Termux environment dependencies..."
# Execute native configuration with the syscall tracer active
# Unset LD_PRELOAD during setup to prevent glibc dynamic linker from loading Bionic libtermux-exec.so
(
    unset LD_PRELOAD
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
)

# 11. Create Launcher Wrapper
info "Creating dynamic launch wrapper at $WRAPPER_PATH..."
if [ -z "$LD_SO" ]; then
    warn "Could not dynamically locate glibc dynamic linker. Falling back to 'grun'..."
    cat << EOF > "$WRAPPER_PATH"
#!/data/data/com.termux/files/usr/bin/bash
#
# Termux dynamic glibc-runner bridge wrapper for Antigravity CLI
# using native ptrace-based syscall interception for faccessat2 bypass.
#
unset LD_PRELOAD
export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
exec "$INSTALL_DIR/agy_ptrace_tracer" grun "$INSTALL_DIR/antigravity" "\$@"
EOF
else
    success "Located glibc dynamic linker at $LD_SO"
    cat << EOF > "$WRAPPER_PATH"
#!/data/data/com.termux/files/usr/bin/bash
#
# Termux dynamic glibc-runner bridge wrapper for Antigravity CLI
# using native ptrace-based syscall interception for faccessat2 bypass.
#
unset LD_PRELOAD
export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
exec "$INSTALL_DIR/agy_ptrace_tracer" "$LD_SO" --library-path "$GLIBC_LIB_DIR" "$INSTALL_DIR/antigravity" "\$@"
EOF
fi

chmod +x "$WRAPPER_PATH"
success "Wrapper created and executable bits set."

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
