# 排障

[English](../troubleshooting.md) | 简体中文

本文属于[文档索引](README.zh-CN.md)。

按症状组织，每条给出原因和修法。构建侧的条目会注明行为出处（上游源码的文件
和位置）。

## QA 告警

### `File ... contains reference to TMPDIR [buildpaths]`

* **是什么。** 该检查逐个扫描包内文件，查找构建目录字符串
  （`poky/meta/classes-global/insane.bbclass` 的 `QAPATHTEST[buildpaths]`）。
  默认只是 warning；只有项目把 `buildpaths` 提升到 `ERROR_QA` 才会让构建失败。
* **影响。** 可复现性以及构建目录结构的泄露，不影响功能。
* **本 layer 已做的处理。** 清洗 `envPaths` 和 `*.local` 文件；`IOCS_APPL_TOP`
  让 Base 自带的 IOC 和所有 IOC 应用指向安装位置；Base 的调试源码包对其生成的
  出处注释豁免了该检查。
* **新文件触发时。** 先找到字符串：`strings -a <文件> | grep <tmpdir>`。然后
  要么从源头修 —— 类似 `IOCS_APPL_TOP`、`FINAL_LOCATION` 这样的开关几乎总是正解
  —— 要么用 `INSANE_SKIP:<包名> += "buildpaths"` 只对该包豁免，并在注释里写明
  原因。

### `dev-so`

class 故意把带版本的 `.so` 软链接放进运行期包，让 target 上的目录树保留开发
用途。属预期行为。

## 配置与构建失败

### `EPICS_BASE must be set in a configure/RELEASE file`

`configure/CONFIG` 要求 `EPICS_BASE` 必须在 RELEASE 文件里赋值，否则拒绝构建。
class 在 `epics_generate_release` 里追加它；如果 recipe 覆盖了 `do_configure`
却没有调用它，或者在 Base 之外把 `EPICS_WRITE_RELEASE` 设成了 `"0"`，就会丢掉
这条赋值。

### host pass 报 release 一致性错误

`CHECK_RELEASE` 会比较各模块 `configure/RELEASE` 里记录的依赖路径与使用方解析
出的路径。stage 进来的模块记录的是它自己的构建 sysroot，永远和使用方不一致，
所以该检查必然误报。两个生成的 `CONFIG_SITE` 文件都已设 `CHECK_RELEASE = NO`；
如果某个 recipe 又把它打开了，那就是原因。

### 链接报错找不到 `lib/linux-x86_64/lib<模块>.a`

EPICS 让交叉目标依赖 host 目标（`configure/RULES_ARCHS` 生成
`install.<cross> : install.<host>`），构建因此会尝试链一个 host 版本，而它
依赖的 host 模块库是故意不打包的。IOC 应用通过 `EPICS_MAKE_EXTRA` 清掉
`CROSS_ARCHS`；会链接其他模块的支持模块需要同样处理（见
[modules.md](modules.zh-CN.md)）。

### `Can't open perl script .../base/bin/<host-arch>/<工具>.pl`

模块和 IOC 构建要运行 Base 的 host 工具。它们在打包之后 stage 进 sysroot
（`epics-base` recipe 的 `epics_stage_host_tools`）；如果找不到，说明 sysroot
是用没有这段 staging 的旧 Base 构建填充的 —— 清理并重新构建 `epics-base`。

### `envPaths` 里出现构建目录或 sysroot 路径

IOC class 会改写 `IOCS_APPL_TOP` 并剥离 sysroot 前缀
（`classes/epics-ioc.bbclass` 的 `do_install:append`）。仍然带着这些内容的
文件，是没经过那次清洗就进了包。

### 解析 `.bbclass` 时报 `unparsed line`

BitBake 在遇到内容恰好为 `}` 的行时结束一个 shell 函数体。在生成 shell 脚本的
heredoc 里，嵌套函数的右花括号必须缩进；顶格的 `}` 会截断外层任务，剩余内容
被当成 BitBake 语法解析。任务体里的 `${小写}` shell 变量也可能与同名的 BitBake
变量冲突（`libdir` 是 `/usr/lib`）。

### `undefined reference to pvar_dset_...` 或缺少设备支持

asyn 的 `-DHAVE_DEVINT64` 这类特性宏是模块 Makefile 用 `+=` 加的。把编译选项
放到 make 命令行上会让 `+=` 失效，宏丢了而 `.dbd` 仍声明这些设备。选项必须
通过生成的 `CONFIG_SITE` 进入构建，绝不能作为命令行变量。

## 打包与运行期

### IOC 启动时报 `libasyn.so: cannot open shared object file`

模块库没有被解析到。IOC 同时需要运行期依赖和搜索路径：链接的模块写进
`RDEPENDS:${PN}`，rpath 条目来自 `EPICS_IOC_LIBDIRS`。用
`readelf -d <ioc> | grep -i path` 确认 —— Base、IOC 自身和每个链接的模块都要
在列表里。

### 实例装上了但没有启用

preset 只启用 recipe 里 `EPICS_IOC_INSTANCES` 与
`EPICS_IOC_AUTO_ENABLE = "enable"` 列出的实例；其余只安装、不启动——与
caRepeater 单元同一策略：安装不等于启动。用
`systemctl enable --now 'epics-ioc@<实例名>'` 启动。如果 systemd 找不到该
实例，检查 `/etc/epics/instances/<实例名>.env` 是否在镜像里，以及其中的
`IOC_APP_DIR`/`IOC_PATH` 是否指向已安装的应用。

### autosave：`write_it: No such file or directory`

存盘目录不存在。`ioc-start.sh` 会在启动 IOC 前创建 `$IOC_STATE`；手工运行 IOC
时需要先建好。

### asyn 读超时，`TIMEOUT INVALID`

`drvAsynIPPort` 没有中断源，`I/O Intr` 扫描永远不触发，不带结束符的轮询读也
永远等不到数据。把一次交互显式闭合：设置
`asynOctetSetInputEos`/`asynOctetSetOutputEos`，并由记录驱动收发
（`asynOctetWriteRead` 从另一条记录取命令，`asynOctetCmdResponse` 把命令写死在
链路里）。服务端端口用 `drvAsynIPServerPortConfigure` 配置，参数必须是
`<host>:<port>` 形式。

### 两个实例抢控制台端口

槽位编号对整个 target 全局生效，所以两个**不同** IOC 之间重复的
`IOC_INSTANCE_INDEX` 与同一 IOC 内部的重复一样会撞号。`ioc-ports --audit`
扫描注册表两层并报告冲突文件；`--next` 取第一个空闲槽位。实例 env
文件里显式写的 `PS_PORT` 会覆盖推导值，这是意外冲突最常见的来源。

在 target 上的现象是 `procServ: Exiting with error code: 98` 旁边跟着一句
误导性的 `Bad file descriptor`。98 是 `EADDRINUSE`，而 `perror` 打印的文字
是异常栈展开过程中被覆盖的 `errno`——看数字，别看字面。启动前
`ioc-start.sh` 会扫描 infofile，把已占用该控制台端口的实例名和 PID 打出来。

占用者未必是当前实例：rootfs 若是覆盖更新而非重新烧写，旧镜像的 unit 连同
其 `.wants` 软链接会留下来，开机即启动并占住端口（实测
`epics-asyn-scope-ioc@ioc0.service` 占着 21000）。用
`systemctl list-units --all | grep -i ioc` 查看，禁用并删除残留文件，
或干脆重新烧写 rootfs 分区。

### 客户端连不上某一个特定的 IOC

同网段客户端无需任何配置：每个 IOC 都会收到广播搜索并以自己的端口应答。某个
实例连不上时，先检查它是否固定了端口（固定后客户端需要
`EPICS_CA_ADDR_LIST="<ip>:<ca端口>"`），或者客户端是否在另一个网段——广播到不了
那里。不要用客户端的 `EPICS_CA_SERVER_PORT` 来"选实例"：它是客户端自己的单一
搜索端口，不是逐 IOC 的选择器。

## 在 target 上

```bash
systemctl status 'epics-ioc@scope01' --no-pager
journalctl -u 'epics-ioc@scope01' -n 200
netstat -ltnp | grep -E ':210[0-2][0-9]'
cat /run/epics/scope01.info
ioc-manager console scope01  # procServ 控制台 -> iocsh 提示符
telnet <板卡IP> 21010          # 从其他主机接同一个控制台
```

控制台是最快的入口：errlog 输出就在眼前，`asynSetTraceMask("L0", 0, 0x321)`
不用重启 IOC 就能抬高某个 asyn 端口的日志级别。掩码含义：`0x121`
error/warning/info，`0x321` 加 debug，`0x721` 加 trace。
