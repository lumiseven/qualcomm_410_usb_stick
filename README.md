# 创景 SP970_HW_V9：确认型号并刷入 Debian 12 的完整记录

本记录对应 2026-11-16 的实际操作，整理于 2026-11-17。工作目录为 `/home/lumiseven/record/20261116`。

**结果：原厂 Android 4.4.4 已替换为 Debian 12.7 Bookworm，USB 网络、SSH、Wi-Fi 热点可用，软件重启后能够重新登录。蜂窝 4G Modem 尚不可用。**

本文中的命令用于复现这次操作，不是可以不加检查整段执行的无人值守脚本。尤其要确认当前 fastboot 序列号、原机备份目录、镜像来源和分区容量。

## 1. 已确认的硬件与最终状态

| 项目 | 实测结果 |
|---|---|
| 型号 | `SP970_HW_V9` |
| 厂商 | `CHUANGJING`，创景 |
| SoC | Qualcomm MSM8916 / 骁龙 410 |
| 原系统 | Android 4.4.4 |
| 原系统硬件属性 | `ro.product.version.hardware=H01` |
| eMMC | lk2nd 显示约 3728 MiB |
| Linux 可用内存 | `free -h` 显示总计约 382 MiB，不能据此直接认定物理内存规格 |
| 新系统 | Debian GNU/Linux 12 Bookworm，`/etc/debian_version` 为 `12.7` |
| 内核 | `5.15.0-handsomekernel+`，aarch64 |
| 根分区 | `/dev/mmcblk0p14`，约 3.3 GiB，可用约 2.6 GiB |
| USB 管理地址 | 设备 `192.168.5.1/24`，电脑 `192.168.5.2/24` |
| Wi-Fi 热点 | SSID `Openstick`，密码 `openstick`，设备地址 `192.168.4.1` |
| SSH | 用户 `user`，本次配置了专用公钥；`sudo -i` 可切换管理员 |
| 已知限制 | Modem `MPSS authentication failed: -19`；`mmcli -L` 无 Modem；视频固件未配置 |

Wi-Fi 热点状态已从设备侧验证，未用手机实际连接验证；热点可见不代表具备互联网出口。软件重启经过验证，尚未另外进行断电冷启动测试。没有执行全量软件更新。

## 2. 先阅读：同型号设备复用边界

- 本次成功记录针对 **SP970_HW_V9**。不能仅凭商家说“SP970”就认定所有硬件修订均相同。
- **另一台设备必须重新读取它自己的 `fsc`、`fsg`、`modemst1`、`modemst2`、`persist` 和无线固件。** 不要复制本目录 `device-original/` 中的校准数据到其他设备。
- `assembled/rootfs.raw` 是本台设备定制的镜像，包含本台 Wi-Fi 校准文件、公钥及 SSH 主机密钥。另一台设备应从原始 Debian 12 镜像重新组装，不直接复制最终镜像。
- 不要公开上传 `device-original/`、SSH 私钥或整个工作目录。原机分区可能包含设备标识及原系统数据。
- 原厂分区表会被替换，原 Android 不再保留。本次保存了多个关键分区，但**不是整盘备份，也未验证一键回滚到原厂的流程**。
- 本目录的 `progress.json` 是过程快照，含历史 `pending` 字段，不应当作待执行任务清单。以本文、实际文件和设备状态为准。

## 3. 主机环境与文件布局

本次使用 Linux 主机，通过 USB 操作。主要工具：

```bash
fastboot --version
adb version
command -v python3 curl unzip git debugfs e2fsck ssh ssh-keygen nmcli
```

另用到了 `mtools` 的 `mdir`、`mcopy`，以及 `dtc`。本次没有主机免密 sudo，因此通过 `apt download` 下载工具包后用 `dpkg-deb -x` 解压运行；普通 Linux 环境也可通过发行版包管理器安装这些工具。不要照搬目录中 Ubuntu 特定版本的 `.deb` 到其他发行版。

主要目录：

```text
README.md
sp970-debian/                      调查参考项目，未直接运行 build.sh
openstick-upstream/                OpenStick 官方仓库
firmware-downloads/
  openstick-debian-v0.2.zip         Debian 12 原始系统包
  openstick-official-debian.zip     官方旧系统包，仅提取匹配的 5.15 模块
  boot-sp970.img                    最终使用的 SP970 Android 格式启动镜像
  base-generic.zip                  最终使用的官方底层引导基础包
  official-base/                    从基础包选取的引导与 GPT 文件
  lk2nd-msm8916.img                 临时 RAM 启动的 lk2nd 23.1
  lk2nd-sha256sums.txt               发布方摘要列表
  unsparse.py                       本次编写的 Android sparse 转 raw 工具
  v0.2/                            原始 Debian 12 镜像及中间副本
  official-debian/                  官方旧系统包解压目录
  official-modules/                 与 5.15 内核匹配的模块
  original-firmware/                从本机 modem 分区提取的固件
  device-original/                  本机原始分区、build.prop、摘要
  readback/                         写入后读回的校准分区
  assembled/                       最终组装镜像、配置、日志及 SSH 脚本
```

**下面命令均以工作目录为当前目录。** 新设备应使用新的独立工作目录，并重新下载或复制通用原始包；不要覆盖本次备份。fastboot 示例中的序列号是本次值，复用时根据 `fastboot devices` 修改。

## 4. 从 USB 状态开始确认设备

### 4.1 进入原厂 fastboot

本机实测操作：拔下设备，按住唯一的重置键，插入 USB，约 5 秒后松手。

```bash
lsusb
fastboot devices
adb devices -l
fastboot -s 123456789123 getvar product
fastboot -s 123456789123 oem device-info
```

原厂模式结果：

```text
USB ID: 18d1:d00d
fastboot serial: 123456789123
product: MSM8916
Device unlocked: false
```

`lsusb` 的 `Google Inc. Xiaomi Mi/Redmi 2 (fastboot)` 是 USB ID 数据库名称，**不是实际型号证据**。fastboot 与 ADB 是不同接口，处于 fastboot 时 `adb devices` 为空正常。

### 4.2 本次尝试过但未取得型号的路径

执行 `fastboot reboot` 后，设备以 `05c6:f00e` 出现，只暴露 RNDIS USB 网卡，没有 ADB。网卡未获得 DHCP 地址；临时配置地址后检查 `192.168.100.1`、`192.168.43.1`、`192.168.1.1`、`192.168.0.1` 的 80/8080 端口，ARP 解析及连接失败。测试网络配置已移除。

照片中的天线片有类似 `SP970-Main-V2` 的字样，只能辅助判断系列，不能当作主板版本。**不需要拆散热片或屏蔽罩**：后来通过原系统属性确认了型号。

原始照片：

- `/home/lumiseven/Downloads/20261116_220616.jpg`
- `/home/lumiseven/Downloads/20261116_220623.jpg`

## 5. 镜像搜索、来源及最终取舍

### 5.1 下载来源

| 来源 | 用途 |
|---|---|
| [OpenStick 官方 v1](https://github.com/OpenStick/OpenStick/releases/tag/v1) | `base-generic.zip`、`boot-sp970.img`、`debian.zip` |
| [OpenStick-Builder v0.2](https://github.com/kinsamanka/OpenStick-Builder/releases/tag/v0.2) | `openstick-debian.zip`，本次 Debian 12 根文件系统来源 |
| [lk2nd 23.1](https://github.com/msm8916-mainline/lk2nd/releases/tag/23.1) | RAM 临时启动及分区读取 |
| [SP970 Debian 适配项目](https://github.com/antnesswcm/sp970-debian) | SP970 设备树、USB 配置及固件适配参考 |

参考项目本地提交为 `7765703d2549f129f1bf0ebe8998f673d000d07e`。调查时没有可直接下载的 Release；其构建脚本与说明存在引导配置差异，因此没有直接执行仓库的整体刷机/构建脚本。

```bash
mkdir -p firmware-downloads
curl -fL --retry 2 -o firmware-downloads/openstick-debian-v0.2.zip \
  https://github.com/kinsamanka/OpenStick-Builder/releases/download/v0.2/openstick-debian.zip
curl -fL --retry 2 -o firmware-downloads/base-generic.zip \
  https://github.com/OpenStick/OpenStick/releases/download/v1/base-generic.zip
curl -fL --retry 2 -o firmware-downloads/boot-sp970.img \
  https://github.com/OpenStick/OpenStick/releases/download/v1/boot-sp970.img
curl -fL --retry 2 -o firmware-downloads/openstick-official-debian.zip \
  https://github.com/OpenStick/OpenStick/releases/download/v1/debian.zip
curl -fL --retry 2 -o firmware-downloads/lk2nd-msm8916.img \
  https://github.com/msm8916-mainline/lk2nd/releases/download/23.1/lk2nd-msm8916.img
curl -fL --retry 2 -o firmware-downloads/lk2nd-sha256sums.txt \
  https://github.com/msm8916-mainline/lk2nd/releases/download/23.1/sha256sums.txt
```

必须等待下载进程成功结束，再解压。下载未完成时出现 ZIP 中央目录缺失，不等同于源包损坏。

### 5.2 为什么不能下载后原样刷

- v0.2 包内部实际是 Debian 12，但默认启动配置使用 UZ801 设备树。
- UFI001C 的按键和 LED GPIO 与 SP970 不同，不能直接代替 SP970。
- 官方 SP970 `boot-sp970.img` 的内核是 **5.15.0-handsomekernel+**，必须配同版本模块。
- 本次也下载过 postmarketOS 6.12.1 内核并检查 SP970 适配资料，**最终没有使用该内核**。
- 最终组合是：**v0.2 的 Debian 12 根文件系统 + 官方 SP970 5.15 启动镜像 + 官方旧系统包中的匹配模块 + 本设备原机固件/校准 + USB/SSH 配置修改**。

### 5.3 校验依据

lk2nd 依据发布方 `sha256sums.txt` 比对通过：

```text
8f5f788b45b96447517ff121f20841e6bfc95a5d7c4b48fdedb855d90f593144  lk2nd-msm8916.img
```

下列为本地计算的指纹，不能冒充发布方签名验证：

```text
89aee177b6bab23b28748188d75cda38c702c5813fe4135d27a9540735dc7fca  openstick-debian-v0.2.zip
3db7f25f989de8934a959194b5edaff85b95350ae0801708f3f4cbbabafbcc16  boot-sp970.img
6dae09f6ac0ea4d8c94eec67baf1f79ff15203678401b9221c78629ed67ae2dc  assembled/rootfs.raw
```

最终 rootfs 指纹仅对应本次组装结果。换设备、换密钥、重新组装后应生成新的摘要。

## 6. 临时启动 lk2nd，取得型号及原机分区

### 6.1 RAM 启动，不立即覆盖原厂引导

```bash
fastboot -s 123456789123 boot firmware-downloads/lk2nd-msm8916.img
fastboot devices
fastboot -s 123456789321 getvar product
fastboot -s 123456789321 getvar all
fastboot -s 123456789321 oem log
fastboot -s 123456789321 get_staged firmware-downloads/lk2nd-device.log
```

本次序列号变为 `123456789321`，product 为 `lk2nd-msm8916`。原厂报告未解锁，但本次 RAM 启动成功，**没有执行 `oem unlock` 或 `flashing unlock`**。其他设备如拒绝该操作，应停下核对，不应自动套用解锁或擦除命令。

lk2nd 日志显示没有匹配到准确的设备节点，但 fastboot 分区读取可用；这不能解释为 lk2nd 自动确认了 SP970 型号。

### 6.2 读取分区

当前版本 fastboot 需要支持 `fetch`：

```bash
mkdir -p firmware-downloads/device-original
# 在新的独立目录中执行，不能覆盖其他设备的备份。
for part in fsc fsg modemst1 modemst2 aboot sbl1 rpm tz hyp; do
  fastboot -s 123456789321 fetch "$part" \
    "firmware-downloads/device-original/$part.bin" || break
done
fastboot -s 123456789321 fetch system firmware-downloads/device-original/system.img
fastboot -s 123456789321 fetch modem firmware-downloads/device-original/modem.img
fastboot -s 123456789321 fetch persist firmware-downloads/device-original/persist.img
```

每条命令应返回成功；循环中的失败必须处理后再继续。本次 system 分区 800 MiB，读取约 87 秒，中途会分块输出，不能因短时间没有输出就重新发起读取。

lk2nd 会把 boot 前 512 KiB 作为 `lk2nd` 虚拟分区，`fetch boot` 返回剩余部分。完整 boot 需要拼接：

```bash
fastboot -s 123456789321 fetch lk2nd firmware-downloads/device-original/boot-prefix.bin
fastboot -s 123456789321 fetch boot firmware-downloads/device-original/boot-tail.bin
cat firmware-downloads/device-original/boot-prefix.bin \
    firmware-downloads/device-original/boot-tail.bin \
    > firmware-downloads/device-original/boot.img
```

仅适用于本次所验证的 lk2nd 分区视图，不要在原厂 fastboot 中假定相同行为。

### 6.3 取得明确型号

```bash
debugfs -R 'cat /build.prop' firmware-downloads/device-original/system.img
debugfs -R 'dump /build.prop firmware-downloads/device-original/build.prop' \
  firmware-downloads/device-original/system.img
```

本次关键属性：

```text
ro.product.model=SP970_HW_V9
ro.product.manufacturer=CHUANGJING
ro.product.board=msm8916
ro.board.platform=msm8916
ro.build.version.release=4.4.4
ro.product.version.hardware=H01
```

读取完整前用 debugfs 打开 system.img 曾出现位图读取错误；完整读取后正常，不能将未完成的文件当作损坏分区。

### 6.4 提取原机无线固件及校准

modem 分区是 FAT16：

```bash
mkdir -p firmware-downloads/original-firmware
mdir -i firmware-downloads/device-original/modem.img ::/image
mcopy -i firmware-downloads/device-original/modem.img '::/image/*' \
  firmware-downloads/original-firmware/
debugfs -R 'dump /WCNSS_qcom_wlan_nv.bin firmware-downloads/device-original/WCNSS_qcom_wlan_nv.bin' \
  firmware-downloads/device-original/persist.img
sha256sum firmware-downloads/device-original/*.bin \
  firmware-downloads/device-original/*.img \
  > firmware-downloads/device-original/SHA256SUMS
```

本次使用解压版工具时，`mdir`、`mcopy` 的路径为 `firmware-downloads/mtools/usr/bin/`。

## 7. 组装 Debian 12 镜像

此阶段只修改电脑上的镜像文件。**所有 debugfs 写操作都要指向本地副本，不能指向主机磁盘设备。**

### 7.1 解压与验证版本

```bash
unzip firmware-downloads/openstick-debian-v0.2.zip -d firmware-downloads/v0.2
python3 firmware-downloads/unsparse.py firmware-downloads/v0.2/rootfs.bin \
  firmware-downloads/v0.2/rootfs.raw
python3 firmware-downloads/unsparse.py firmware-downloads/v0.2/boot.bin \
  firmware-downloads/v0.2/boot.raw
debugfs -R 'cat /usr/lib/os-release' firmware-downloads/v0.2/rootfs.raw
e2fsck -fn firmware-downloads/v0.2/rootfs.raw
```

应看到 `VERSION_ID="12"` 和 `VERSION_CODENAME=bookworm`。debugfs 不像正常文件系统那样自动处理所有路径中的符号链接，本次读取 `/etc/os-release` 失败，读取实际文件 `/usr/lib/os-release` 成功。

### 7.2 固定软件源

建立 `firmware-downloads/bookworm-sources.list`：

```text
deb https://deb.debian.org/debian bookworm main contrib non-free-firmware
deb https://deb.debian.org/debian-security bookworm-security main contrib non-free-firmware
deb https://deb.debian.org/debian bookworm-updates main contrib non-free-firmware
```

```bash
cp --reflink=auto firmware-downloads/v0.2/rootfs.raw firmware-downloads/v0.2/rootfs-bookworm.raw
debugfs -w -R 'rm /etc/apt/sources.list' firmware-downloads/v0.2/rootfs-bookworm.raw
debugfs -w -R 'write firmware-downloads/bookworm-sources.list /etc/apt/sources.list' \
  firmware-downloads/v0.2/rootfs-bookworm.raw
mkdir -p firmware-downloads/assembled
cp --reflink=auto firmware-downloads/v0.2/rootfs-bookworm.raw firmware-downloads/assembled/rootfs.raw
```

不能保留随发行版变化的 `stable` 名称，否则以后更新可能跨到 Debian 13 或更新版本。

### 7.3 提取匹配模块

```bash
unzip firmware-downloads/openstick-official-debian.zip -d firmware-downloads/official-debian
python3 firmware-downloads/unsparse.py firmware-downloads/official-debian/debian/rootfs.img \
  firmware-downloads/official-debian/rootfs.raw
mkdir -p firmware-downloads/official-modules
debugfs -R 'rdump /lib/modules firmware-downloads/official-modules' \
  firmware-downloads/official-debian/rootfs.raw
```

提取结果应包含 `modules/5.15.0-handsomekernel+/`。普通用户运行 rdump 会出现无法设置 root 属主的警告；本次文件仍被提取，之后注入镜像时检查目标属主为 root。不能忽略实际文件缺失或读取失败。

Wi-Fi 模块实测：

```bash
strings firmware-downloads/official-modules/modules/5.15.0-handsomekernel+/kernel/drivers/net/wireless/ath/wcn36xx/wcn36xx.ko \
  | rg 'vermagic|firmware='
```

结果包含 `vermagic=5.15.0-handsomekernel+ ... aarch64`，与启动镜像完全一致。

### 7.4 本次镜像注入与修改清单

本目录保存了实际执行过的 debugfs 命令文件，可用于审计和复现：

| 文件 | 作用 |
|---|---|
| `assembled/inject.debugfs` | 加入本机 wcnss/modem/mba 固件、Wi-Fi 校准、SSH 用户公钥 |
| `assembled/management.debugfs` | USB NCM 服务、脚本、开机链接、fstab |
| `assembled/modules.debugfs` | 加入 5.15 模块、禁用独立 dnsmasq 服务、替换共享 SSH 主机密钥 |
| `assembled/sp970-usb.sh` | 实际 USB configfs/NCM 脚本 |
| `assembled/usb-gadget.service` | 实际 systemd 服务 |
| `assembled/fstab` | 不挂载 Android 格式的 boot 分区 |

这些命令文件**不是幂等脚本**。应在干净镜像副本上依次执行，检查日志；不要对已修改镜像反复重放。

```bash
# 前提：当前设备固件、密钥及上述命令文件均已准备和核对。
debugfs -w -f firmware-downloads/assembled/inject.debugfs firmware-downloads/assembled/rootfs.raw
debugfs -w -f firmware-downloads/assembled/management.debugfs firmware-downloads/assembled/rootfs.raw
debugfs -w -f firmware-downloads/assembled/modules.debugfs firmware-downloads/assembled/rootfs.raw
```

重新用于其他设备时，需重新生成上述注入清单，或逐行核对路径及内容：

1. 从**当前设备**的 `original-firmware/` 中将 `wcnss.*`、`modem.*`、`mba.*` 写入 `/usr/lib/firmware/`。
2. 将当前设备的校准文件写入 `/usr/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin`。
3. 将提取的 `5.15.0-handsomekernel+` 模块树写入 `/usr/lib/modules/`，保留依赖索引。
4. 为新设备生成新的 `sp970_ed25519` 客户端密钥及 `ssh_host_ed25519_key` 主机密钥，不覆盖或共享本次私钥：

   ```bash
   ssh-keygen -t ed25519 -N '' -C sp970-local-management -f firmware-downloads/assembled/sp970_ed25519
   ssh-keygen -t ed25519 -N '' -C sp970-host -f firmware-downloads/assembled/ssh_host_ed25519_key
   ```

5. 公钥写入 `/home/user/.ssh/authorized_keys`；目录属主 `1000:1000`、权限 0700，文件属主 `1000:1000`、权限 0600。
6. 删除镜像原有共享 SSH 主机密钥，写入新主机密钥；私钥属主 root、权限 0600。
7. USB 服务启用到 `multi-user.target.wants`；脚本权限 0755。USB 两端 MAC 本次为 `02:53:50:97:00:01` / `02:53:50:97:00:02`，若同时接多台设备，应分配不同 MAC、序列号及管理网段。
8. 使用原镜像 `usb.nmconnection` 的 `192.168.5.1/24` 和 `method=shared`。禁用独立 `dnsmasq.service` 的开机链接，让 NetworkManager 管理自己的 dnsmasq。
9. 去掉原 fstab 中的 ext2 `/boot` 挂载：最终使用的是 Android boot image，不是 v0.2 的 ext2 boot.bin。

USB NCM 已确认是官方 5.15 内核的内置功能。用户态保持 Debian 12，不能因提取旧系统包的模块而覆盖整个 Debian 12 rootfs。

### 7.5 写入前检查

```bash
sh -n firmware-downloads/assembled/sp970-usb.sh
e2fsck -fn firmware-downloads/assembled/rootfs.raw
debugfs -R 'cat /usr/lib/os-release' firmware-downloads/assembled/rootfs.raw
debugfs -R 'cat /etc/apt/sources.list' firmware-downloads/assembled/rootfs.raw
debugfs -R 'stat /usr/lib/modules/5.15.0-handsomekernel+/modules.dep' firmware-downloads/assembled/rootfs.raw
sha256sum firmware-downloads/assembled/rootfs.raw firmware-downloads/boot-sp970.img \
  > firmware-downloads/assembled/SHA256SUMS
```

## 8. 实际刷写顺序

**只有完成当前设备备份、型号确认及镜像组装后才进入本节。以下命令会修改设备引导和分区，必须逐步检查返回值。任一步失败应停下，不继续后续命令。**

### 8.1 从基础包只提取通用文件

`base-generic.zip` 中还带有示例 fsg/modemst 文件和 flash.sh，**不能直接运行其整套脚本，也不能把包内 NV 当成本机数据**。

```bash
python3 - <<'PY'
from pathlib import Path
from zipfile import ZipFile
p = Path('firmware-downloads/official-base')
p.mkdir(exist_ok=True)
with ZipFile('firmware-downloads/base-generic.zip') as z:
    for name in ['aboot.bin', 'gpt_both0.bin', 'hyp.mbn', 'rpm.mbn',
                 'sbl1.mbn', 'tz.mbn', 'sbc_1.0_8016.bin']:
        (p / name).write_bytes(z.read('base/' + name))
PY
```

### 8.2 先替换 aboot，再进入新的 fastboot

此时仍处于临时 lk2nd：

```bash
fastboot -s 123456789321 flash aboot firmware-downloads/official-base/aboot.bin
fastboot -s 123456789321 reboot bootloader
fastboot devices
fastboot -s 6556d077 getvar product
```

本次新序列号为 `6556d077`，product 为 `LK1ST_MSM8916`。**序列号变化后需要重新选择设备。**

### 8.3 写分区表、底层引导及本机 NV

```bash
fastboot -s 6556d077 flash partition firmware-downloads/official-base/gpt_both0.bin
fastboot -s 6556d077 flash hyp firmware-downloads/official-base/hyp.mbn
fastboot -s 6556d077 flash rpm firmware-downloads/official-base/rpm.mbn
fastboot -s 6556d077 flash sbl1 firmware-downloads/official-base/sbl1.mbn
fastboot -s 6556d077 flash tz firmware-downloads/official-base/tz.mbn
fastboot -s 6556d077 flash fsc firmware-downloads/device-original/fsc.bin
fastboot -s 6556d077 flash fsg firmware-downloads/device-original/fsg.bin
fastboot -s 6556d077 flash modemst1 firmware-downloads/device-original/modemst1.bin
fastboot -s 6556d077 flash modemst2 firmware-downloads/device-original/modemst2.bin
fastboot -s 6556d077 flash aboot firmware-downloads/official-base/aboot.bin
fastboot -s 6556d077 flash cdt firmware-downloads/official-base/sbc_1.0_8016.bin
fastboot -s 6556d077 reboot bootloader
```

本次没有另行执行 erase boot/rootfs。官方基础布局没有单独的 modem/persist 分区，所以原机固件/校准已经提前注入 rootfs。**不能只“不写 modemst”就声称保留 NV：分区表变化会改变其位置。**

重启后检查：

```bash
fastboot -s 6556d077 getvar partition-size:boot
fastboot -s 6556d077 getvar partition-size:rootfs
fastboot -s 6556d077 getvar partition-size:tz
fastboot -s 6556d077 getvar partition-size:modemst1
```

本次分别返回 `0x4000000`、`0xd4dfbe00`、`0x100000`、`0x200000`。官方 GPT 文件中的 rootfs 尾部是扩展占位布局，由引导处理后扩展到设备末尾；不能把该文件简单当作固定容量的完整磁盘镜像用 dd 写入。

刷写时曾出现 `skip copying ... avb footer` 提示和旧容量信息，但相关写入返回 OKAY，重启后容量如上。复用时仍需检查实际返回值，不能把所有 warning/FAIL 都视作正常。

### 8.4 写入启动镜像和 Debian 12

```bash
fastboot -s 6556d077 flash boot firmware-downloads/boot-sp970.img
fastboot -s 6556d077 -S 128M flash rootfs firmware-downloads/assembled/rootfs.raw
```

**本次 rootfs 分 4 块写入，总耗时 451.130 秒。最后一块写入耗时 320.066 秒，其间长时间没有输出，最后成功返回 OKAY。**

不要因几十秒无输出就拔插、重复启动 fastboot 或重刷。等待同一进程完成；可从主机进程和内核日志检查状态，但不能仅凭进程存活就证明设备仍在推进写入，也不能仅凭耗时就断言卡死。

### 8.5 读回校准数据后启动

新引导使用 `oem dump` / `get_staged`：

```bash
mkdir -p firmware-downloads/readback
fastboot -s 6556d077 oem dump fsc
fastboot -s 6556d077 get_staged firmware-downloads/readback/fsc.bin
# 对 fsg、modemst1、modemst2 同样执行 dump + get_staged。
```

新旧分区容量可能不同，应按原文件长度比较前缀，而不是要求整个读回文件长度相同：

```python
from pathlib import Path
p = Path('firmware-downloads')
for name in ['fsc', 'fsg', 'modemst1', 'modemst2']:
    original = (p / 'device-original' / f'{name}.bin').read_bytes()
    restored = (p / 'readback' / f'{name}.bin').read_bytes()
    assert restored[:len(original)] == original, name
```

本次四项均通过。然后：

```bash
fastboot -s 6556d077 reboot
```

## 9. USB 网络、SSH 和启动验证

### 9.1 主机配置

启动后本次 USB ID 为 `1d6b:0104`，电脑网卡为 `enx025350970002`。原主机连接自动 DHCP 没及时完成，因此配置独立静态连接：

```bash
ip -br address
nmcli connection add type ethernet ifname enx025350970002 con-name sp970-debian12 \
  ipv4.method manual ipv4.addresses 192.168.5.2/24 ipv4.never-default yes ipv6.method disabled
nmcli connection up sp970-debian12
```

已存在连接时不要重复创建。使用 `ipv4.never-default yes` 保留电脑原有 Wi-Fi 默认路由；这里没有设置电脑向设备共享互联网。

### 9.2 登录

本次目录已经有登录脚本：

```bash
./firmware-downloads/assembled/ssh-sp970.sh
sudo -i
```

脚本使用 `sp970_ed25519` 和 `known_hosts`，固定校验新生成的 SSH 主机公钥。新设备应根据自己的 `ssh_host_ed25519_key.pub` 重建 known_hosts：

```bash
awk '{print "192.168.5.1 " $1 " " $2}' \
  firmware-downloads/assembled/ssh_host_ed25519_key.pub \
  > firmware-downloads/assembled/known_hosts
```

不要通过关闭主机密钥校验来掩盖连接到另一台设备的问题。镜像原始密码未作为本次验收方法；使用专用密钥登录后可执行 `passwd` 修改账户密码。热点默认密码也应按使用场景修改。

### 9.3 验收命令

```bash
cat /etc/os-release
cat /etc/debian_version
uname -a
findmnt /
df -h /
free -h
systemctl --failed --no-pager
systemctl is-active ssh usb-gadget NetworkManager
nmcli device status
sudo mmcli -L
cat /proc/sys/kernel/random/boot_id
```

本次系统和内核符合预期，根分区启动后自动扩展到约 3.3 GiB，没有失败的 systemd 服务。记录 boot_id，执行 `sudo reboot`，等待 USB 网络重新出现，再 SSH 登录并重新检查。

本次重启前后 boot_id 不同；SSH 再次登录成功，USB 网络和 Wi-Fi 热点自动恢复。SSH 刚能连上时 Wi-Fi 曾短暂显示 disconnected，稍后自动连上 hotspot。

记录见 `assembled/post-reboot-verification.txt`；该文件捕获时 Wi-Fi 仍在初始化，之后另外查询已确认 hotspot connected。

设备未接互联网时系统时间初始不正确，本次用主机当前 Unix 时间执行 `sudo date -u -s @时间戳` 校正。长期使用需配置可达的 NTP/网络上游；手动校时不等于验证了断电后的时间保持。

## 10. 已知问题与不应误读的结果

### 蜂窝 Modem 尚未适配成功

内核日志：

```text
qcom-q6v5-mss ... MPSS authentication failed: -19
remoteproc ... Boot failed: -19
```

`mmcli -L` 返回 `No modems were found`。原机 NV 已保留并读回比对，但这不保证该内核/固件组合的蜂窝 Modem 可用。SIM 卡上网、短信等不是本次已验证的功能。官方 v1 发布说明也指出 SP970 的 Modem 支持存在限制。

### 视频固件缺失

日志有 `qcom/venus-1.8/venus.mdt` 缺失。未验证硬件视频编解码，不影响本次 USB/SSH 使用。

### 热点与互联网是两回事

`wlan0` 运行 hotspot、地址为 `192.168.4.1`，并不能证明有上游互联网。此次没有配置蜂窝上网或主机 NAT 共享，不能把“热点已启动”写成“4G 路由功能完整可用”。

### 内核版本较旧

Debian 用户空间是 12，但设备内核为社区 SP970 适配的 5.15.0-handsomekernel+，不是 Debian 通用内核。更新 Debian 软件包不等于更新了这套内核；不要无验证替换启动镜像或混装不同内核模块。

## 11. 下次同设备上手顺序

1. 独立工作目录，确认是 MSM8916，进入原厂 fastboot。
2. 下载并校验 lk2nd，RAM 启动；重新确认序列号。
3. 导出当前设备的原始分区，读取 build.prop，确认 `SP970_HW_V9`。
4. 从通用包重建 Debian 12 副本，加入当前设备固件、校准文件及新密钥；检查模块与 boot 版本一致。
5. 检查文件系统、软件源、USB 服务和镜像摘要，准备齐所有文件再改引导。
6. 按第 8 节顺序刷入引导、GPT、当前设备 NV、SP970 boot 和定制 rootfs。
7. 等待 fastboot 完整成功；读回 NV 对比；再重启。
8. 配置电脑 USB 地址，SSH 验证 Debian 12、空间、服务及实际重启。
9. 明确交付边界：USB/SSH/Wi-Fi 热点可用，蜂窝 Modem 仍待适配；保存每台设备各自的备份与密钥。

不要将这份记录中的固定序列号、原机分区和最终镜像无区别用于另一台设备。

## 12. 2026-11-17：配置为 sing-box 同网段旁路由

本节是刷机完成后的新增配置；前文 `Openstick` 热点信息属于刷机验收阶段。现在 `wlan0` 改为连接上游 Wi-Fi，不再自动开启原热点。

### 拓扑与地址

```text
客户端（仍连接 8-102，IPv4 网关/DNS=192.168.3.71）
  → SP970 wlan0 192.168.3.71/24
  → sing-box / Trojan TLS
  → hk2.showdoc.lumione.top:8443
  → 公网出口 8.218.139.124
```

- 上游：`8-102`，网关 `192.168.3.1`。
- 设备静态地址：`192.168.3.71/24`，NetworkManager 配置名 `uplink-8-102`，开机自动连接。
- USB 管理保持 `192.168.5.1`，电脑为 `192.168.5.2`，原 SSH 脚本继续使用。
- Wi-Fi 省电关闭。该 SSID 有多个 AP；初次配置固定 BSSID `24:69:8E:2F:05:AC`；后续因手机 TCP 广播异常，改为固定主路由接入点 `90:76:9F:46:21:DD`（当前值）。若 AP 更换，应调整绑定。
- 仅配置 IPv4 旁路由。客户端应关闭 IPv6，或另行规划 IPv6 接管，避免走原主路由的 IPv6 出口。
- 应在主路由 DHCP 设置中保留/排除 `192.168.3.71`，避免之后分配给其他设备。本次没有登录主路由修改 DHCP。

### sing-box 与转发方式

使用用户提供的 `sing-box_1.14.4_linux_arm64.deb`，已安装并核对 `sing-box version`。代理凭据保存在设备 `/etc/sing-box/config.json`（root:sing-box，0640）及本地 `router-setup/config.json`（0600）；不要提交这些配置到公开仓库。本文不记录密码。

- 公网 TCP：iptables-legacy NAT REDIRECT → sing-box `12346`。
- 公网 UDP：iptables-legacy mangle TPROXY → sing-box `12345`，fwmark `0x71/0xff`、策略路由表 `171`、规则优先级 `1071`。
- 客户端 TCP/UDP 53：重定向到 `5353`，sing-box 内置 DNS 通过 Trojan 使用 `1.1.1.1:53` 的 TCP DNS。
- 节点域名使用 `223.5.5.5` 引导解析，避免代理自身的 DNS 循环。
- 私网、组播及保留地址绕过公网透明代理；ICMP 不通过 Trojan，不能用 ping 的出口来判断代理是否生效。
- 关闭 IPv4 ICMP redirect、反向路径过滤，开启 IPv4 forwarding。
- TCP/UDP 接管仅针对 wlan0、usb0 的入站转发流量，不全局劫持设备自己的 OUTPUT。
- 额外保留 USB 地址上的测试 SOCKS/HTTP 混合端口 `192.168.5.1:1080`，未在 Wi-Fi 地址开放混合代理端口。
- 原 NetworkManager USB 共享连接的 nftables 规则保留；自定义代理规则使用独立 legacy 链，不清空系统防火墙。

本地配置文件在 `router-setup/`，设备对应文件：

```text
/etc/sing-box/config.json
/usr/local/sbin/sp970-router
/etc/sysctl.d/90-sp970-router.conf
/etc/systemd/system/sp970-router.service
```

`sing-box.service` 和 `sp970-router.service` 已启用开机启动。网络配置与规则脚本已保存；本轮没有另行重启设备验证旁路由配置的冷启动行为。

### CA 信任修复

初始 Debian 镜像没有 `/etc/ssl/certs/ca-certificates.crt`，代理报 unknown authority。电脑使用自身信任库成功验证节点的 Let’s Encrypt 证书链后，将电脑公开 CA bundle 安装到设备同一路径，权限 0644，重启 sing-box 后出口测试成功。**没有设置 TLS insecure 或关闭证书验证。**

尝试过 apt 更新，但索引下载耗时较长，已终止该次 apt update；没有完成 ca-certificates 软件包安装或全系统更新。当前信任库是从主机安装的快照，后续应通过 Debian ca-certificates 包维护更新。

### 客户端设置与实测

客户端保留自己的 `192.168.3.x/24` 地址，将 IPv4 网关和 DNS 均设置为 `192.168.3.71`，不要把客户端自身 IP 设成 `.71`。不要同时保留备用 DNS 指向主路由；浏览器 DoH/应用 VPN 可能改变 DNS 路径。

已验证：

- 设备上游网关可达，sing-box 配置校验通过，两项服务 active/enabled。
- 从电脑经 USB 显式 SOCKS 代理访问查询出口，返回 `8.218.139.124`。
- 从电脑仅为测试目标临时指定 USB 网关，以无显式代理的 HTTPS 请求验证 TCP 透明转发，出口为 `8.218.139.124`，Cloudflare 显示 HKG/HK。
- 向 `192.168.3.71:53` 发 UDP DNS 查询，收到正常答案。
- 用户用另一台 Wi-Fi 客户端实际测试，确认网页可打开，出口显示 `8.218.139.124`。
- 日志观察到客户端 TCP REDIRECT 和 UDP TPROXY 命中。UDP/QUIC 曾出现节点连接超时，未据此宣称所有 UDP 应用或长期稳定性均已验证。

同名 AP 的跨 AP 测试中曾出现代理 ARP、广播包和 TCP 超时，切换 AP 时也出现节点连接超时。手机实测已通，但不要把这次验证等同于压力测试。电脑的单目标临时路由均已移除，默认网关保持原设置。

### 管理与回退

先通过原 USB SSH 脚本登录，再执行：

```bash
sudo sing-box check -c /etc/sing-box/config.json
sudo systemctl status sing-box sp970-router
sudo journalctl -u sing-box -n 60 --no-pager
sudo iptables-legacy -t nat -nvL SP970_DNS
sudo iptables-legacy -t mangle -nvL SP970_PROXY
ip rule
ip route show table 171
```

修改配置后先 `sing-box check`，再 `sudo systemctl restart sing-box`。修改防火墙脚本后使用 `sudo systemctl restart sp970-router`；脚本只清理自身规则。

恢复客户端直连最直接的方式：将客户端网关/DNS 改回主路由 `192.168.3.1`。如要停用设备代理规则：

```bash
sudo systemctl disable --now sp970-router
sudo systemctl disable --now sing-box
```

停止 sp970-router 会移除代理规则，不是“断网保护”开关。规则运行而 sing-box 不工作时，被接管的 TCP/UDP 不会自动切换到另一个代理节点。TLS、节点可达性、Wi-Fi 链路及客户端 IPv6 设置均需独立检查。

### 2026-11-17：手机搜索慢、偶发超时排查（进行中）

手机 IP 为 `192.168.3.130`，反馈 Google 搜索慢。以下为短时样本，不能代表长期稳定性：

- 设备负载约 0.02，可用内存约 275 MiB，未见 CPU/内存耗尽。
- 设备到主路由 10 次 ping：0% 丢包，平均 4.3 ms；到手机 15 次：0% 丢包，平均 38.6 ms，最大 111.7 ms。手机省电也可能影响 ICMP 延迟，不能单凭该结果认定无线故障。
- 从 USB 混合代理经过同一节点访问出口查询 5 次均成功，耗时 0.56～1.08 秒。
- SOCKS5 UDP ASSOCIATE 转发到 `1.1.1.1:53` 的 DNS 请求 3 次成功，耗时约 50～246 ms。这只验证 UDP 小包，不能证明 QUIC 持续传输正常。
- 经代理下载 Cloudflare 1,000,000 字节用时 1.21 秒（约 0.83 MB/s），Google 搜索返回 HTTP 200；指定手机访问的 Google IP `172.217.112.4` 也成功。
- 历史日志存在 TCP/UDP 建连约 15～20 秒超时；当前 TCP 统计有少量重传。尚不能定位为节点、无线或 QUIC 的单一故障。

为做对照，**仅在运行时**给该手机添加下列规则，快速拒绝被 TPROXY 接管的 UDP/443，观察浏览器回退 TCP 后是否改善。未写入开机规则，不代表已经确认修复：

```bash
sudo iptables-legacy -I INPUT 1 -i wlan0 -s 192.168.3.130 -p udp --dport 443 -m mark --mark 0x71/0xff -m comment --comment sp970-quic-diagnostic -j REJECT --reject-with icmp-port-unreachable
```

查看命中情况：`sudo iptables-legacy -nvL INPUT --line-numbers`。不要重复添加；若没有命中，则不能用本次对照判定 QUIC。完成对照后删除临时规则：

```bash
sudo iptables-legacy -D INPUT -i wlan0 -s 192.168.3.130 -p udp --dport 443 -m mark --mark 0x71/0xff -m comment --comment sp970-quic-diagnostic -j REJECT --reject-with icmp-port-unreachable
```

是否保留正式调整，需要结合手机重新打开浏览器后的结果与规则计数。

后续结果：UDP/443 临时规则命中 10 个包，但用户反馈仍无法访问，已删除该规则，未持久化。DNS 曾有 3.7～7.1 秒慢查询；从电脑向旁路由发起一次 Wi-Fi DNS 查询也超时，但随后 Wi-Fi/USB 共 10 个并发 A 查询全部成功（约 5～229 ms），因此不能将所有网页超时归因于 DNS。

进一步在 wlan0 仅抓取报文头：25 秒样本共 198 个与手机有关的 IPv4 包，其中 155 个 TCP 包的以太网目标地址为 `ff:ff:ff:ff:ff:ff`，Linux 标记 PACKET_BROADCAST，大量为重复 SYN；仅 4 个 TCP 包为正常单播（已有连接的关闭/确认）。与此同时，DNS 请求为发往设备真实 MAC 的单播，DNS 应答也正常发往手机 MAC。说明失败请求存在二层转发异常，下一步核查手机网关、前缀长度、ARP 与 AP/中继转发；尚不能区分是手机配置/缓存还是 AP 行为。诊断程序 `sniff-phone.go` / `sniff-arp.go` 仅输出地址与报文头，不输出应用载荷。

随后将设备 Wi-Fi 配置 `uplink-8-102` 的 BSSID 改为 `90:76:9F:46:21:DD` 并重新连接；用户同时完成手机 Wi-Fi 重连。新的 25 秒抓包中 TCP 单播 527 个、TCP 广播 0 个，已观察到正常双向数据。重启 sing-box 清理切换前的旧上游连接，两项服务均 active。**切 AP 与手机重连时间相近，因此不能严格区分两者各自贡献；当前证据定位到原路径的二层转发/邻居解析异常，尚不证明某款 AP 固件存在确定缺陷。** 原 DNS 配置保留，QUIC 临时阻断已撤销。等待手机连续搜索确认体感恢复。

第二个独立 25 秒验证样本：TCP 单播 1339 个、广播 0 个；检查最近一分钟 sing-box 日志未见 ERROR。此为短时验证，不能替代用户实际搜索结果或长期稳定性验证。
