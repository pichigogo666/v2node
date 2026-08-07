# 自有 v2node 镜像仓库

这是 `pichigogo666` 账号下的独立 v2node 源码与部署仓库，不是 Fork。即使原作者仓库以后不可用，本仓库仍保留完整源码和提交历史。

## 自有资源

- 源码：本仓库 `main` 分支
- Docker 镜像：`ghcr.io/pichigogo666/v2node:latest`
- GeoIP/GeoSite：本仓库 `rules-latest` Release
- Docker 一键脚本：`deploy/v2node-docker.sh`
- 配套 V2Board：`pichigogo666/v2board`

## Docker 一键部署

```bash
curl -fL \
  https://raw.githubusercontent.com/pichigogo666/v2node/main/deploy/v2node-docker.sh \
  -o v2node-docker.sh

chmod +x v2node-docker.sh
sudo ./v2node-docker.sh install
```

脚本会询问 V2Board 节点 API 地址、v2node 节点 ID 和通信密钥，并自动部署 Docker Compose 服务。

### 同一服务器部署多个节点

每个节点指定一个不同的实例名称，并确保 V2Board 后台为它们配置了不同的服务端口：

```bash
sudo ./v2node-docker.sh install --instance jp01 --node-id 1
sudo ./v2node-docker.sh install --instance jp02 --node-id 2
```

脚本会分别创建：

```text
/opt/v2node-docker-jp01   容器 v2node-jp01
/opt/v2node-docker-jp02   容器 v2node-jp02
```

管理指定实例：

```bash
sudo ./v2node-docker.sh status --instance jp01
sudo ./v2node-docker.sh logs --instance jp02 -f
sudo ./v2node-docker.sh update --instance jp01
```

也可以直接运行各实例目录中的脚本，脚本会自动识别所属实例：

```bash
sudo bash /opt/v2node-docker-jp01/v2node-docker.sh status
```

不填写 `--instance` 时保持旧版兼容，继续使用 `/opt/v2node-docker` 和容器名 `v2node`。

## 更新镜像

仓库源码或 Dockerfile 更新后，GitHub Actions 会构建 `amd64` 与 `arm64` 镜像并发布到本账号的 GHCR。

## 规则文件

运行 `Vendor GeoIP and GeoSite files` 工作流，可以将规则文件保存到本仓库自己的 `rules-latest` Release。节点安装时只从本仓库下载，不再直接依赖规则项目。

## 上游声明

本仓库基于 v2node 开源代码保留副本，原许可证见仓库中的 `LICENSE`。

