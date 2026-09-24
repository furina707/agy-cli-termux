# Antigravity CLI - Termux 适配器

在 Android Termux 中，通过自定义的 `glibc-runner`（`grun`）桥接环境 + 二进制补丁 + ptrace 系统调用拦截，
原生且无缝地运行专为标准 Linux ARM64 (glibc) 编译的 **Antigravity CLI**。

---

## 问题背景

Antigravity CLI 官方发布的 Linux ARM64 二进制文件是针对标准 Linux 平台编译的，静态链接了 **glibc**（GNU C 运行库）
与 **TCMalloc** 内存分配器。然而：

- Android 系统（及 Termux 容器）底层采用 **Bionic libc**，无法直接加载 glibc 动态链接器
- Android ARM64 内核配置为 **39-bit 虚拟地址空间**（上限 `0x8000000000`），而 TCMalloc 硬编码假定 **48-bit 空间**
  并尝试 `mmap` 超高地址（如 `hint=0x4e88c0000000`），导致 `MmapAligned() failed` 崩溃
- Antigravity CLI 使用了 seccomp 沙箱，其中 `faccessat2`（syscall 439）在 Android 低版本内核中缺失，触发 `SIGSYS` 信号杀死进程

---

## 解决方案

本项目通过四层适配解决全部兼容性问题：

### 1. glibc-runner 桥接层
自动安装 `glibc-runner`（`grun`），提供 glibc 动态链接器和库路径，使标准 Linux ARM64 二进制可以在 Termux 中加载执行。

### 2. TCMalloc 35-bit 地址空间降维补丁
在 Termux 本地通过 `clang` 编译一个二进制补丁工具，扫描 ELF 中 TCMalloc 的指令编码，将：

- `ubfx Xd, Xn, #42, #3` → `#35, #3`
- `lsr/lsl/asr Xd, Xn, #42` → `#35`
- `movz/movk Xd, #0x1000/0x1800/0x1400, lsl #32` → `#0x20/0x30/0x28`
- `and Xd, Xn, #0x1c0000000000` → `#0x3800000000`
- `tst Xn, #0x1c0000000000` → `#0x3800000000`

从而将所有 48-bit 地址常量降为 35-bit，适配 Android 39-bit 地址空间。

### 3. BoringSSL FIPS 完整性签名补丁
BoringSSL FIPS 模块在初始化时会校验自身的预期哈希值，与运行时计算的实际哈希比对。补丁工具从运行时错误信息中动态捕获实际哈希值，然后用它覆写二进制中的预期哈希，使 FIPS 自检通过。

### 4. ptrace 系统调用拦截器
本地编译一个 ptrace tracer 子进程，拦截被追踪进程的系统调用：

- **防御层 1**：在 syscall 入口拦截 `faccessat2`（syscall 439），将其替换为 `-1` 并返回 `-ENOSYS`
- **防御层 2**：捕获 seccomp 触发的 `SIGSYS` 信号，强制修改返回值为 `-ENOSYS` 后继续运行

### 架构图

```
用户输入命令 [agy]
       │
       ▼
执行路径启动器包装脚本 [$PREFIX/bin/agy]
       │ (设置 SSL_CERT_FILE, CURL_CA_BUNDLE 等环境变量)
       ▼
ptrace 系统调用拦截器 [agy_ptrace_tracer]
       │ (通过 ptrace 拦截 faccessat2 / SIGSYS)
       ▼
glibc-runner 解释器 [grun] 或 直接调用 glibc 动态链接器 [ld-linux-aarch64.so.1]
       │ (加载 glibc 动态运行库环境)
       ▼
执行已修补的官方 Linux ARM64 原生 ELF 二进制文件
       │ (TCMalloc 35-bit 降维 + FIPS 签名已修补)
```

### 安全性

- 所有代码在 Termux 本地通过 `clang` 即时编译，不下载预编译二进制
- 官方二进制下载后经过 SHA512 完整性校验
- 不对内核或系统分区做任何修改

---

## 安装与部署

在您的 **Termux** 终端中拷贝并运行以下一键安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/furina707/agy-cli-termux/main/install-termux.sh | bash
```

或者，您也可以先克隆本仓库到本地，然后运行安装脚本：

```bash
git clone https://github.com/furina707/agy-cli-termux.git
cd agy-cli-termux
bash install-termux.sh
```

### 前置依赖

安装脚本会自动处理以下依赖：
- `grun`（glibc-runner）
- `clang` 编译器
- `ca-certificates`（HTTPS 证书，用于 OAuth2 认证）
- `curl` 或 `wget`
- `tar`、`sha512sum`

---

## 验证与使用

安装完成后，直接调用系统注册的包装器命令以验证版本：

```bash
agy --version
```

在 Termux 终端中启动您的智能编程助理：

```bash
agy
```

首次运行需要通过浏览器完成 Google OAuth2 认证。

---

## 常见问题

### OAuth2 token exchange 失败

如果 `agy` 在执行 `agy auth login` 时提示连接错误，通常是因为 CA 证书或网络代理问题：

1. 确认 `ca-certificates` 包已安装：
   ```bash
   pkg install ca-certificates
   ```
2. 如果使用代理（如 Clash、v2ray），设置环境变量：
   ```bash
   export HTTP_PROXY=http://127.0.0.1:7890
   export HTTPS_PROXY=http://127.0.0.1:7890
   agy auth login
   ```
3. 确认 SSL_CERT_FILE 路径正确：
   ```bash
   ls -l $SSL_CERT_FILE
   ```

### 安全升级

由于 Termux 下的 agy 包含 35-bit 降维与 FIPS 完整性签名补丁，直接运行 `agy update` 会导致补丁失效。
请使用以下命令进行安全升级：

```bash
curl -fsSL https://raw.githubusercontent.com/furina707/agy-cli-termux/main/install-termux.sh | bash
```

---

## 许可证

本项目基于 MIT 许可证开源。
