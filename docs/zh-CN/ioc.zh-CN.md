# IOC 应用

[English](../ioc.md) | 简体中文

本文属于[文档索引](README.zh-CN.md)。

IOC 应用是一棵 `makeBaseApp` 风格的目录树：一个应用目录，含 `configure/`、生成
IOC 可执行文件和 `.dbd` 的 `*App/src`、放记录的 `*App/Db`，以及带 `st.cmd` 的
`iocBoot/<ioc>`。

三个部分配合工作：

* `epics-ioc`（继承 `epics-module`）构建并打包应用。
* `epics-ioc-systemd`（继承 `epics-ioc`）注册实例：把每个实例的 env 文件装进
  全机实例注册表（`/etc/epics/instances/<name>.env`），并可通过 systemd preset
  启用实例。
* `epics-ioc-scripts` 是所有 IOC 共用的运行时：一个通用 systemd 模板
  （`epics-ioc@.service`）、`ioc-start.sh` 调度器和端口槽位辅助脚本。实例只由
  它的全机唯一名字标识。

`recipes-examples/epics-asyn-scope-ioc/` 里的 `epics-asyn-scope-ioc` 是完整示例：它直接
从 asyn 源码构建 asyn 自带的模拟示波器测试 IOC（`testAsynPortDriver`）。阅读本文
时请对照它的 recipe。

## 安装布局

```text
/usr/lib/systemd/system/epics-ioc@.service     # 全部 IOC 共用一个通用模板
/usr/libexec/epics-ioc/{ioc-start.sh,ioc-ports.sh,epics-ioc-env}
/usr/bin/{ioc-ports,ioc-manager,ioc-instance-add}
/etc/epics/instances/{scope01.env,scope02.env} # 实例注册表（队级层）
/opt/epics/iocs/asyn-scope-ioc -> asyn-scope-ioc-1.0
/opt/epics/iocs/asyn-scope-ioc-1.0/
├── bin/linux-aarch64/testAsynPortDriver
├── lib/linux-aarch64/libtestAsynPortDriverSupport.so
├── db/testAsynPortDriver.db
├── dbd/testAsynPortDriver.dbd
└── iocBoot/ioctestAsynPortDriver/{st.cmd,envPaths}
```

应用安装在 `${EPICS_PREFIX}/iocs`（`EPICS_INSTALL_BASE`），与支持模块安装在
`${EPICS_PREFIX}/modules` 的方式一致。

## 编写 IOC recipe

```bitbake
inherit epics-ioc-systemd

EPICS_MODULE_NAME = "my-ioc"
DEPENDS += "epics-asyn epics-autosave"
RDEPENDS:${PN} += "epics-asyn epics-autosave"

EPICS_RELEASE_EXTRA = "\
    ASYN = ${RECIPE_SYSROOT}${EPICS_PREFIX}/modules/asyn\n\
    AUTOSAVE = ${RECIPE_SYSROOT}${EPICS_PREFIX}/modules/autosave"
EPICS_IOC_LIBDIRS = "${EPICS_PREFIX}/modules/asyn/lib/${EPICS_TARGET_ARCH} \
                     ${EPICS_PREFIX}/modules/autosave/lib/${EPICS_TARGET_ARCH}"

IOC_APP_NAME = "myIoc"
IOC_PATH     = "iocBoot/iocmy"
```

class 会读取的变量：

| 变量                        | 默认值                               | 含义 |
|-----------------------------|--------------------------------------|------|
| `EPICS_MODULE_NAME`         | `${BPN}`                             | `iocs/` 下的目录名。 |
| `EPICS_INSTALL_BASE`        | `${EPICS_PREFIX}/iocs`               | 安装根目录。 |
| `EPICS_RELEASE_EXTRA`       | `""`                                 | `configure/RELEASE` 条目；多个用 `\n` 分隔。 |
| `EPICS_IOC_LIBDIRS`         | `""`                                 | 所链模块的运行期库目录；转成 rpath 条目。 |
| `IOC_APP_NAME`              | `""`                                 | `bin/<目标体系结构>/` 下的可执行文件；留空则通过 st.cmd 的 shebang 运行。 |
| `IOC_PATH`                  | `""`                                 | `st.cmd` 所在目录，如 `iocBoot/iocmy`。 |
| `IOC_ST_CMD`                | `"st.cmd"`                           | 启动脚本名。 |
| `EPICS_IOC_INSTANCE_ENVS`   | `""`                                 | 要安装的注册表条目（源码路径，basename = 实例名）。 |
| `EPICS_IOC_INSTANCES`       | `""`                                 | 镜像构建时由 systemd-preset-all 启用的实例。 |
| `EPICS_IOC_AUTO_ENABLE`     | `"disable"`                          | `enable` 时为 `EPICS_IOC_INSTANCES` 写 preset 行。 |

IOC 链接到的每个模块都必须写进 `RDEPENDS`：shlibs 扫描看不到
`${EPICS_PREFIX}` 下的内容，推不出来。

`configure/RELEASE` 里写 `/opt/epics` 路径，不要写构建 sysroot —— sysroot 只
在构建期有效。

## 实例

一个实例就是一个全机唯一的名字（`scope01`、`blm`……）加一条注册表条目——一个
纯 `KEY=value` 的 env 文件。注册表分两层，后者覆盖前者：

* `/etc/epics/instances/<name>.env` —— 队级层，由 IOC 包随镜像安装；
* `/boot/iocs/<name>.env` —— 机器级层，位于可写的 BOOT 分区，用于每台机器的
  差异化覆盖；多数机器上不存在。

注册表条目指出应用位置并携带实例身份：

```sh
IOC_APP_DIR=/opt/epics/iocs/asyn-scope-ioc   # 应用所在目录
IOC_PATH=iocBoot/ioctestAsynPortDriver       # 相对 IOC_APP_DIR
IOC_APP_NAME=testAsynPortDriver              # 留空：通过 shebang 运行 st.cmd
IOC_INSTANCE_INDEX=1                         # 控制台 21010；对 target 上所有 IOC 全局唯一
P=ioc1:                                      # 记录前缀（分隔符包含在值里）
R=scope1:                                    # 可选设备根：记录名形如 $(P)$(R)...
IOC_STATE=/var/lib/asyn-scope-ioc/scope01    # 可写的实例状态目录（autosave save 文件）

#CA_PORT=21013                              # 可选：固定 CA 服务端口（否则动态）
#PVA_PORT=21014                             # 可选：固定 PVA 服务端口（否则动态）
#PS_PORT=...                                # 可选：覆盖控制台端口
#APP_PORT_1=...                             # 可选：IOC 自己开 socket 时使用
#APP_PORT_2=...
#IOC_HOST=blm01                             # 可选：拒绝在其他机器上启动
```

用 `IOC_HOST` 固定的实例在其他机器上会拒绝启动——防止把某台机器的注册表条目
拷到错误的 SD 卡上。

### 实例名与 PV 宏名是两回事

实例名和 PV 前缀是两个互不相干的身份：

| 身份 | 示例 | 由谁定义 | 作用范围 |
|---|---|---|---|
| 实例名 | `blm` | 注册表文件名 | 仅运维标识；全队统一 |
| `IOC_HOST` | `blm01` | 注册表条目的可选键 | 防拷贝错误的守卫 |
| `P`（PV 前缀） | `XRAY:BLM:BD40` | 每台机器，位于 BOOT 分区 | 客户端看到的名字 |

实例名被限定为小写 `[a-z0-9-]`（systemd 的 `%i` 和调度器校验都拒绝冒号和
大写），而且每台机器跑的是同一个镜像，所以它必须处处相同：二十台机器上都是
`blm`。每台机器唯一不同的恰恰是 PV 前缀，而它完全不进镜像：

* 像 BLM 这种 `st.cmd` source `/boot` envPaths 的 IOC，`P` 来自
  `/boot/iocs/iocblm/envPaths` 里的 `epicsEnvSet("P","XRAY:BLM:BD40")`；
* 一般 IOC 从注册表键 `P`（和 `R`）取值——可选的
  `/boot/iocs/<name>/<name>.env` 机器层可以覆盖。IOC 内部的 envPaths
  `epicsEnvSet` 优先级更高：它在 st.cmd 里更晚执行。

冒号风格跟随数据库：`.db` 模板里的记录名自带分隔符（`$(P):CH0:...`），所以
`P` 的值不带尾冒号。

实例名是小写 `[a-z0-9-]` 且全机唯一。`IOC_INSTANCE_INDEX` 是唯一必须唯一的
编号，而且是对 target 上所有 IOC 全局唯一。`ioc-instance-add <name>` 用最小
空闲槽位生成注册表条目，`ioc-ports --show [实例名]` 打印端口（运行中的
实例还会列出实际 endpoint）：

```sh
ioc-instance-add myscope
ioc-ports --show scope01
ioc-ports --next
ioc-ports --audit
```

`ioc-manager` 是面向注册表和 systemd 的日常入口：

```sh
ioc-manager list                  # 两层注册表里的实例 + 状态
ioc-manager report                # 名字 / 槽位 / 端口 / 前缀 / 应用
ioc-manager status                # 每个实例一行
ioc-manager start blm             # 启动单个实例
ioc-manager stop blm              # 停止单个实例
ioc-manager restart blm           # 重启单个实例
ioc-manager enable blm            # 开机自启
ioc-manager disable blm           # 取消开机自启
ioc-manager startall | stopall
ioc-manager status scope01        # 单个实例的完整 systemctl status
```

## 启动调度器

systemd 做不了端口算术和注册表查找，所以 `ExecStart` 指向一个脚本而不是
procServ 本身。`ioc-start.sh <实例名>` 依次：

1. source 站点级值（`epics-ioc-env`：注册表根、`PORT_BASE`、`RUN_DIR`、
   `PROCSERV_ARGS`）；
2. 加载 `/etc/epics/instances/<实例名>.env`，随后加载可选的
   `/boot/iocs/<实例名>.env` 机器级覆盖；
3. 检查 `$IOC_APP_DIR/$IOC_PATH` 存在；
4. 推导控制口和应用口（`ioc-ports.sh`）；
5. env 固定了 `CA_PORT`/`PVA_PORT` 时，导出
   `EPICS_CA_SERVER_PORT`/`EPICS_PVAS_SERVER_PORT`（服务端启动时读取）；
6. 注册表设置了 `P` / `R` 时将其 export，为 `IOC_STATE` 取默认值并创建状态目录；
7. `cd` 进 `$IOC_APP_DIR/$IOC_PATH`，source 可选的 `ioc-start.pre` 钩子并
   执行 `$IOC_START_PRE`；
8. `exec procServ -f -L - --name=<实例名> -I <info文件> -P "$PS_PORT" ...`。

`P`、`R` 和 `IOC_STATE` 会被 export，而 iocsh 从进程环境读取 `.cmd` 宏，因此
`st.cmd` 里可以直接用 `$(P)`、`$(R)`、`$(IOC_STATE)` 或任何实例设置。`/run/epics/`
下的 `-I` info 文件记录运行中服务器的 PID 和 endpoint；`ioc-ports --show <实例名>`
会读取它。

钩子文件 `<IOC_APP_DIR>/<IOC_PATH>/ioc-start.pre` 会被 source，所以可以在其中定义
`IOC_START_PRE` 引用的函数——例如在 `$APP_PORT_1` 上起一个外部设备模拟器。
它是服务 cgroup 里的兄弟进程，systemd 停服务时会连同它一起停掉。

## target 上的操作

```bash
systemctl is-enabled 'epics-ioc@scope01'      # disabled：已安装，未启用
systemctl enable --now 'epics-ioc@scope01'
systemctl enable --now 'epics-ioc@scope02'
netstat -ltnp | grep -E ':210[0-2][0-9]'       # 控制台 21000（blm）/ 21010 / 21020
cat /run/epics/scope02.info                   # 运行中 IOC 的 PID 与 endpoint

telnet <板卡IP> 21010                         # scope01 的控制台
telnet <板卡IP> 21020                         # scope02 的控制台
```

控制台就是运行中 IOC 的 iocsh 提示符（`help`、`dbpr`……）。procServ 以
one-shot 方式运行：IOC 退出——无论崩溃还是控制台里 `^X`——procServ 都会带着
子进程的退出码退出，单元保持 **failed** 状态，journal 里就是完整的故障现场。
这里**有意不做自动重启**：IOC 挂了是要排查的故障，不是重启能掩盖的。确实需要
自动拉起的实例用实例级 drop-in 自行开启
（`/etc/systemd/system/epics-ioc@<name>.service.d/restart.conf`，
`[Service]` + `Restart=always` + `RestartSec=5s`）。

记录通过 CA 访问，客户端无需任何配置，因为主机上每个实例都会收到广播搜索并以
自己的端口应答：

```bash
caget ioc0:scope1:UpdateTime                # 可写的 ao 记录
caget ioc0:scope1:Waveform_RBV              # 模拟波形
caget ioc1:scope1:Waveform_RBV             # 另一个实例，同样零配置
```

这个 IOC 的波形记录是只读的（`Waveform_RBV`、`TimeBase_RBV`）；可写的记录是
`Run`、`VoltOffset`、`TriggerDelay`、`NoiseAmplitude`、`UpdateTime` 和三个
`*Select` 枚举。示波器的 Phoebus 显示界面随 IOC 装在目标板的
`/opt/epics/iocs/asyn-scope-ioc-1.0/opi/asyn-scope-ioc0.bob`——把它拷到客户端用
Phoebus 打开即可。文件里的默认宏是 `P=ioc0:`、`R=scope1:`，开箱即指向 ioc0
实例；其他实例只需在客户端加 `-m "P=ioc1:"`。

模拟示波器不自己开 socket，所以它的实例不占用应用口。需要应用口的 IOC——比如
做 Modbus 或 stream-device 服务端的——在 env 文件里固定，并写入
[port-allocation.md](port-allocation.zh-CN.md) 的端口表。

## 为什么 class 要这么做

IOC 构建异常时可以对照排查：

* **`envPaths` 只在 host 侧生成。** `iocBoot/<ioc>/Makefile` 把
  `ARCH = $(EPICS_HOST_ARCH)` 写死，只有 host 的 `buildInstall` 目标会运行
  `convertRelease.pl`，所以 class 在 target 编译之后单独执行这一步。
* **不构建 host 体系结构。** EPICS 让交叉目标依赖 host 目标
  （`configure/RULES_ARCHS`），那会用未打包的 host 模块库去链一个 host 版
  IOC。`EPICS_MAKE_EXTRA` 清掉 `CROSS_ARCHS`，只构建 target。
* **`IOCS_APPL_TOP`。** EPICS 把应用顶层目录记进 `envPaths` 和生成的
  `*_registerRecordDeviceDriver.cpp`，后者在 `iocInit` 时与运行期 `TOP` 比较。
  不设置的话它就是构建目录：既把构建路径嵌进二进制，又让每次启动都告警，所以
  class 把它指向安装位置。
* **用 rpath 而不是 `LD_LIBRARY_PATH`。** target 上为 Base 和
  `EPICS_IOC_LIBDIRS` 写入显式 rpath，IOC 不需要任何环境设置就能启动。
  `envPaths` 里则记录着来自 `configure/RELEASE` 的 sysroot 路径，class 会把它
  清掉，并把带版本的安装目录改写成与版本无关的软链接。
