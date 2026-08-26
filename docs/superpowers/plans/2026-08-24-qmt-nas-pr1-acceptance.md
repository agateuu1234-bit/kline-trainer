# PR-1 验收清单（配置覆盖守卫 + `/health` 暴露 repository）

> 面向非程序员。一行一条命令，从上往下照做。命令里出现的 `PY=` 一行只需在**每个新开的终端窗口**跑一次。
> 本 PR **不涉及** NAS、不涉及手机、不部署任何东西 —— 它只改仓库里的三个文件，外加四个测试文件（一个是全新写的，一个是把旧测试文件整个重写、从一条测试扩到四条，另外两个是给旧测试里 `/health` 的返回值断言顺带改了一行）。

## 准备（每个新终端窗口跑一次）

| 动作 | 预期 | 通过条件 |
|---|---|---|
| 粘贴：`PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"` | 没有任何输出 | 光标回到新的一行 |
| 粘贴：`cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-pr1/backend"` | 没有任何输出 | 光标回到新的一行 |

## 一、看得见的行为：健康检查现在会告诉你连的是真库还是假库

| 动作 | 预期 | 通过条件 |
|---|---|---|
| 粘贴：`"$PY" -c "from fastapi.testclient import TestClient; from app.main import app; print(TestClient(app).get('/health').json())"` | 屏幕打印一行字典 | 那一行**恰好**是 `{'status': 'ok', 'repository': 'inmemory'}` |

这条的意思：没给数据库地址时，后端用的是**内存里的假库**，而现在它会**明说**。改这个字段之前，它只回一句 `ok`，你无法分辨手机拉到的是真数据还是空气。

## 二、自动检查：7 条守卫测试都在岗

| 动作 | 预期 | 通过条件 |
|---|---|---|
| 粘贴：`"$PY" -m pytest tests/test_env_example_coverage.py tests/test_health.py -q` | 最后一行出现测试统计 | 最后一行含 `7 passed`，且**不含** `failed`、`error`、`skipped` |

## 三、整套后端测试没有被弄坏

| 动作 | 预期 | 通过条件 |
|---|---|---|
| 粘贴：`"$PY" -m pytest tests/ -q` | 跑几十秒后打印统计 | 最后一行含 `passed`，且**不含** `failed`、`error`、`skipped` |

⚠️ 出现 `skipped` 也算不通过 —— 本仓的持续集成把「跳过」当失败处理。

## 四、配置样例文件确实补上了

| 动作 | 预期 | 通过条件 |
|---|---|---|
| 用「文本编辑」打开 `/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-pr1/backend/.env.example` | 看到 14 行左右的配置样例 | 文件里**同时**有 `DB_URL=` 开头的一行**和** `DATABASE_URL=` 开头的一行 |

这条的意思：两个名字**都要在**。`DB_URL` 是从你的电脑连 NAS 用的，`DATABASE_URL` 是后端程序自己读的 —— 之前只有前者，所以后端一直读不到，会悄悄换成假库。

## 五、本 PR **没有**做到的事（防止误以为已完成）

- 后端**还没有**部署到 NAS，手机**还拉不到**任何东西。
- `/health` 现在能报 `asyncpg`，但那要等后端真的连上 NAS 上的数据库之后才会出现。
- 训练组数据**没有**被搬动，NAS 上什么都没变。
