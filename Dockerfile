# syntax=docker/dockerfile:1

# Build Go natively on the runner and cross-compile for the target platform.
# This avoids compiling the full Xray dependency tree through QEMU for arm64.
FROM --platform=$BUILDPLATFORM golang:1.26.1-alpine AS builder
ARG TARGETOS
ARG TARGETARCH
WORKDIR /app
COPY . .
ENV CGO_ENABLED=0
RUN GOEXPERIMENT=jsonv2 go mod download
RUN GOEXPERIMENT=jsonv2 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -v -o v2node

# Release
FROM  alpine
# 安装必要的工具包
RUN  apk --update --no-cache add tzdata ca-certificates \
    && cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
RUN mkdir /etc/v2node/
COPY --from=builder /app/v2node /usr/local/bin

ENTRYPOINT [ "v2node", "server", "--config", "/etc/v2node/config.json"]
