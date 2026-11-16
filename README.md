# openclaw-poc

本机 OpenClaw Docker 部署与国产模型接入的 POC 仓库。

- 只监听宿主机 `127.0.0.1:18789`，对外通过 SSH 隧道或反向代理访问
- 模型通过 `models.providers` 配置文件接入，API Key 用环境变量占位符注入
- 运行时配置/数据在 `$HOME/.openclaw`（默认；可用 `.env` 覆盖），通过 bind mount 挂入容器

完整说明见 [CN-MODELS-DEPLOY.md](./CN-MODELS-DEPLOY.md)。

## 一键部署

```bash
cd /opt/openclaw-poc
./deploy.sh
```

脚本会自动完成：

1. 检查 Docker 与 Compose v2 插件
2. 没有 `.env` 时从 `.env.example` 创建，并生成 `OPENCLAW_GATEWAY_TOKEN`
3. 没有 `.env.models` 时创建 Key 占位符
4. 自动创建配置目录、工作区、Skills 目录并打印 `已创建`/`已存在`
5. 首次运行时把 `config/openclaw.json.example` 写入运行时配置目录
6. 修正目录属主（容器内为 uid 1000）
7. `docker compose up -d`，探测 `/healthz` 直到就绪
8. 打印汇总：三个目录路径、Gateway 地址、**Gateway token**、当前模型、已配置 Key 数量
9. `.env.models` 内容变化时自动重建容器

> token 在交互终端直接显示；重定向/CI 等非交互输出中自动显示为 `********`。
> 需要强制显示或隐藏：`OPENCLAW_DEPLOY_SHOW_TOKEN=1|0 ./deploy.sh`。

也可以直接带地址和 Key 部署（写入 `.env.models`）：

```bash
DEEPSEEK_BASE_URL=https://your-gateway/v1 DEEPSEEK_API_KEY=sk-xxx ./deploy.sh
```

常用选项：

```bash
./deploy.sh --prepare-only     # 只准备文件，不启动
./deploy.sh --force-recreate   # 强制重建容器
./deploy.sh --force-config     # 用样例覆盖运行时 openclaw.json
```

内部调用 `docker compose`，因此也可以手工执行：

```bash
docker compose up -d
docker compose ps
docker compose logs -f openclaw-gateway
```

访问：

```bash
ssh -L 18789:127.0.0.1:18789 <user>@<host>
# 浏览器打开 http://127.0.0.1:18789/
# 登录 token: grep OPENCLAW_GATEWAY_TOKEN .env
```

## 国产模型地址与 Key

编辑 `.env.models`，按需填写地址和/或 Key（地址留空则用默认端点），然后重新执行 `./deploy.sh`（会自动重建容器）：

```bash
vi .env.models
# DEEPSEEK_BASE_URL=https://your-gateway/v1   # 可选
# DEEPSEEK_API_KEY=sk-xxxx
./deploy.sh
docker compose exec -T openclaw-gateway node dist/index.js models list --all --provider deepseek
```

已预置：DeepSeek、Qwen（DashScope 国内）、Z.AI GLM、Moonshot Kimi、火山方舟豆包、腾讯混元 TokenHub、StepFun、MiniMax（插件自带）。

## 密钥防泄漏

`.gitignore` 已忽略 `.env`、`.env.*`，只保留 `.env.example` 和 `.env.models.example`。
仓库还带一个 `pre-commit` 钩子：即使显式 `git add -f`，暂存了 `.env`/`.env.models` 也会拒绝提交。

`core.hooksPath` 是本地配置，克隆仓库后需要启用一次：

```bash
git config core.hooksPath .githooks
```

## 数据目录（宿主机）

| 内容 | 宿主机 | 容器内 |
| --- | --- | --- |
| 配置/状态 | `$HOME/.openclaw`（`.env` 的 `OPENCLAW_CONFIG_DIR`） | `/home/node/.openclaw` |
| 工作区 | `$HOME/.openclaw/workspace`（`OPENCLAW_WORKSPACE_DIR`） | `/home/node/.openclaw/workspace` |
| Skills | `$HOME/.openclaw/workspace/skills`（`OPENCLAW_SKILLS_DIR`） | `/home/node/.openclaw/workspace/skills` |

Skills 直接编辑宿主机目录即可，工作区 Skills 的优先级高于托管目录 `~/.openclaw/skills`（仍在配置挂载内）。

## 目录内容

| 文件 | 说明 |
| --- | --- |
| `deploy.sh` | 一键部署脚本（幂等） |
| `.githooks/pre-commit` | 提交前拒绝暂存本地密钥文件 |
| `docker-compose.yml` | Gateway + CLI，loopback 绑定，CLI 共享 Gateway 网络/PID |
| `CN-MODELS-DEPLOY.md` | 部署、模型配置、端点替换、排错完整文档 |
| `config/openclaw.json.example` | 运行时配置样例（无密钥，Key 均为环境变量引用） |
| `.env.example` | 部署变量模板 |
| `.env.models.example` | 模型 Key 占位符模板 |

`.env`、`.env.models`、`.env.models.sha256` 为本地状态，已被 `.gitignore` 忽略。
