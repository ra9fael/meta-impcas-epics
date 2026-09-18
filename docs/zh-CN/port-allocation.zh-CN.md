# IOC 端口管理

[English](../port-allocation.md) | 简体中文

本文属于[文档索引](README.zh-CN.md)。

同一块 target 上的多个 IOC 实例各自需要一个控制台端口，视应用而定还需要自己的
服务端口。这部分 EPICS 本身已经管了大半：主机上的第一个 IOC 拿到默认的 CA/PVA
端口，后续每个 IOC 自动退到动态端口并通过 beacon 广播。EPICS 唯一不知道的就是
procServ 控制台，所以本 layer 唯一静态分配的就是它。

| 层 | 端口 | 管理方式 |
|----|------|----------|
| procServ 控制台 | `21000 + 10 * 槽位`（21000、21010……） | **静态槽位分配** |
| IOC 应用监听口（`APP_PORT_1/2`） | 槽位 `+1`/`+2`，可覆盖 | 可选，仅开 socket 的 IOC 需要 |
| CA 服务口 | 不分配：动态（第一个 IOC 得 5064） | EPICS 原生；可选固定 |
| PVA 服务口 | 不分配：动态（第一个 IOC 得 5075） | EPICS 原生；可选固定 |
| CA beacon/repeater、PVA 广播 | 5065 / 5076 | 主机上所有 IOC 共享 |

recipe 与实例如何配置见 [ioc.md](ioc.zh-CN.md)。

## 槽位编号

`IOC_INSTANCE_INDEX`（0–99）是操作员需要指定的唯一数字。它**对整个 target 全局
生效**：不同 IOC 类型、同一类型的不同实例，都从同一个池子里拿号——因为不能
冲突的是控制台端口。

实例 env 文件里设置：

```sh
IOC_INSTANCE_INDEX=1        # 控制台 21010，应用口 21011/21012
P=ioc1:
R=scope1:
IOC_STATE=/var/lib/<PN>/ioc1
```

换算由 `ioc-ports` 命令（`/usr/libexec/epics-ioc/ioc-ports.sh` 的薄包装）完成：

```sh
ioc-ports --show [实例名]   # 推导出的端口，以及运行中实例的实际 endpoint
ioc-ports --next            # 全 target 范围内第一个空闲槽位
ioc-ports --audit           # 扫描注册表两层，报告槽位冲突
```

新实例从随包示例复制：

```sh
cp /etc/epics/instances/<example>.env /etc/epics/instances/<name>.env
# 修改 IOC_APP_DIR / IOC_INSTANCE_INDEX / P，然后
systemctl enable --now 'epics-ioc@<name>'
```

某台机器上单个实例的差异化配置放在 BOOT 分区的
`/boot/iocs/<name>/<name>.env` 在 BOOT 分区，优先级高于随镜像安装的条目。

## procServ 控制台（唯一静态分配的口）

控制台没有任何发现机制——procServ 不向任何地方注册——所以每个实例拿到确定性的
端口 `EPICS_IOC_PORT_BASE + 10 * 序号`；一旦撞号，第二个 IOC 会显式启动失败而不是
悄悄互踩。

两个配套手段：

* procServ 以 `-I /run/epics/<实例>.info` 运行，把运行中服务器的 PID 和实际
  endpoint 落盘；`ioc-ports --show <实例名>` 会打印出来，
  `ioc-manager console <实例名>` 则直接读该 endpoint 接入控制台。
* 控制台是明文 telnet，默认 `PROCSERV_ARGS="--oneshot --allow"` 时任何主机都能连。
  `--allow` 只有长选项（不存在 `-A` 短选项），且仅靠编译期默认值不会放宽 bind 地址。
  去掉 `--allow` 即只绑本机；也可用防火墙限制 21000 段；procServ 还支持
  用 UNIX domain socket（`unix:/路径` endpoint）提供控制台，完全不占 TCP 端口。

## CA 与 PVA（动态，可选固定）

不需要分配。CA 服务端的 UDP 搜索 socket 以地址扇出方式打开（`SO_REUSEPORT`），
广播搜索能到达主机上的**每一个** IOC；拥有该 PV 的实例应答，应答里带着它自己的
TCP 端口。拿不到默认端口时——被别的 IOC 占了——服务端自动改用动态端口并在
beacon 里通告。PVA 同理：UDP 搜索口（5076）共享，TCP 口在搜索应答和 beacon 里
通告。

所以 target 上第一个 IOC 跑在 5064/5075，其余都在动态端口上，全程零配置。

只在需要确定性时才固定端口——防火墙、跨网段客户端、需要写入文档的部署：

```sh
# 实例 env 文件里；推荐值保持槽位布局：
CA_PORT=21013        # 基址 + 10*序号 + 3
PVA_PORT=21014       # 基址 + 10*序号 + 4
```

启动脚本会在 IOC 启动前把它们导出为
`EPICS_CA_SERVER_PORT` / `EPICS_PVAS_SERVER_PORT`。

## 客户端配置

| 场景 | CA（caget/caput/camonitor） | PVA（pvget/QSRV） |
|---|---|---|
| 客户端与板卡在同一广播域 | 所有槽位都零配置 | 所有槽位都零配置 |
| 跨网段 / 防火墙 | 先固定 IOC 端口（见上），再设 `EPICS_CA_ADDR_LIST="<ip>:<ca端口>"`，多个用空格分隔；`EPICS_CA_AUTO_ADDR_LIST=NO` 可全显式 | 先固定 IOC 端口，再设 `EPICS_PVA_ADDR_LIST="<ip>:5076"`（广播口共享） |

注意：

* **不要**在客户端用 `EPICS_CA_SERVER_PORT` 来"选某个 IOC"：它是客户端自己的
  单一搜索端口，不是逐 IOC 的选择器。
* 控制台端口和应用端口不是 CA 端口，绝不能出现在 `EPICS_CA_ADDR_LIST` 里。
* 广播不跨网段——这正是提供固定端口选项的原因。
