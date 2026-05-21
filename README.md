# Antigravity CLI - Termux Adapter

Run the standard dynamic glibc-compiled **Antigravity CLI** natively inside **Android Termux** using a custom glibc-runner bridge.

---

## 💡 The Problem

Antigravity CLI is distributed as a pre-compiled native binary for Linux ARM64, target-linked against standard **`glibc`**.
Android and Termux run on **`Bionic libc`** and do not follow the standard Filesystem Hierarchy Standard (FHS). Thus, attempting to run the standard installer throws missing linkers and library errors (`No such file or directory` / `exec format error`).

---

## ⚡ The Solution (Method B)

This project automates standard compatibility configuration by using **`glibc-runner` (`grun`)** to bridge Android Bionic libc and standard glibc.

Our custom installer:
1. Automatically detects CPU architecture (`aarch64` ARM64).
2. Sets up `glibc-runner` (via `pkg install grun` dynamically).
3. Downloads the official `linux_arm64` release directly.
4. Performs verification check matching the manifest `sha512` signature.
5. Deploys the native binary and registers a launcher wrapper bridge at `$PREFIX/bin/agy`.

---

## 🚀 Installation

Open your **Termux** terminal and run the following command:

```bash
curl -fsSL https://raw.githubusercontent.com/<YOUR_USERNAME>/<YOUR_REPO_NAME>/main/install-termux.sh | bash
```

Alternatively, you can clone this repository and run the script locally:

```bash
git clone https://github.com/<YOUR_USERNAME>/<YOUR_REPO_NAME>.git
cd <YOUR_REPO_NAME>
bash install-termux.sh
```

---

## 🔍 Verification

Once installed, verify the installation by calling the wrapper:

```bash
agy --version
```

Start using the assistant inside Termux:
```bash
agy
```

---

## 🛠️ Architecture

```
User CLI input [agy]
       │
       ▼
Launcher Wrapper Script [$PREFIX/bin/agy]
       │
       ▼
Interception via grun [glibc-runner]
       │
       ▼
Standard glibc Dynamic Runtime Environment Staging
       │
       ▼
Official linux_arm64 Native ELF Binary Execution
```

---

## 📝 License

This project is licensed under the MIT License.
