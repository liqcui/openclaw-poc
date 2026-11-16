#!/usr/bin/env bash
# 一键部署 OpenClaw Gateway + 国产模型配置。
# 幂等：可重复执行；已存在的 .env / openclaw.json 不会被覆盖（除非 --force-config）。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

PREPARE_ONLY=0
FORCE_RECREATE=0
FORCE_CONFIG=0
HEALTH_TIMEOUT="${OPENCLAW_DEPLOY_HEALTH_TIMEOUT:-240}"
MODEL_KEYS=(
  DEEPSEEK_API_KEY
  QWEN_API_KEY
  ZAI_API_KEY
  MOONSHOT_API_KEY
  VOLCANO_ENGINE_API_KEY
  TOKENHUB_API_KEY
  STEPFUN_API_KEY
  MINIMAX_API_KEY
)
MODEL_URLS=(
  DEEPSEEK_BASE_URL
  QWEN_BASE_URL
  ZAI_BASE_URL
  MOONSHOT_BASE_URL
  VOLCANO_ENGINE_BASE_URL
  TOKENHUB_BASE_URL
  STEPFUN_BASE_URL
)

usage() {
  cat <<'EOF'
用法: ./deploy.sh [选项]

  --prepare-only    只准备配置/密钥文件，不启动容器
  --force-recreate  强制重建容器（修改了 .env.models 时通常可省略，脚本会自动检测）
  --force-config    用 config/openclaw.json.example 覆盖运行时配置
  -h, --help        显示帮助

环境变量:
  OPENCLAW_DEPLOY_HEALTH_TIMEOUT  等待健康的秒数，默认 240

也可以在命令前直接传入 Key（会写入 .env.models）:
  DEEPSEEK_API_KEY=sk-xxx ./deploy.sh
EOF
}

die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf '警告: %s\n' "$*" >&2
}

for arg in "$@"; do
  case "$arg" in
    --prepare-only) PREPARE_ONLY=1 ;;
    --force-recreate) FORCE_RECREATE=1 ;;
    --force-config) FORCE_CONFIG=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "未知选项: $arg"
      ;;
  esac
done

command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 Docker Engine"
docker compose version >/dev/null 2>&1 || die "缺少 Docker Compose v2 插件（docker compose），请先安装 docker-compose-plugin"

env_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

env_set() {
  local file="$1" key="$2" value="$3" escaped tmp
  escaped="$(printf '%s' "$value" | sed -e 's/[&|\\]/\\&/g')"
  tmp="${file}.tmp.$$"
  if grep -q "^${key}=" "$file"; then
    sed "s|^${key}=.*|${key}=${escaped}|" "$file" >"$tmp"
  else
    cp "$file" "$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$file"
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

gen_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

model_key_count() {
  local count=0 key
  for key in "${MODEL_KEYS[@]}"; do
    [ -n "$(env_get .env.models "$key")" ] && count=$((count + 1))
  done
  printf '%s' "$count"
}

# 1. 本地部署变量
if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  echo "==> 已创建 .env（来自 .env.example）"
fi

if [ -z "$(env_get .env OPENCLAW_GATEWAY_TOKEN)" ]; then
  env_set .env OPENCLAW_GATEWAY_TOKEN "$(gen_token)"
  echo "==> 已生成 OPENCLAW_GATEWAY_TOKEN（保存在 .env）"
fi

# 2. 模型 Key 占位符
if [ ! -f .env.models ]; then
  cp .env.models.example .env.models
  chmod 600 .env.models
  echo "==> 已创建 .env.models（占位符，填入 Key 后重新执行本脚本）"
fi

# 3. 从进程环境导入非空 Key / 地址（便于 CI / 批量部署）
for key in "${MODEL_KEYS[@]}" "${MODEL_URLS[@]}"; do
  value="${!key:-}"
  if [ -n "$value" ]; then
    env_set .env.models "$key" "$value"
    echo "==> 已写入 $key 到 .env.models"
  fi
done

# 4. 运行时配置目录
CONFIG_DIR="$(env_get .env OPENCLAW_CONFIG_DIR || true)"
[ -n "$CONFIG_DIR" ] || CONFIG_DIR="${HOME}/.openclaw"
WORKSPACE_DIR="$(env_get .env OPENCLAW_WORKSPACE_DIR || true)"
[ -n "$WORKSPACE_DIR" ] || WORKSPACE_DIR="$CONFIG_DIR/workspace"

mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR" || die "无法创建配置目录: $CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/openclaw.json" ] || [ "$FORCE_CONFIG" -eq 1 ]; then
  install -m 600 config/openclaw.json.example "$CONFIG_DIR/openclaw.json"
  echo "==> 已写入 $CONFIG_DIR/openclaw.json"
else
  echo "==> 保留现有 $CONFIG_DIR/openclaw.json"
fi

# 容器内进程以 node（uid 1000）运行，确保它可以读写配置目录
if [ "$(id -u)" -eq 0 ]; then
  chown 1000:1000 "$CONFIG_DIR" "$WORKSPACE_DIR" 2>/dev/null ||
    warn "无法 chown $CONFIG_DIR 到 1000:1000，容器可能因权限失败"
  chown 1000:1000 "$CONFIG_DIR/openclaw.json" 2>/dev/null || true
elif [ "$(id -u)" -ne 1000 ]; then
  warn "当前 uid 为 $(id -u)，容器内为 1000；如启动失败请执行: sudo chown -R 1000:1000 '$CONFIG_DIR'"
fi

if [ "$PREPARE_ONLY" -eq 1 ]; then
  echo "==> 仅准备配置，未启动容器"
  exit 0
fi

# 5. 启动容器（.env.models 内容变化时自动重建）
cur_hash="$(hash_file .env.models)"
prev_hash="$(cat .env.models.sha256 2>/dev/null || true)"
if [ -n "$prev_hash" ] && [ "$prev_hash" != "$cur_hash" ]; then
  FORCE_RECREATE=1
  echo "==> .env.models 已变化，重建容器"
fi

up_args=()
[ "$FORCE_RECREATE" -eq 1 ] && up_args+=(--force-recreate)
docker compose up -d "${up_args[@]}"
printf '%s\n' "$cur_hash" >.env.models.sha256

# 6. 等待健康
# 直接探测已发布端口的 /healthz，避免 Docker 健康检查间隔造成的状态滞后。
port="$(env_get .env OPENCLAW_GATEWAY_PORT || true)"
[ -n "$port" ] || port=18789

gateway_ready() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 3 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1 && return 0
  fi
  local container_id status
  container_id="$(docker compose ps -q openclaw-gateway 2>/dev/null | head -n 1)"
  [ -n "$container_id" ] || return 1
  status="$(docker inspect -f '{{.State.Health.Status}}' "$container_id" 2>/dev/null || true)"
  [ "$status" = "healthy" ]
}

echo "==> 等待 Gateway 健康检查（首次启动会先跑 doctor 和插件安装）"
deadline=$((SECONDS + HEALTH_TIMEOUT))
while ! gateway_ready; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    container_id="$(docker compose ps -q openclaw-gateway 2>/dev/null | head -n 1)"
    status=""
    [ -n "$container_id" ] && status="$(docker inspect -f '{{.State.Health.Status}}' "$container_id" 2>/dev/null || true)"
    warn "等待健康检查超时（${HEALTH_TIMEOUT}s，Docker 状态: ${status:-未知}，/healthz 未通过）"
    echo "排查: curl -i http://127.0.0.1:${port}/healthz" >&2
    echo "      docker compose logs --tail=100 openclaw-gateway" >&2
    exit 1
  fi
  sleep 3
done

# 7. 汇报
keys="$(model_key_count)"

echo ""
echo "==> 部署完成"
echo "    Gateway:    http://127.0.0.1:${port}/"
echo "    远程访问:   ssh -L ${port}:127.0.0.1:${port} <user>@<host>"
echo "    登录 token: grep OPENCLAW_GATEWAY_TOKEN .env"
echo "    模型验证:   docker compose exec -T openclaw-gateway node dist/index.js models list --all"
echo "    日志:       docker compose logs -f openclaw-gateway"

if [ "$keys" -eq 0 ]; then
  warn "尚未配置任何模型 Key；填写 .env.models 后重新执行 ./deploy.sh"
fi
