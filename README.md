# Antigravity CLI - Termux 适配器

在 Android Termux 中，通过自定义的 `glibc-runner`（`grun`）桥接环境，原生且无缝地运行专为标准 Linux ARM64 (glibc) 编译的 **Antigravity CLI**。

---

## 💡 问题背景

Antigravity CLI 官方发布的 Linux ARM64 二进制文件是针对标准 Linux 平台编译的，静态或动态链接了 **`glibc`**（GNU C 运行库）。
然而，Android 系统（及 Termux 容器）底层采用的是 Google 专有的 **`Bionic libc`**，且不遵循传统的 Linux 文件系统层级标准（FHS）。
因此，直接在 Termux 原生环境下运行该二进制文件会导致动态链接器缺失，抛出类似 `No such file or directory` 或 `exec format error` 的错误。

---

## ⚡ 解决方案 (方案 B)

本项目通过自动配置 **`glibc-runner` (`grun`)** 建立一个轻量级的动态兼容桥梁，从而彻底解决兼容性问题。

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
