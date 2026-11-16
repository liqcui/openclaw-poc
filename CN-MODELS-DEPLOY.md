# OpenClaw Docker 部署与国产模型配置

本仓库是本机部署与国产模型配置的唯一来源（原 `/opt/openclaw` 仓库保持不动）：

| 文件 | 作用 |
| --- | --- |
| `deploy.sh` | 一键部署脚本：生成 `.env`/token、写入配置、修正权限、启动并等待健康 |
| `docker-compose.yml` | 实际运行的 compose 文件：Port 只绑 `127.0.0.1`，CLI 与 Gateway 共享网络/PID |
| `.env` / `.env.example` | 部署变量（镜像、Gateway token、端口、挂载目录）；`.env` 为本地文件 |
| `.env.models` / `.env.models.example` | 国产模型 API Key 占位符；`.env.models` 为本地文件 |
| `config/openclaw.json.example` | 运行时配置样例（模型 provider、默认模型、Gateway 设置） |
| `$HOME/.openclaw/openclaw.json` | 实际运行的 Gateway 配置（路径可用 `.env` 的 `OPENCLAW_CONFIG_DIR` 覆盖） |
| `$HOME/.openclaw/workspace` | Agent 工作区 |

## 0. 一键部署

```bash
cd /opt/openclaw-poc
./deploy.sh
# 或直接带 Key：
DEEPSEEK_API_KEY=sk-xxx ./deploy.sh
```

脚本幂等，可重复执行：

- 检查 Docker 与 Compose v2
- 缺失时创建 `.env` 并生成 `OPENCLAW_GATEWAY_TOKEN`
- 缺失时创建 `.env.models` 占位符；命令行传入的 `*_API_KEY` 会写入该文件
- 首次运行写入 `config/openclaw.json.example` 到运行时配置目录（`--force-config` 可覆盖）
- 修正配置目录属主（容器内 uid 1000）
- `docker compose up -d`，`.env.models` 内容变化时自动 `--force-recreate`
- 等待 Gateway 就绪（直接探测 `/healthz`；Docker 健康检查间隔已从镜像默认的 180s 收紧到 15s）并打印访问方式

选项：`--prepare-only`（只准备不启动）、`--force-recreate`、`--force-config`；健康检查超时可用 `OPENCLAW_DEPLOY_HEALTH_TIMEOUT=<秒>` 调整（默认 240）。

## 1. 启停与检查

```bash
cd /opt/openclaw-poc

# 启动（首次或修改 compose/.env.models 后）
docker compose -f docker-compose.yml up -d

# 状态 / 健康（首次启动会先跑 doctor 和插件安装，health 显示 starting 属正常，通常 30–60 秒）
docker compose -f docker-compose.yml ps

# 日志
docker compose -f docker-compose.yml logs -f openclaw-gateway

# 重启 Gateway（修改 openclaw.json 后）
docker compose -f docker-compose.yml restart openclaw-gateway

# 停止（保留数据）
docker compose -f docker-compose.yml down
```

Gateway 只监听宿主机 `127.0.0.1:18789`。远程访问用 SSH 隧道：

```bash
ssh -L 18789:127.0.0.1:18789 <user>@<host>
# 然后浏览器打开 http://127.0.0.1:18789/
```

Dashboard 登录 token 在 `.env` 的 `OPENCLAW_GATEWAY_TOKEN`（容器内通过环境变量读取）。

## 2. 关键配置结构

`${HOME}/.openclaw/openclaw.json` 中与模型相关的部分：

```json
{
  "models": {
    "mode": "merge",
    "providers": {
      "deepseek": {
        "baseUrl": "${DEEPSEEK_BASE_URL:-https://api.deepseek.com}",
        "api": "openai-completions",
        "apiKey": "${DEEPSEEK_API_KEY:-}",
        "models": [
          { "id": "deepseek-v4-flash", "name": "DeepSeek V4.1 Flash", "reasoning": true },
          { "id": "deepseek-v4-pro",   "name": "DeepSeek V4 Pro",     "reasoning": true }
        ]
      }
    }
  },
  "agents": {
    "defaults": { "model": { "primary": "deepseek/deepseek-v4-flash" } }
  }
}
```

要点：

- 模型引用格式为 `provider/model-id`，例如 `deepseek/deepseek-v4-flash`。
- `models.mode: "merge"` 表示在镜像自带目录之上合并自定义 provider。
- `apiKey: "${VAR:-}"` 从**容器环境变量**取值；`:-` 让占位符为空时配置仍能通过校验。
- `baseUrl` 同样支持 `${VAR:-默认地址}`，地址和 Token 都能通过 `.env.models` 配置。
- 自定义 provider 必须写 `baseUrl` 和 `models` 数组，否则配置校验失败。
- 所有 provider 走 OpenAI 兼容协议（`api: "openai-completions"`）。

地址与 Key 的注入链路：

```
.env.models  ──env_file──▶  容器环境变量  ──${VAR}──▶  openclaw.json 的 baseUrl / apiKey
```

`.env.models` 已预置占位符（地址与 Key 均可留空）：

```dotenv
# 地址留空 = 用 openclaw.json 里的默认地址；Key 留空 = 未认证
DEEPSEEK_BASE_URL=
DEEPSEEK_API_KEY=
QWEN_BASE_URL=
QWEN_API_KEY=
ZAI_BASE_URL=
ZAI_API_KEY=
MOONSHOT_BASE_URL=
MOONSHOT_API_KEY=
VOLCANO_ENGINE_BASE_URL=
VOLCANO_ENGINE_API_KEY=
TOKENHUB_BASE_URL=
TOKENHUB_API_KEY=
STEPFUN_BASE_URL=
STEPFUN_API_KEY=
MINIMAX_API_KEY=
```

需要从零重建运行时配置时，可把仓库里的 `config/openclaw.json.example` 复制为 `${HOME}/.openclaw/openclaw.json`（会覆盖 Gateway 自动维护的字段，先备份）。

## 3. 已配置的国产模型

| Provider id | 地址变量（留空用默认） | Token 变量 | 已登记模型（`provider/model`） |
| --- | --- | --- | --- |
| `deepseek` | `DEEPSEEK_BASE_URL`（默认 `https://api.deepseek.com`） | `DEEPSEEK_API_KEY` | `deepseek/deepseek-v4-flash`、`deepseek/deepseek-v4-pro` |
| `qwen` | `QWEN_BASE_URL`（默认 DashScope 国内 Standard） | `QWEN_API_KEY` | `qwen/qwen3.8-max`、`qwen/qwen3.8-flash`、`qwen/qwen3.5-plus` |
| `zai` | `ZAI_BASE_URL`（默认 `https://open.bigmodel.cn/api/paas/v4`） | `ZAI_API_KEY` | `zai/glm-5.3`、`zai/glm-5.3-flash`、`zai/glm-5.2` |
| `moonshot` | `MOONSHOT_BASE_URL`（默认 `https://api.moonshot.cn/v1`） | `MOONSHOT_API_KEY` | `moonshot/kimi-k3`、`moonshot/kimi-k2.7-code` |
| `volcengine` | `VOLCANO_ENGINE_BASE_URL`（默认火山方舟北京） | `VOLCANO_ENGINE_API_KEY` | `volcengine/doubao-seed-2-1-pro-260628`、`volcengine/doubao-seed-2-1-turbo-260628`、`volcengine/deepseek-v4-flash-260425` |
| `tencent-tokenhub` | `TOKENHUB_BASE_URL`（默认腾讯 TokenHub） | `TOKENHUB_API_KEY` | `tencent-tokenhub/hy4`、`tencent-tokenhub/hy3` |
| `stepfun` | `STEPFUN_BASE_URL`（默认 `https://api.stepfun.ai/v1`） | `STEPFUN_API_KEY` | `stepfun/step-3.7-flash`、`stepfun/step-3.5-flash` |

镜像另外自带 MiniMax provider（`minimax/MiniMax-M3`），设置 `MINIMAX_API_KEY` 后可直接使用，无需自定义 provider。Alibaba/DashScope 插件只注册媒体能力（图像/视频生成），文本模型请用 `qwen`。

> 以上模型 ID 与端点来自本版本（2026.11.4）镜像内置的 provider 目录。供应商改版后以 `openclaw models list` 和供应商文档为准。

## 4. 填入地址 / 密钥并生效

```bash
cd /opt/openclaw-poc
vi .env.models          # 例如 DEEPSEEK_API_KEY=sk-xxxx；如需换地址再填 DEEPSEEK_BASE_URL=...

# 重新部署：脚本检测到 .env.models 变化后自动重建容器
./deploy.sh

# 等价的手工方式
# docker compose -f docker-compose.yml up -d --force-recreate

# 确认 key 已进入容器（不打印值）
docker compose -f docker-compose.yml exec -T openclaw-gateway sh -c 'env | grep API_KEY | cut -d= -f1'

# 确认模型已注册（在 Gateway 容器内执行，避免共享状态锁冲突）
docker compose -f docker-compose.yml exec -T openclaw-gateway \
  node dist/index.js models list --all --provider deepseek
```

> 配置里出现 `models.providers.<id>` 时，Doctor 在启动阶段会自动安装匹配的官方插件包（如 `@openclaw/deepseek-provider`），安装结果保存在挂载的配置目录（默认 `$HOME/.openclaw`）下。离线环境需要预先装好或删除这些 provider 条目。

## 5. 切换默认模型

改 `openclaw.json` 的 `agents.defaults.model.primary`，然后 `restart openclaw-gateway`；或在容器里用 CLI 写入：

```bash
docker compose -f docker-compose.yml exec -T openclaw-gateway \
  node dist/index.js models set qwen/qwen3.8-max
docker compose -f docker-compose.yml restart openclaw-gateway
```

建议把工具能力强的模型设为默认；`deepseek-v4-flash` 便宜，`deepseek-v4-pro` / `qwen3.8-max` / `glm-5.3` 更适合复杂任务。

## 6. 指定模型 API 地址与 token

分工是固定的：

- **地址、模型 ID、协议**写在 `openclaw.json` 的 `models.providers` 里
- **地址和 token 的值**放在 `.env.models`，配置里用 `${变量名:-默认值}` 引用
- `.env.models` 里新增的任何变量都会被 `env_file` 自动注入容器，**不需要改 compose**

### 6.1 只换某个内置 provider 的地址

内置 provider 的地址已经环境变量化，直接改 `.env.models` 即可，无需编辑 JSON：

```dotenv
DEEPSEEK_BASE_URL=https://your-gateway.example.com/v1
DEEPSEEK_API_KEY=sk-xxxx
```

然后执行 `./deploy.sh`（或 `docker compose up -d --force-recreate`）。

只有需要改协议、模型列表等内容时才动 `openclaw.json`：

```bash
vi "${HOME}/.openclaw/openclaw.json"     # 本机为 /root/.openclaw/openclaw.json
```

```json
"deepseek": {
  "baseUrl": "${DEEPSEEK_BASE_URL:-https://api.deepseek.com}",
  "api": "openai-completions",
  "apiKey": "${DEEPSEEK_API_KEY:-}",
  "models": [ ... ]
}
```

地址仍由 `.env.models` 的 `DEEPSEEK_BASE_URL` 提供（留空回退到默认值）。编辑配置后重启生效：

```bash
docker compose restart openclaw-gateway
```

### 6.2 新增一个任意 OpenAI 兼容端点（只有地址 + token）

在 `models.providers` 里加一个新 provider（`baseUrl` 和 `models` 是必填）：

```json
"my-api": {
  "baseUrl": "https://your-api.example.com/v1",
  "api": "openai-completions",
  "apiKey": "${MY_API_TOKEN:-}",
  "models": [
    {
      "id": "your-model-id",
      "name": "Your Model",
      "reasoning": false,
      "input": ["text"],
      "contextWindow": 128000,
      "maxTokens": 8192
    }
  ]
}
```

`.env.models` 增加一行（变量名与 `apiKey` 引用一致即可）：

```dotenv
MY_API_TOKEN=sk-xxxx
```

设为默认模型：`agents.defaults.model.primary` 改成 `"my-api/your-model-id"`，然后重启 Gateway。

### 6.3 推荐：地址也走环境变量（换环境只改 `.env.models`）

`baseUrl` 同样支持 `${VAR:-默认值}`，这样同一个配置文件可以在不同环境复用：

```json
"my-api": {
  "baseUrl": "${MY_API_BASE_URL:-https://your-api.example.com/v1}",
  "api": "openai-completions",
  "apiKey": "${MY_API_TOKEN:-}",
  "models": [{ "id": "your-model-id", "name": "Your Model" }]
}
```

```dotenv
# .env.models
MY_API_BASE_URL=https://your-api.example.com/v1
MY_API_TOKEN=sk-xxxx
```

修改后执行 `./deploy.sh`（或 `docker compose up -d --force-recreate`）重建容器。

### 6.4 验证

```bash
# 配置合法且模型已注册（Auth 列出现 yes 表示 key 已注入）
docker compose exec -T openclaw-gateway node dist/index.js models list --all --provider my-api

# 如果配置写错，日志会提示并以 last-known-good 启动
docker compose logs --tail=50 openclaw-gateway | grep -E 'Rejected|auto-restored'
```

补充：

- 想让新环境也复用这份 provider 配置，把相同内容写进仓库的 `config/openclaw.json.example`；`deploy.sh` 在运行时配置缺失（或 `--force-config`）时才会写入样例
- token 直接写成字面量也可以（`"apiKey": "sk-xxx"`），但会进配置文件和备份，不推荐
- 端点需要自定义请求头时用 provider 的 `headers`；完全无鉴权时用 `"auth": "none"`
- 容器内访问宿主机服务用 `host.docker.internal`（compose 已配置 `extra_hosts: host-gateway`），例如 `http://host.docker.internal:1234/v1`（LM Studio）、`http://host.docker.internal:3000/v1`（one-api/new-api）

### 6.5 内置 provider 的默认端点

下表中的默认地址都可以用对应环境变量覆盖（见第 3 节表格），例如 `QWEN_BASE_URL`、`ZAI_BASE_URL`。

| 场景 | provider | baseUrl |
| --- | --- | --- |
| DeepSeek 官方 | `deepseek` | `https://api.deepseek.com` |
| 通义千问 Coding Plan（国际） | `qwen` | `https://coding-intl.dashscope.aliyuncs.com/v1` |
| 通义千问 Coding Plan（国内） | `qwen` | `https://coding.dashscope.aliyuncs.com/v1` |
| 智谱 Coding Plan（国内） | `zai` | `https://open.bigmodel.cn/api/coding/paas/v4` |
| Kimi 国际 | `moonshot` | `https://api.moonshot.ai/v1` |
| 火山方舟 Coding Plan | `volcengine` | `https://ark.cn-beijing.volces.com/api/coding/v3`（模型 id 去掉日期后缀，如 `ark-code-latest`） |

## 7. 关于官方 provider 插件

当前版本（2026.11.4）在启动时会为配置中声明的 provider 自动安装官方插件（观察到的日志：`Installed missing configured plugin "deepseek" from @openclaw/deepseek-provider@2026.11.4`）。插件提供完整模型目录、成本统计和供应商特性适配；配置文件里的显式 `models.providers.<id>` 仍优先生效（用于固定国内端点和模型集合）。

如需手动安装或补齐：

```bash
docker compose -f docker-compose.yml exec -T openclaw-gateway \
  node dist/index.js plugins install @openclaw/qwen-provider
docker compose -f docker-compose.yml restart openclaw-gateway
```

插件包名：`@openclaw/deepseek-provider`、`@openclaw/qwen-provider`、`@openclaw/zai-provider`、`@openclaw/moonshot-provider`、`@openclaw/volcengine-provider`、`@openclaw/tencent-provider`、`@openclaw/stepfun-provider`。若只想使用插件目录，删除配置里对应的 `models.providers` 条目即可按插件默认端点工作。

## 8. 排错

| 现象 | 原因与处理 |
| --- | --- |
| 回复报 401/认证失败 | `.env.models` 里对应 key 为空或错误；改完必须重建容器（`up -d --force-recreate`） |
| 日志出现 `Config auto-restored from last-known-good` | 配置校验失败。原文件已备份为 `openclaw.json.clobbered.<时间戳>`；按日志指出的字段修正后复制回 `openclaw.json` 并重启 |
| `models list` 看不到自定义模型 | 确认 `models.mode: "merge"`、provider 有 `baseUrl` 和 `models`，且 JSON 合法 |
| 端口能连但提示无权限 | 从 `.env` 取 `OPENCLAW_GATEWAY_TOKEN`，作为 Bearer token / Dashboard 登录使用 |
| CLI 连不上 Gateway / 提示共享状态锁 | 用 `docker compose exec -T openclaw-gateway node dist/index.js <命令>`，或 `docker compose run --rm openclaw-cli <命令>`（已共享网络与 PID 命名空间）；不要单独 `docker run` CLI |
| 容器内 18789 已占用 | 检查是否有旧容器（`docker ps`）或用 `docker compose down` 清理本项目的容器 |
| `deploy.sh` 报健康检查超时 | 先看 `curl -i http://127.0.0.1:18789/healthz`：返回 200 说明 Gateway 已可用（脚本以它为准）；再看 `docker compose logs --tail=100 openclaw-gateway` 是否有配置校验/迁移报错。compose 已把健康检查间隔从镜像默认的 180s 收紧到 15s，Docker 状态不再滞后数分钟 |

## 9. 配置备份

Gateway 修改配置时会自动生成 `openclaw.json.bak*`、`openclaw.json.last-good`。手动备份：

```bash
cp -a ${HOME}/.openclaw/openclaw.json ${HOME}/.openclaw/openclaw.json.bak.$(date +%Y%m%d-%H%M%S)
```

`.env.models` 含明文密钥，权限保持 `600`，不要提交或粘贴到公开渠道。
