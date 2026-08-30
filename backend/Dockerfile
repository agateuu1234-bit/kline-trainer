# backend/Dockerfile —— API 镜像（spec §4-D2 / C1-2 / C1-8②）
#
# 基础镜像必须是「精确 patch tag + @sha256: digest」：
#   - 精确 patch tag 让人看得出装的是哪个 Python；
#   - digest 才是真正钉死供应链的那一半（tag 可以被重新指向）。
# digest 取的是**多架构 manifest list（OCI image index）**的顶层 digest，
# 不是单平台 manifest 的 —— 否则镜像会被钉死在一个架构上（Mac arm64 / NAS amd64）。
# 2026-08-24 实测：该 index 同时覆盖 linux/amd64 与 linux/arm64/v8。
#
# ⚠️ 这里钉死的到底是什么，说准一点，别把话说大：
#   - 基础镜像：由 digest 钉死；
#   - requirements-api.txt 里那三个**直接**依赖：由 `==` 精确版本钉死；
#   - 它们各自的**间接（传递）**依赖：**没有钉死**。fastapi 会带来 starlette /
#     pydantic / pydantic-core / anyio / typing-extensions，uvicorn 会带来 click / h11，
#     这些都按安装当时 PyPI 上的可用版本解析。
#   所以：同一个 commit 隔几个月各构建一次，这条线以下装到的代码**可能不同**。
#   要连传递依赖一起钉死需要一份 lock 文件（`pip-compile` 之类），那会改变实际装进去的
#   包集合、需要单独一轮验证，本 PR 不做，记为残留项。
FROM python:3.11.14-slim@sha256:c8271b1f627d0068857dce5b53e14a9558603b527e46f1f901722f935b786a39

# 刻意不叫 /app —— 应用包本身就叫 app，两者同名会让 COPY 目标很难读。
WORKDIR /srv

# 依赖层单独 COPY，改应用代码时不用重装依赖。
COPY requirements-api.txt ./
RUN pip install --no-cache-dir -r requirements-api.txt

COPY app ./app

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
