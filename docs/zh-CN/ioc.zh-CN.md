# IOC 应用

[English](../ioc.md) | 简体中文

本文属于[文档索引](README.zh-CN.md)。

IOC 应用是一棵 `makeBaseApp` 风格的目录树：一个应用目录，含 `configure/`、生成
IOC 可执行文件和 `.dbd` 的 `*App/src`、放记录的 `*App/Db`，以及带 `st.cmd` 的
`iocBoot/<ioc>`。

三个部分配合工作：

* `epics-ioc`（继承 `epics-module`）构建并打包应用。
* `epics-ioc-systemd`（继承 `epics-ioc`）注册实例：把每个实例的 env 文件装进
  全机实例注册表（`/etc/epics/instances/<name>.env`），并可在镜像构建时启用实例。
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
| `EPICS_IOC_INSTANCES`       | `""`                                 | 镜像构建时由 `EPICS_IOC_AUTO_ENABLE` 启用的实例。 |
| `EPICS_IOC_AUTO_ENABLE`     | `"disable"`                          | `enable` 时为 `EPICS_IOC_INSTANCES` 装上 systemd enable 符号链接。 |

IOC 链接到的每个模块都必须写进 `RDEPENDS`：shlibs 扫描看不到
`${EPICS_PREFIX}` 下的内容，推不出来。

`configure/RELEASE` 里写 `/opt/epics` 路径，不要写构建 sysroot —— sysroot 只
在构建期有效。

## 实例

一个实例就是一个全机唯一的名字（`scope01`、`blm`……）加一条注册表条目——一个
纯 `KEY=value` 的 env 文件。注册表分两层，后者覆盖前者：

* `/etc/epics/instances/<name>.env` —— 队级层，由 IOC 包随镜像安装；
* `/boot/iocs/<name>/<name>.env` —— 机器级层，位于可写的 BOOT 分区，用于每台
  机器的差异化覆盖。镜像自动启动的每个实例，`epics-ioc-systemd` 都会把队级条目
  投影成这个文件的初始版本 deploy 出来，`inflate-sd.sh` 再把整个目录拷到卡上：
  所以在部署好的机器上，这个文件一直都在，无论有没有人改过它。

部署人员会在 Windows 上编辑机器级层，因此引导链从 `/boot` 读取的每个文件都
容忍 CRLF 行尾：`ioc-start.sh`、`bootcfg`、`fpgacfg` 都会检测到 CR、给出警告，
并解析去掉 CR 后的副本。

注册表条目指出应用位置并携带实例身份：

```sh
IOC_APP_DIR=/opt/epics/iocs/asyn-scope-ioc   # 应用所在目录
IOC_PATH=iocBoot/ioctestAsynPortDriver       # 相对 IOC_APP_DIR
IOC_APP_NAME=testAsynPortDriver              # 留空：通过 shebang 运行 st.cmd
IOC_INSTANCE_INDEX=1                         # 控制台 21010；对 target 上所有 IOC 全局唯一
P=ioc1:                                      # 记录前缀（分隔符包含在值里）
R=scope1:                                    # 可选设备根：记录名形如 $(P)$(R)...
IOC_STATE=/var/lib/asyn-scope-ioc/scope01    # 可写的实例状态目录（autosave save 文件）
IOC_STATE_DIRS="autosave"                    # IOC_STATE 下需要一并创建的子目录

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
| `P`（PV 前缀） | `XRAY:BLM00` | 每台机器，位于 BOOT 分区 | 客户端看到的名字 |

实例名被限定为小写 `[a-z0-9-]`（systemd 的 `%i` 和调度器校验都拒绝冒号和
大写），而且每台机器跑的是同一个镜像，所以它必须处处相同：二十台机器上都是
`blm`。每台机器唯一不同的是 PV 前缀；镜像里最多带一个台架默认值，绝不带某台
机器自己的前缀：

* 一般 IOC 从注册表键 `P`（和 `R`）取值——可选的
  `/boot/iocs/<name>/<name>.env` 机器层可以覆盖。IOC 内部的 envPaths
  `epicsEnvSet` 优先级更高：它在 st.cmd 里更晚执行。
* BLM IOC 正是围绕这个优先级组织的：它的 recipe 从安装后的 `envPaths` 里删掉
  `epicsEnvSet("P", ...)` 这一行，把应用硬编码的两个可写路径改写成
  `$(IOC_STATE)/autosave` 和 `$(IOC_STATE)/calibrations`，并去掉那行 source
  `/boot/iocs/.../envPaths` 的命令；于是前缀和状态目录位置都成了普通的注册表键，
  每台机器只需一个文件：

  ```sh
  # /boot/iocs/blm/blm.env —— 部署完成后，卡上剩下的就是这一行
  P=XRAY:BLM00
  ```

  目录按实例名而不是按 iocBoot 目录命名：运维要碰的是 `iocs/blm/`。autosave 库
  只保存它拿到的路径，BLM 驱动也只会在目标路径旁打开文件，两者都建不出不存在的
  目录——这就是 `IOC_STATE` 加 `IOC_STATE_DIRS` 的用处：调度器在 exec procServ
  之前，就按条目指定的介质把整棵目录树建好。本机取
  `IOC_STATE=/boot/iocs/blm`，调好的阈值和标定文件因此能穿过一次 rootfs 重刷，
  并随机器一起走；条目里不设这个键的机器会拿到 `/var/lib/epics-ioc/blm`，其它
  一切不变。

  把这个目录挪走，是被有意排除在卡片的决定之外的。某台机器上改了它，IOC 打开的就是
  另一套——大概率是空的——save 文件，第 0 轮什么都恢复不回来，反而把记录默认值
  当成这台机器自己的设置写回去；在联锁真的动作之前，没人会看出任何症状。文件本身
  拦不住这件事：deploy 出来的 `blm.env` 是上面这份条目的投影，每个键都照抄，
  `IOC_STATE` 也在里面。防线是部署规程的那两步——改 `P`、把本机不决定的行删掉——
  而"删行"顺手就把隐患一起删掉了：卡上不存在的键，没人在卡上改它。

  这个文件在卡上的起点，是条目的投影：只包含赋值行，保持原顺序、丢掉注释：

  ```text
  IOC_INSTANCE_INDEX=0
  IOC_APP_DIR=/opt/epics/iocs/impcas-ioc-blm-zux
  IOC_PATH=iocBoot/iocblm
  IOC_APP_NAME=blm
  P=XRAY:BLM00
  R=
  IOC_HOST=
  IOC_STATE=/boot/iocs/blm
  IOC_STATE_DIRS="autosave calibrations"
  ```

  每一行的起点都是本镜像发出的值，所以一份没人动过的投影，行为等同于这个文件
  不存在。部署就是对这一个文件做两件事：把 `P` 改成本机的前缀，再删掉本机不决定
  的行。删行是安全的方向——条目里没有的键跟随镜像——而且它让本机自己的决定看得
  出来：`ioc-manager show blm` 只在卡上给出非空值时才把某个键标成机器层，所以裁到
  只剩 `P=` 的卡会报一行 `machine`、其余 `fleet`，文件本身就回答了"这台机器哪里
  不一样"。删多了就把 `iocs/blm/` 整个文件夹删掉再跑一次 `inflate-sd.sh`，取回
  完整投影。

  镜像不设的键（`R`、`IOC_HOST`）在条目里写成空值，投影到卡上就是空行：
  `ioc-start.sh` 只在非空时才 export（`[ -n "$R" ] && export R`），所以空值等价于
  "不设"，这一行只是留给本机的占位，不用就删。

  这也是为什么卡上的模板是一个目录、而不是一个要人敲出来的文件名：从 Windows 新建
  `blm.env` 意味着在一个默认隐藏 `.txt` 后缀的对话框里精确输入名字，而
  `blm.env.txt` 悄悄就不是一条注册表条目——IOC 照样启动、照样广播队级前缀，直到
  记录名对上才看得出不对。

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
ioc-manager startall | stopall | restartall
ioc-manager status scope01        # 单个实例的完整 systemctl status
ioc-manager console scope01       # 接入该实例的 procServ 控制台
ioc-manager logs blm -f           # 单个实例的 journal（不带名字则合并全部）；
                                  # -n N 行数，-- 之后的参数透传给 journalctl
ioc-manager show blm              # 合并后的注册表条目，逐键标注来源层
ioc-manager doctor                # 注册表 / systemd / 运行时三方对账
ioc-manager wait blm 120          # 阻塞到 active 且控制台已绑定
```

`doctor` 只报告不修改：应用目录缺失、`IOC_HOST` 与本机不符、条目没有 `P`
（记录名丢掉前缀，或者混进字面量 `${P}`）、运行中的实例 `IOC_STATE` 不存在或
只读（autosave 会无声丢弃每一次保存）、槽位冲突、"已 enable 但未运行"和
"在运行但无注册条目"的实例、`$RUN_DIR` 里残留的控制台 infofile。`wait` 面向
开机脚本和验收：unit active 且 procServ 已写出实例 infofile（控制台绑定成功即
IOC 进程存活）才返回 0，failed 或超时返回 1。

## 启动调度器

systemd 做不了端口算术和注册表查找，所以 `ExecStart` 指向一个脚本而不是
procServ 本身。`ioc-start.sh <实例名>` 依次：

1. source 站点级值（`epics-ioc-env`：注册表根、`PORT_BASE`、`RUN_DIR`、
   `PROCSERV_ARGS`）；
2. 加载 `/etc/epics/instances/<实例名>.env`，随后加载可选的
   `/boot/iocs/<实例名>/<实例名>.env` 机器级覆盖；
3. 检查 `$IOC_APP_DIR/$IOC_PATH` 存在；
4. 推导控制口和应用口（`ioc-ports.sh`）；
5. env 固定了 `CA_PORT`/`PVA_PORT` 时，导出
   `EPICS_CA_SERVER_PORT`/`EPICS_PVAS_SERVER_PORT`（服务端启动时读取）；
6. 注册表设置了 `P` / `R` 时将其 export，为 `IOC_STATE` 取默认值，并连同
   `IOC_STATE_DIRS` 列出的每个子目录一起创建（autosave 和应用自己都建不出还
   不存在的路径，数据放在子目录里的实例必须把这些子目录声明出来）；
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

ioc-manager console scope01                   # 本机接入控制台（不用记端口）
telnet <板卡IP> 21010                         # 从其他主机接同一个控制台
telnet <板卡IP> 21020                         # 从其他主机接 scope02
```

`ioc-manager console <实例名>` 从实例 infofile 解析 endpoint（因此固定
`PS_PORT` 和通配 bind 都能正确处理），再调用镜像里可用的客户端
（telnet / socat / nc）。procServ 把控制台的**控制权**给第一个接入的客户端，
后续接入的只能只读查看。

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
