# cezanne 内核编译仓库（EROFS + HyperOS 4 开荒）

用于给 **Redmi K30 Ultra（cezanne / MT6889）** 编译带 **EROFS 支持**的 4.14.186 内核，
目标是把**澎湃 OS4（warhol OS4.0.3.0）的 system / product / system_ext** 挂起来。

编译在 **GitHub Actions** 云端完成，本地不需要 WSL、不需要 Linux、不需要改任何安全设置。

---

## 一、为什么是这个方案

| 设计点 | 原因 |
|---|---|
| 用官方 `MiCode/Xiaomi_Kernel_OpenSource @ cezanne-r-oss` | 4.14.186，和原厂内核同源同版本 |
| `LOCALVERSION` 固定为 `-perf-00252-g2f26b5917fd6` | 编译出的 `uname -r` 与原厂**完全一致**，vendor 里 10 个 `.ko`（WiFi/BT/GPS/热管理…）不用重编就能加载 |
| 叠加原厂 `cezanne_user_defconfig` | 保住 `CONFIG_MODVERSIONS=y` 下所有符号 CRC，不然模块会报 "disagrees about version of symbol" |
| 从同为 4.14.186 的 MTK 内核移植 `fs/erofs` | 主线 4.19 才有 EROFS，cezanne 源码树里没有；OS4 系统分区全是 erofs，没驱动直接卡开机 |
| EROFS 只开驱动、压缩保持默认 | 实测 OS4 全部 erofs 分区 `feature_incompat = 0x00`（未压缩），而原厂本来就有 `LZ4_DECOMPRESS=y`，所以 ZIP 开不开都不增加依赖，改动面最小 |

---

## 二、怎么用（三步）

### 第 1 步：建仓库

在 GitHub 新建一个 **Public** 空仓库（**不要**勾选 "Add a README file"），名字随意，比如 `cezanne-kernel`。

### 第 2 步：把本目录推上去

本目录**已经初始化成 git 仓库并暂存好全部文件**（含 `.gitattributes`，保证脚本是 LF 换行）。
在本机打开 Git Bash，复制这 6 行，把用户名/邮箱/仓库地址换成你自己的：

```bash
cd "E:/数码爱好/30U/_work/kernel-build"
git config user.name  "你的GitHub用户名"
git config user.email "你的GitHub邮箱"
git commit -m "init: cezanne kernel build with EROFS"
git remote add origin https://github.com/<你的用户名>/cezanne-kernel.git
git push -u origin main
```

> 第一次 push 会弹浏览器让你登录 GitHub 授权，点同意即可。
>
> 如果坚持用网页上传：注意 `.github` 和 `.gitattributes` 是隐藏项，
> 拖文件夹时容易被漏掉。漏了 `.github` 就没有 workflow，Actions 页面会是空的。

### 第 3 步：跑编译

打开仓库 → **Actions** 标签 → 左侧 `Build cezanne kernel (EROFS for HyperOS 4)` → 右侧 **Run workflow**：

| 参数 | 第一次建议值 | 说明 |
|---|---|---|
| `enable_erofs` | ✅ 勾选 | 关掉就没意义了 |
| `enable_ksu` | ⬜ 不勾 | 第一次先验证能不能开机，变量越少越好 |
| `localversion` | 保持默认 | 改了就加载不了原厂模块 |

大约 **25~40 分钟**。跑完在 Actions 运行页底部 **Artifacts** 下载 `cezanne-kernel-erofs`。

---

## 三、产物说明

下载的 zip 解开后有：

| 文件 | 用途 |
|---|---|
| `*-dtb-anykernel3.zip` | **卡刷包**（含 Image.gz-dtb），TWRP/OrangeFox 里直接刷 |
| `*-gz-anykernel3.zip` | 卡刷包（含 Image.gz），上面那个刷不进去时用这个 |
| `Image.gz` / `Image.gz-dtb` | 裸内核镜像，想自己组 boot.img 用 |
| `config.txt` | 最终生效的完整 config，**要留档**，以后排查问题全靠它 |
| `kernel-release.txt` | 内核版本串，必须等于 `4.14.186-perf-00252-g2f26b5917fd6` |
| `BUILD-INFO.txt` | 编译信息摘要 |
| `System.map` | 符号表，崩溃分析用 |

### 拿到包先做两项自检

1. `kernel-release.txt` 的内容是不是 **`4.14.186-perf-00252-g2f26b5917fd6`**
   → 不是的话，原厂模块全部加载失败，不用往下走了
2. `config.txt` 里有没有 `CONFIG_EROFS_FS=y` 和 `CONFIG_EROFS_FS_XATTR=y`
   → BUILD-INFO.txt 里也有一行 `EROFS 生效: 1`

---

## 四、刷入验证顺序（不要一把刷完整包）

1. **TWRP/OrangeFox 先全盘备份** `boot`、`super`、`dtbo`、`vendor`（有备份随时 2 分钟回滚）
2. **只刷内核**（本仓库的 anykernel3.zip），系统仍用现在的 MIUI14
   - 能开机 → 内核本身没问题 ✅
   - 起不来 → 内核有依赖没满足，回到恢复模式刷回 boot 备份，把 `config.txt` 和卡住的日志发我
3. 内核过了之后，再单独换 `super`（只换 system 层，vendor 保持原厂）
4. 每一步失败都只回滚这一步，不要全盘重来

---

## 五、目录结构

```
kernel-build/
├── .github/workflows/build.yml   # Actions 流水线
├── scripts/
│   ├── build.sh                  # 主构建脚本（配 config + 编译 + 打包）
│   └── fetch_erofs.sh            # 移植 fs/erofs 到内核树
├── configs/
│   ├── erofs.fragment            # EROFS 配置片段
│   └── ksu.fragment              # KernelSU 配置片段（可选）
├── anykernel/anykernel.sh        # AnyKernel3 打包脚本
└── README.md
```

---

## 六、常见问题

**Q：为什么不用本地 WSL 编译？**
A：本机 WSL 被执行策略拦截，且 4.14 全量编译在 4 核笔记本上要 1~2 小时、机器全程卡死。Actions 是 8 核、免费、日志清晰。

**Q：编译失败怎么办？**
A：看失败那一步的日志。`fetch_erofs.sh` 失败多半是网络，重跑即可；`build.sh` 的配置校验失败会明确打印哪一项没生效（通常是依赖链被裁），把那一行发我。

**Q：以后想加 KernelSU？**
A：同样流程，把 `enable_ksu` 勾上重跑即可，会额外产出 `-ksu` 后缀的包。

**Q：升级到更新的 4.14 LTS（如 .336/.357）？**
A：那需要把 ACK 的 4.14-stable 合进 cezanne 树，会改动大量符号 CRC，必须同时重编所有 vendor 模块。开荒阶段不做，等能开机稳定了再说。
