# Antigravity CLI - Termux 适配器

在 Android Termux 中，通过自定义的 `glibc-runner`（`grun`）桥接环境，原生且无缝地运行专为标准 Linux ARM64 (glibc) 编译的 **Antigravity CLI**。

---

## 💡 问题背景

Antigravity CLI 官方发布的 Linux ARM64 二进制文件是针对标准 Linux 平台编译的，静态或动态链接了 **`glibc`**（GNU C 运行库）。
然而，Android 系统（及 Termux 容器）底层采用的是 Google 专有的 **`Bionic libc`**，且不遵循传统的 Linux 文件系统层级标准（FHS）。
因此，直接在 Termux 原生环境下运行该二进制文件会导致动态链接器缺失，抛出类似 `No such file or directory` 或 `exec format error` 的错误。

---

## ⚡ 解决方案 (方案 B)

本项目通过自动配置 **`glibc-runner` (`grun`)** 建立一个轻量级的动态兼容桥梁，并集成了定制的内存垫片，彻底解决兼容性问题。

### 🌟 TCMalloc 48-bit 虚拟地址空间崩溃修复
官方编译的 Linux ARM64 二进制文件静态链接了 Google 的 **TCMalloc** 高性能内存分配器。该分配器硬编码假定操作系统拥有 **48-bit 虚拟地址空间**（桌面/服务器 Linux 标准），并在初始化时尝试 `mmap` 寻址超高的地址空间（例如错误日志中的 `hint=0x4e88c0000000`，即 ~78.5 TiB 处）。
然而，几乎所有 Android 设备的 ARM64 内核均配置为 **39-bit 虚拟地址空间**（最大寻址空间为 512 GiB，即上限为 `0x8000000000`）。当静态 TCMalloc 触发建议地址位于 48-bit 的 `mmap` 系统调用时，Android 内核将直接拒绝该越界寻址，导致程序抛出 `MmapAligned() failed - unable to allocate with tag` 并 Fatal OOM 闪退。

为了在**不修改内核、不改变 PRoot 隔离、不重构官方静态二进制程序**的前提下解决该底层硬件/内核级限制，本项目实现了以下高阶适配方案：
1. **本地自包含即时编译**：适配脚本将自动在 Termux 本地通过 `clang` 即时编译一个垫片库 `libmmap_shim.so`。
2. **纯自包含零依赖 (-nostdlib)**：垫片库采用纯自包含设计（不依赖任何 glibc 或 Bionic libc 动态库），使得它可以被 Bionic linker（如运行中的包装脚本或 `grun` 自身）与 Glibc Linker（如 `agy` 原生程序）同时安全加载，**不产生任何 dynamic linker 警告或运行时符号冲突**。
3. **高位建议地址过滤**：使用底层的 ARM64 原生内联汇编系统调用指令（`svc #0`）代理 `mmap` 和 `mmap64`。当检测到 `addr` 建议参数超出 39-bit（`>= 0x8000000000`）时，垫片自动将其剥离重置为 `NULL`，强制内核分配安全的 39-bit 虚拟内存空间（完美兼容 48-bit  radix 树的低位寻址）。
4. **环境包装拦截**：生成执行包装器 `$PREFIX/bin/agy`，通过预加载（`LD_PRELOAD`）把垫片无感知地注入到执行会话中，实现完美平滑启动。

本安装适配脚本 (`install-termux.sh`) 将自动完成以下工作：
1. 自动检测设备 CPU 架构，确保为 `aarch64` (ARM64) 架构。
2. 检查并自动拉取 Termux 包管理器中的 `glibc-runner` 依赖。
3. 从官方发布服务安全下载标准 `linux_arm64` 平台压缩包。
4. 使用哈希签名比对进行 SHA512 完整性强校验，确保文件未被篡改。
5. 解压主程序至隔离库目录，并在系统执行路径 `$PREFIX/bin/agy` 下生成微型链接包装器（Wrapper）。

---

## 🚀 安装与部署

在您的 **Termux** 终端中拷贝并运行以下一键安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/furina707/agy-termux/main/install-termux.sh | bash
```

或者，您也可以先克隆本仓库到本地，然后运行安装脚本：

```bash
git clone https://github.com/furina707/agy-termux.git
cd agy-termux
bash install-termux.sh
```

---

## 🔍 验证与使用

安装完成后，直接调用系统注册的包装器命令以验证版本：

```bash
agy --version
```

在 Termux 终端中启动您的智能编程助理：
```bash
agy
```

---

## 🛠️ 运行架构设计

```
用户输入命令 [agy]
       │
       ▼
执行路径启动器包装脚本 [$PREFIX/bin/agy]
       │
       ▼
重定向至 glibc-runner 解释器 [grun]
       │
       ▼
加载精简版 glibc 动态运行库环境
       │
       ▼
执行官方标准的 linux_arm64 原生机器码 ELF 二进制文件
```

---

## 📝 许可证

本项目基于 MIT 许可证开源。
