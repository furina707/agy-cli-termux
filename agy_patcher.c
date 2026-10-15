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

    if (size < 32) {
        fprintf(stderr, "[PATCHER ERROR] Input too small for FIPS scan (%zu bytes)\n", size);
        return;
    }

    if (strlen(hex_hash) != 64) {
        fprintf(stderr, "[PATCHER ERROR] FIPS hex hash must be exactly 64 characters\n");
        return;
    }

    for (size_t i = 0; i < 32; i++) {
        unsigned int val = 0;
        if (sscanf(&hex_hash[i * 2], "%2x", &val) != 1) {
            fprintf(stderr, "[PATCHER ERROR] FIPS hash contains non-hex characters\n");
            return;
        }
        calculated[i] = (unsigned char)val;
    }

    size_t count = 0;
    for (size_t i = 0; i + 32 <= size; i++) {
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

    if (size < 4) {
        fprintf(stderr, "[PATCHER ERROR] Input too small for TCMalloc scan (%zu bytes)\n", size);
        return;
    }

    for (size_t offset = 0; offset + 4 <= size; offset += 4) {
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

    if (fseek(f, 0, SEEK_END) != 0) {
        perror("fseek");
        fclose(f);
        return 1;
    }
    long size = ftell(f);
    if (size <= 0) {
        fprintf(stderr, "[PATCHER ERROR] Invalid input size: %ld\n", size);
        fclose(f);
        return 1;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        perror("fseek");
        fclose(f);
        return 1;
    }

    unsigned char *data = malloc((size_t)size);
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
