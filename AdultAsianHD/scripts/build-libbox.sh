#!/bin/sh
# 编 sing-box libbox 出 Libbox.xcframework（iOS 真机 + 模拟器）
#
# 用途：小视频内置代理的核。CI 里跑（GitHub Actions xcode-27 runner），
# 本机没有 macOS/Xcode 编不了。Stage 0 试编脚本——先编过，再写 Swift 代码。
#
# 钉死的版本（不要随便改）：
#   sing-box v1.14.6（2026-11-28 发布的最新稳定版；默认分支是 testing，
#     clone 必须用 --branch v1.14.6）
#   SagerNet gomobile fork v0.1.13（gomobile + gobind 两个工具都要装）
#   Go 1.27.4（workflow 里 actions/setup-go 钉死；sing-box 1.14.6 要求 Go >= 1.26）
#
# tags 说明（对着 v1.14.6 的 cmd/internal/build_libbox/main.go 核过）：
#   上游 Apple 默认集是 with_gvisor,with_quic,with_wireguard,with_utls,
#   with_naive_outbound,with_clash_api,with_usbip,with_openvpn,with_openconnect,
#   with_dhcp,with_tailscale(+ts_omit_*),grpcnotrace,with_low_memory
#   （-tags-not-macos），badlinkname,tfogo_checklinkname0。
#   我们裁掉：with_naive_outbound（iOS 上 Cronet 链接冲突）、with_clash_api
#   （v1 不用 clash API 的 gRPC 端口；libbox 的 command_server.go 不 import
#   clashapi，缺这个 tag 也能编）、with_usbip / with_openvpn / with_openconnect /
#   with_dhcp（v1 不用）、with_tailscale + ts_omit_*（v1 不用）。
#   with_ech 不要加：sing-box 1.12.0 起改用 stdlib ECH 实现，这个 tag
#   已经删了（加了也只会被 go build 静默忽略）。
#   最终 tags：with_gvisor,with_quic,with_wireguard,with_utls,
#   with_low_memory,grpcnotrace,badlinkname,tfogo_checklinkname0
#
# ldflags 说明：
#   -X constant.Version 写核版本；-X internal/godebug.defaultGODEBUG=multipathtcp=0
#   关默认 MPTCP；-s -w 去符号；-buildid= 去构建 ID；-checklinkname=0
#   放行 Go 1.23+ 的 linkname 检查（跟 tags 里的 tfogo_checklinkname0 配对）。
#   （跟上游 build_shared.LinkerFlags / Tuno 的出货脚本同一套。）
#
# 输出：$GITHUB_WORKSPACE/AdultAsianHD/Libbox.xcframework
#   （ios-arm64 + ios-arm64_x86_64-simulator 两个 slice；不进 Git，
#   .gitignore 里有 AdultAsianHD/Libbox.xcframework/，CI 用 actions/cache 缓存。）
set -eu

SING_BOX_VERSION="${SING_BOX_VERSION:-1.14.6}"
GOMOBILE_VERSION="${GOMOBILE_VERSION:-v0.1.13}"
TAGS="${TAGS:-with_gvisor,with_quic,with_wireguard,with_utls,with_low_memory,grpcnotrace,badlinkname,tfogo_checklinkname0}"
# 探针（2026-11-28 试验构建 #83 的教训）：runner（macOS /bin/sh）上裸赋值
# SING_BOX_VERSION="1.14.6" 后，第 54 行在 set -u 下仍报未定义；但文件 SHA 与本地逐字节一致、
# 本地 dash/bash/bash --posix 都能过。上面已改成默认值写法绕过，这里留一个裸赋值当金丝雀，
# 看 runner 的 sh 是不是丢裸赋值（若印 <丢了>，即为 runner 侧 shell 问题；若印 canary-ok，
# 则 #83 的失败另有原因，可能是那次 checkout 异常）。
CANARY_PROBE="canary-ok"
echo "探针：裸赋值金丝雀=${CANARY_PROBE:-<丢了>} sing-box=$SING_BOX_VERSION gomobile=$GOMOBILE_VERSION"

WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
OUT="$WORKSPACE/AdultAsianHD/Libbox.xcframework"

echo "--- Go ---"
go version

echo "--- 装 gomobile（SagerNet fork，gomobile + gobind 都要） ---"
go install "github.com/sagernet/gomobile/cmd/gomobile@$GOMOBILE_VERSION"
go install "github.com/sagernet/gomobile/cmd/gobind@$GOMOBILE_VERSION"
export PATH="$PATH:$(go env GOPATH)/bin"
gomobile version || true

echo "--- clone sing-box v$SING_BOX_VERSION（浅 clone，只要这个 tag） ---"
rm -rf /tmp/sing-box-build
git clone --depth 1 --branch "v$SING_BOX_VERSION" \
  https://github.com/SagerNet/sing-box /tmp/sing-box-build
cd /tmp/sing-box-build
git rev-parse HEAD

echo "--- gomobile bind（只编 iOS 真机 + 模拟器） ---"
echo "tags: $TAGS"
gomobile bind -v \
  -target ios,iossimulator \
  -libname=box \
  -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=$SING_BOX_VERSION \
            -X internal/godebug.defaultGODEBUG=multipathtcp=0 \
            -s -w -buildid= -checklinkname=0" \
  -tags "$TAGS" \
  -o "$OUT" \
  ./experimental/libbox

echo "--- Libbox.xcframework 自检 ---"
if [ ! -d "$OUT" ]; then
  echo "❌ 没产出 Libbox.xcframework：$OUT"
  exit 1
fi
find "$OUT" | sort
for SLICE in ios-arm64 ios-arm64_x86_64-simulator; do
  if [ ! -d "$OUT/$SLICE" ]; then
    echo "❌ 缺 slice：$SLICE"
    exit 1
  fi
  BIN="$(find "$OUT/$SLICE" -type f -name "Libbox" | head -n 1)"
  if [ -z "$BIN" ]; then
    echo "❌ $SLICE 里没找到 Libbox 二进制"
    exit 1
  fi
  echo "--- $SLICE：$BIN ---"
  lipo -info "$BIN"
done
echo "--- 体积 ---"
du -sh "$OUT"
SIZE_MB="$(du -sm "$OUT" | cut -f1)"
if [ "$SIZE_MB" -gt 60 ]; then
  echo "⚠️ XCFramework 超过 60MB（当前 ${SIZE_MB}MB），看一眼是不是 tags 带多了（不失败，只提醒）。"
fi
echo "OK：Libbox.xcframework 已编出。"
