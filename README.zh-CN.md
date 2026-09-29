# meta-epics

[English](README.md) | 简体中文

用于交叉编译 EPICS 并在 target 上运行 IOC 应用的 PetaLinux layer。

提供 EPICS Base、BLM IOC 所需的支持模块、用于托管 IOC 的进程服务器，以及
构建和打包 IOC 应用（含逐实例端口分配）所需的 bbclass。

本文是快速上手指南，主题文档在 [`docs/`](docs/zh-CN/README.zh-CN.md) 目录下。

## Recipe 列表

| Recipe                        | 版本             | 安装位置                            |
|-------------------------------|------------------|-------------------------------------|
| `epics-base`                  | 7.0.10           | `/opt/epics/base[-7.0.10]`          |
| `epics-asyn`                  | 4.46             | `/opt/epics/modules/asyn[-4.46]`    |
| `epics-autosave`              | 6.0              | `/opt/epics/modules/autosave[-6.0]` |
| `epics-test-asyn-port-driver` | 1.0              | `/opt/epics/iocs/tapd[-1.0]`        |
| `procserv`                    | master（`+git`） | `/usr/bin/procServ`                 |

`epics-test-asyn-port-driver` 既是示例，也是 BLM IOC 的模板：它构建的就是
asyn 自带的模拟示波器测试 IOC。IOC 文档都以它为例。
`procserv` 跟随上游 master，因此每次构建都会重新拉取和编译，需要联网。

## bbclass

| bbclass                  | 用途                                                       |
|--------------------------|------------------------------------------------------------|
| `epics-module`           | 用 EPICS 自身的构建系统交叉编译支持模块。                   |
| `epics-ioc`              | 构建并打包 IOC 应用（`makeBaseApp` 目录树）。                |
| `epics-ioc-systemd`      | 用 procServ 托管 IOC，支持单实例与多实例。                   |

## 文档

| 文档 | 主题 |
|------|------|
| [快速上手](#接入-petalinux) | 即本文：接入、配置、构建。 |
| [EPICS Base](docs/zh-CN/epics-base.zh-CN.md) | Base 安装了什么、交叉构建如何接线。 |
| [支持模块](docs/zh-CN/modules.zh-CN.md) | 模块 recipe，如何新增一个。 |
| [IOC 应用](docs/zh-CN/ioc.zh-CN.md) | IOC 的构建、打包与操作。 |
| [IOC 端口分配](docs/zh-CN/port-allocation.zh-CN.md) | 哪个实例用哪个端口。 |
| [排障](docs/zh-CN/troubleshooting.zh-CN.md) | QA 告警、构建失败、target 侧诊断。 |

## 接入 PetaLinux

以下步骤把本 layer 加入现有的 PetaLinux 工程。

### 1. 放置 layer

把 layer 放到 PetaLinux 工程的 `project-spec/` 目录下：

```text
my-petalinux/
└── project-spec/
    ├── meta-epics/
    └── meta-user/
```

开发期间也可以用软链接：

```bash
cd my-petalinux/project-spec
ln -s /path/to/meta-epics meta-epics
```

### 2. 注册 layer

在 PetaLinux 工程根目录执行：

```bash
petalinux-config
```

打开：

```text
Yocto Settings -> User Layers
```

填入：

```text
${PROOT}/project-spec/meta-epics
```

保存退出后，PetaLinux 会把 layer 写进 `build/conf/bblayers.conf`。

确认生成的 layer 列表：

```bash
grep meta-epics build/conf/bblayers.conf
```

不要提交 `build/conf/bblayers.conf`，它由 PetaLinux 生成。

### 3. 确认 layer 可见

PetaLinux 工程需要先加载自带的 Yocto 环境。在工程根目录按工程实际路径执行：

```bash
source components/yocto/layers/poky/oe-init-build-env build
```

有些 PetaLinux 版本是 `layers/core` 而不是 `layers/poky`：

```bash
source components/yocto/layers/core/oe-init-build-env build
```

加载之后才能使用 `bitbake`、`bitbake-layers` 等命令做检查；在此之前不要执行它们。

在已加载 Yocto 环境的 shell 里运行：

```bash
bitbake-layers show-layers
bitbake-layers show-recipes epics-base
```

输出必须包含 `meta-epics` 和 recipe 版本 `7.0.10`。

## 工程配置

在 `project-spec/meta-user/conf/user.conf` 里配置安装前缀：

```bitbake
EPICS_PREFIX = "/opt/epics"
```

recipe 根据 `TARGET_ARCH` 选择 EPICS 的目标体系结构：

```text
aarch64   -> linux-aarch64
其他 ARM   -> linux-arm
```

必要时可以显式覆盖：

```bitbake
EPICS_TARGET_ARCH = "linux-arm"
```

Zynq-7000 用 `linux-arm`，ZynqMP 用 `linux-aarch64`。也支持按机器覆盖：

```bitbake
EPICS_TARGET_ARCH:my-zynq-machine = "linux-arm"
EPICS_TARGET_ARCH:my-zynqmp-machine = "linux-aarch64"
```

### 确认展开后的配置

```bash
bitbake -e epics-base | grep -E '^(EPICS_PREFIX|EPICS_TARGET_ARCH|EPICS_HOST_ARCH|SRCREV|DEPENDS|RDEPENDS)='
```

recipe 把 `EPICS_HOST_ARCH` 固定为 `linux-x86_64`。交叉编译器、`${TARGET_PREFIX}`
和目标 sysroot 由 PetaLinux/BitBake 自动提供，无需硬编码 SDK 编译器路径。

## 加入根文件系统

以下两种方式二选一。

### 用户 rootfs 配置

在 `project-spec/meta-user/conf/user-rootfsconfig` 里加入：

```text
CONFIG_epics-base
CONFIG_epics-asyn
CONFIG_epics-autosave
CONFIG_procserv
CONFIG_epics-test-asyn-port-driver
```

然后打开 rootfs 配置菜单确认这些包已勾选：

```bash
petalinux-config -c rootfs
```

### 镜像安装列表

或者把它加到 `project-spec/meta-user/conf/user.conf`：

```bitbake
IMAGE_INSTALL:append = " epics-base epics-asyn epics-autosave procserv epics-test-asyn-port-driver"
```

不要同时使用两种方式。

`epics-test-asyn-port-driver` 依赖 `epics-asyn` 和 `procserv`，只勾选它就会
带出这两者；`epics-autosave` 只会被用到它的 recipe 带入。

## 构建

先单独构建 recipe（调试时比整镜像快）：

```bash
petalinux-build -c epics-base
petalinux-build -c epics-test-asyn-port-driver
```

再构建完整镜像：

```bash
petalinux-build
```

首次构建会从 GitHub 拉取 EPICS Base 和各模块；除非源码已经在 `DL_DIR` 里，
否则需要网络或已配置的源码镜像。`procserv` 跟随 master，因此每次都会重新
拉取和编译。

## 确认 target 安装结果

target 启动后检查：

```text
/opt/epics/base -> base-7.0.10
/opt/epics/base-7.0.10/bin/<目标体系结构>/
/opt/epics/base-7.0.10/lib/<目标体系结构>/
/opt/epics/modules/asyn -> asyn-4.46
/opt/epics/modules/autosave -> autosave-6.0
/opt/epics/iocs/tapd -> tapd-1.0
/etc/profile.d/epics.sh
/usr/bin/procServ
```

target 上不应出现 `bin/linux-x86_64/` 这类 host 体系结构目录。完整布局，包括
target 上的开发环境提供了什么，见 [EPICS Base](docs/zh-CN/epics-base.zh-CN.md)。

IOC 应用的部分见 [IOC 应用](docs/zh-CN/ioc.zh-CN.md)，简要流程：

```bash
systemctl enable --now 'epics-ioc@tapd01'
caget TAPD01:scope1:Waveform_RBV
```

## 排障

QA 告警、构建失败和 target 侧诊断集中在[排障](docs/zh-CN/troubleshooting.zh-CN.md)
里。最常见的两类：

* `buildpaths` QA 告警说明某个进了包的文件残留了构建路径。class 会清洗自己
  生成的路径，所以出现新告警通常意味着有文件没经过清洗就进了包。
* IOC 启动时找不到 `lib<模块>.so`，要么缺运行期依赖，要么缺 rpath 条目。

## License 校验和

每个 recipe 使用其固定 commit 中 `LICENSE` 文件的校验和，Yocto 在 license
收集任务里校验。
