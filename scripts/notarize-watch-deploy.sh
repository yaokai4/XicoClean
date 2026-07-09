#!/bin/bash
# notarize-watch-deploy.sh
# 守候一个 notarytool 公证提交，一旦 Accepted：装订票据 → 校验 → 上传替换官网 DMG。
# 失败(Invalid/Rejected)则打印日志并退出，绝不上传。
#
# 用法：
#   scripts/notarize-watch-deploy.sh [SUBMISSION_ID]
#   不传 SUBMISSION_ID 时用下面的默认值（本次 0.2.7 提交）。
#
# 说明：版本未变(0.2.7)，官网只需把 DMG 换成"已公证+装订"版，无需改 appcast。
#       若将来是新版本发布，另需 bump src/app/appcast.xml/route.ts 并 git push（本脚本不做）。
set -uo pipefail

# ---------------- 配置 ----------------
SUBMISSION_ID="${1:-280caf0f-4370-4d5f-a89c-259084c428bc}"
PROFILE="${XICO_NOTARY_PROFILE:-XicoNotary}"
ROOT="/Users/yaokai/Desktop/IT/MacApp/XicoApp"
DMG="$ROOT/dist/Xico-Clean-0.2.7.dmg"

PEM="$HOME/Desktop/IT/web/Shangence.pem"
SERVER="ec2-user@52.198.247.142"
REMOTE_TMP="/tmp/Xico-Clean.dmg"
CONTAINER="xicoai-app"
CONTAINER_PATH="/app/uploads/Xico-Clean.dmg"

POLL_INTERVAL=120     # 轮询间隔（秒）
MAX_HOURS=24          # 最长守候时间
# -------------------------------------

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# 前置检查
[ -f "$DMG" ] || { log "✗ 找不到 DMG: $DMG"; exit 10; }
[ -f "$PEM" ] || { log "✗ 找不到部署密钥: $PEM"; exit 10; }

# ---------------- 1. 轮询直到出裁决 ----------------
log "开始守候公证提交 $SUBMISSION_ID（每 ${POLL_INTERVAL}s，最长 ${MAX_HOURS}h）"
deadline=$(( $(date +%s) + MAX_HOURS * 3600 ))
while :; do
  status="$(xcrun notarytool info "$SUBMISSION_ID" --keychain-profile "$PROFILE" 2>/dev/null \
            | awk -F': ' '/ status:/{print $2}')"
  log "status = ${status:-<查询失败,稍后重试>}"
  case "$status" in
    Accepted)
      break ;;
    Invalid|Rejected)
      log "✗ 公证失败（$status）——未上传官网。失败日志如下："
      xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" 2>&1
      exit 1 ;;
    *)
      : ;;  # In Progress 或临时查询失败 → 继续等
  esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "✗ 超过 ${MAX_HOURS}h 仍未出结果（当前: ${status:-未知}）。可稍后再次运行本脚本继续守候。"
    exit 2
  fi
  sleep "$POLL_INTERVAL"
done

log "✓ 公证通过 (Accepted)"

# ---------------- 2. 装订 + 校验 ----------------
log "装订票据：stapler staple"
xcrun stapler staple "$DMG"          || { log "✗ stapler staple 失败"; exit 3; }
xcrun stapler validate "$DMG"        || { log "✗ stapler validate 失败"; exit 3; }
log "Gatekeeper 终检（应显示 accepted / source=Notarized Developer ID）："
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | head -3 || true

# ---------------- 3. 上传替换官网 DMG ----------------
LOCAL_SIZE="$(stat -f '%z' "$DMG")"
log "上传到服务器 $SERVER（本地大小 ${LOCAL_SIZE} 字节）"
scp -i "$PEM" -o IdentitiesOnly=yes "$DMG" "$SERVER:$REMOTE_TMP" \
  || { log "✗ scp 上传失败"; exit 4; }

log "docker cp 进容器并修正属主"
ssh -i "$PEM" -o IdentitiesOnly=yes "$SERVER" \
  "sudo docker cp '$REMOTE_TMP' '$CONTAINER:$CONTAINER_PATH' && \
   sudo docker exec -u root '$CONTAINER' chown nextjs:nodejs '$CONTAINER_PATH' && \
   REMOTE_SIZE=\$(sudo docker exec '$CONTAINER' stat -c '%s' '$CONTAINER_PATH') && \
   echo \"remote_size=\$REMOTE_SIZE\" && \
   rm -f '$REMOTE_TMP'" \
  || { log "✗ 远程部署失败"; exit 4; }

log "✓ 完成：官网 DMG 已替换为「已公证+装订」版。"
log "  验证：从 mac.xicoai.com 下载后双击应无 Gatekeeper 警告；"
log "  或： curl -sI https://mac.xicoai.com/api/download/xico-clean | head -5"
