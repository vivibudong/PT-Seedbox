# Seedbox 一键安装脚本

> 原项目: [jerry048/Dedicated-Seedbox](https://github.com/jerry048/Dedicated-Seedbox)

快速部署 qBittorrent 4.3.9 + Vertex + FileBrowser 的一体化解决方案

## 支持系统

- Debian 10+
- Ubuntu 20.04+
- 架构：x86_64 / ARM64

## 功能特性

- ✅ qBittorrent 4.3.9 + libtorrent v1.2.20
- ✅ Vertex 面板（Docker）
- ✅ FileBrowser 文件管理（Docker）
- ✅ 系统优化（BBR、内核参数、磁盘调度）
- ✅ 随机端口分配

## 快速开始

### 基础安装（仅 qBittorrent）

```bash
bash <(wget -qO- https://raw.githubusercontent.com/vivibudong/PT-Seedbox/refs/heads/main/qb_fb_vertex_installer.sh) \
  -u 用户名 -p 密码 -c 2048
```

### 完整安装（qBittorrent + Vertex + FileBrowser）

```bash
bash <(wget -qO- https://raw.githubusercontent.com/vivibudong/PT-Seedbox/refs/heads/main/qb_fb_vertex_installer.sh) \
  -u 用户名 -p 密码 -c 2048 -v -f
```

### 自定义端口

```bash
bash <(wget -qO- https://raw.githubusercontent.com/vivibudong/PT-Seedbox/refs/heads/main/qb_fb_vertex_installer.sh) \
  -u 用户名 -p 密码 -c 2048 -v -f -o
```
*执行后会提示输入各服务端口*

### 恢复 Vertex 配置

```bash
bash <(wget -qO- https://raw.githubusercontent.com/vivibudong/PT-Seedbox/refs/heads/main/qb_fb_vertex_installer.sh) \
  -u 用户名 -p 密码 -c 2048 -v -f \
  -d "data.zip 直链" -k "解压密码(可选)"
```

## 参数说明

| 参数 | 说明 | 必需 |
|------|------|------|
| `-u` | 用户名 | ✅ |
| `-p` | 密码（≥12位） | ✅ |
| `-c` | qBit缓存（MB） 建议1/4内存大小 | ✅ |
| `-v` | 安装 Vertex 面板 | ❌ |
| `-f` | 安装 FileBrowser | ❌ |
| `-d` | Vertex data 目录 ZIP 直链 | ❌ |
| `-k` | data.zip 解压密码 | ❌ |
| `-o` | 自定义端口（交互式） | ❌ |
| `-h` | 显示帮助信息 | ❌ |

## 卸载

完整清理所有组件（包括配置、数据、依赖包）：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/vivibudong/PT-Seedbox/refs/heads/main/qb_fb_vertex_installer.sh) \
  --uninstall
```

*卸载时仅会询问：是否删除下载数据、是否删除用户*

## 安装后访问

安装完成后会显示各服务的访问地址：

```
🌐 Vertex
管理地址: http://YOUR_IP:PORT
用户名: your_username
密码: your_password

🧩 qBittorrent
管理地址: http://YOUR_IP:PORT

📁 FileBrowser
管理地址: http://YOUR_IP:PORT
```

## 注意事项

- 首次安装建议执行 `reboot` 重启系统以应用所有优化
- 如无法访问服务，请检查防火墙端口是否放通
- 密码最少 12 位字符
- Vertex 配置文件会保留原有设置（theme、menu 等）

## 系统优化

脚本会自动进行以下优化：

- 🔧 启用 TCP BBR 拥塞控制
- 🔧 调整内核网络参数（根据内存动态配置）
- 🔧 优化磁盘调度器（SSD/HDD 自适应）
- 🔧 提升文件描述符限制
- 🔧 配置网络缓冲区和队列长度

### License

his project is licensed under the [MIT License](LICENSE), allowing free use, modification, and distribution with proper attribution.

### Contact

For issues or suggestions, open an issue on GitHub or reach out via email: budongkejivivi@gmail.com

<div align="center"> <strong>Made with ❤️ by <a href="https://github.com/vivibudong">Vivi不懂</a></strong> </div>

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=vivibudong/PT-Seedbox&type=date&legend=top-left)](https://www.star-history.com/#vivibudong/PT-Seedbox&type=date&legend=top-left)




