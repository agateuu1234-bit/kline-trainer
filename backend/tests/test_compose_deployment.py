# backend/tests/test_compose_deployment.py
"""C1-3 / C1-3b / C1-4 / C1-5 / C1-8 / C1-9：部署编排的结构判据。

⚠️ 本文件只做结构断言。三类东西**结构断言抓不到**，归验收清单 / runbook：
  - `build:` 与带 digest 的 `image:` 同时存在这类坏配置 —— 实测
    `docker compose config` 对它**返回 0**，要到 `docker compose build` 才报
    `failed to solve: build tag cannot contain a digest`（spec T6-6）；
  - 「digest 是不是多架构 index」—— 单平台 digest 完全满足结构判据，
    却会在另一个架构上失败（spec T6-7）；
  - `${VAR:?}` 的**运行时行为** —— 需要 docker 可执行文件（spec T7-0）。
"""
from __future__ import annotations

from pathlib import Path

import yaml

COMPOSE_PATH = Path(__file__).resolve().parents[1] / "docker-compose.yml"

TRAINING_SETS_CONTAINER_PATH = "/data/training-sets"


def _compose() -> dict:
    return yaml.safe_load(COMPOSE_PATH.read_text(encoding="utf-8"))


def _services() -> dict:
    return _compose()["services"]


def _pull_type_services() -> dict:
    """拉取型 = 有 image、无 build。"""
    return {n: s for n, s in _services().items() if "image" in s and "build" not in s}


def _build_type_services() -> dict:
    """构建型 = 有 build。"""
    return {n: s for n, s in _services().items() if "build" in s}


# ── 防空转：两类服务都必须真的存在，否则下面的循环恒真 ──────────────────
def test_both_service_classes_are_non_empty():
    assert _pull_type_services(), "没有拉取型服务 —— digest 判据会恒真通过"
    assert _build_type_services(), "没有构建型服务 —— 反向 digest 判据会恒真通过"


def test_service_classes_cover_every_service():
    """分类必须**完备**：两类之外的第三类服务会同时逃过两条 digest 断言。

    `_pull_type_services` 认「有 image 无 build」，`_build_type_services` 认「有 build」——
    一个两者都没有的服务会被两个筛子同时漏掉，于是它的镜像来源不受任何判据约束，
    而且不会有任何测试变红。这条把「漏掉」从"目前碰巧不会发生"提升成"结构上不可能"。
    """
    services = set(_services())
    covered = set(_pull_type_services()) | set(_build_type_services())
    assert covered == services, (
        "有服务既不算拉取型也不算构建型，两条 digest 判据都够不着: "
        f"{sorted(services - covered)!r}"
    )


def test_project_name_is_explicit():
    """T4-1：显式项目名。

    两个理由（spec §4-D2 + §2.5-c）：
      ① NAS 上已有一个 2026-04 的 `backend-api:latest` 遗留镜像，默认项目名会撞车；
      ② NAS 上**已经存在**卷 `backend_pgdata` —— 默认项目名会静默复用那个旧卷，
         而 schema.sql 全是 CREATE TABLE IF NOT EXISTS，会什么都不修却报成功。
    """
    assert _compose().get("name") == "kline-trainer"


def test_api_service_exists():
    assert "api" in _services()


def test_db_has_healthcheck():
    """T4-1c：没有健康检查，下面的 service_healthy 就无从谈起。"""
    assert "healthcheck" in _services()["db"]


def test_api_depends_on_db_being_healthy():
    """T4-1b：必须是 condition 形式，不是裸列表。

    裸 `depends_on: [db]` 只保证「db 容器启动了」，不保证「PG 能接受连接」。
    api 先起来 → create_pool 抛错 → FastAPI startup 失败 → 容器退出。

    ⚠️ 两条腿分工要记清，别把功劳记错：
      - `depends_on` + healthcheck 只覆盖**一次 `docker compose up` 内部的启动次序**；
      - 宿主（NAS）断电重启后，是 Docker 守护进程按 restart 策略把容器拉起来的，
        这条路**不走** `depends_on` —— 那一半由 `restart: unless-stopped` 覆盖
        （见 test_api_has_restart_policy）。
    """
    depends = _services()["api"]["depends_on"]
    assert isinstance(depends, dict), f"depends_on 必须是映射形式，实际: {depends!r}"
    assert depends["db"]["condition"] == "service_healthy"


def test_api_has_restart_policy():
    """T4-1d。"""
    assert "restart" in _services()["api"]


def test_api_host_port_defaults_to_loopback():
    """T4-2 / C1-4：默认只绑回环，不得默认对局域网开放。"""
    ports = _services()["api"]["ports"]
    assert any(str(p).startswith("${API_BIND_HOST:-127.0.0.1}:") for p in ports), (
        f"api 的宿主端口绑定默认值不是 127.0.0.1: {ports!r}"
    )


def test_every_published_host_port_defaults_to_loopback():
    """T4-2 / C1-4 的**整族**版：任何服务发布到宿主的端口都必须默认绑回环。

    上面那条只守 api。而 db 同样把端口发布到宿主
    （`${DB_BIND_HOST:-127.0.0.1}:5433:5432`），它前面挡着的是 postgres 超级用户密码 ——
    把那个默认值翻成 `0.0.0.0`，在只守 api 的情况下**不会有任何测试变红**。
    本仓的规矩是判据要按「判据本身」修整族，不是只修被报出来的那一处。
    """
    examined: list[str] = []
    for name, svc in _services().items():
        for entry in svc.get("ports") or []:
            text = str(entry)
            examined.append(text)
            assert text.startswith("${") and ":-127.0.0.1}:" in text, (
                f"服务 {name} 的宿主端口绑定默认值不是 127.0.0.1: {text!r}"
            )
    assert examined, "没有任何服务发布宿主端口 —— 本条判据恒真通过，已失效"


def test_training_sets_mount_is_readonly_at_fixed_container_path():
    """T4-3 / C1-5：只读，且容器内路径固定。

    容器内路径固定很重要：`training_sets.file_path` 存的就是这个路径，
    宿主目录怎么变都不用改数据库。
    """
    volumes = [str(v) for v in _services()["api"]["volumes"]]
    matching = [v for v in volumes if f":{TRAINING_SETS_CONTAINER_PATH}:" in v]
    assert matching, f"api 没有挂到 {TRAINING_SETS_CONTAINER_PATH}: {volumes!r}"
    for entry in matching:
        assert entry.endswith(":ro"), f"训练组挂载不是只读: {entry!r}"


def test_pull_type_images_are_digest_pinned():
    """T6-1 / T6-2 / C1-8①：拉取型服务的 image 必须带 digest。"""
    for name, svc in _pull_type_services().items():
        assert "@sha256:" in str(svc["image"]), (
            f"拉取型服务 {name} 的 image 没有 @sha256: digest: {svc['image']!r}"
        )


def test_build_type_services_have_no_digest_in_image():
    """T6-3 / C1-8②：构建型服务**不得**在 image 里带 digest。

    ⚠️ 这条是反向档，不能只测「有 digest」。spec 的 R3-F1 就是这个坑：
    `build:` + `image: x@sha256:…` 会让 `docker compose build` 直接报
    `failed to solve: build tag cannot contain a digest`，而
    `docker compose config` 对这份坏配置**返回 0**。
    """
    for name, svc in _build_type_services().items():
        image = str(svc.get("image", ""))
        assert "@sha256:" not in image, (
            f"构建型服务 {name} 的 image 带了 digest —— docker compose build 会直接失败"
        )


def test_no_latest_tag_anywhere():
    """T6-4。"""
    for name, svc in _services().items():
        image = str(svc.get("image", ""))
        assert ":latest" not in image, f"服务 {name} 用了 :latest: {image!r}"


def test_database_url_uses_required_variable_syntax():
    """T7-1s / C1-9：必须是 `${DATABASE_URL:?…}`，不是 `${DATABASE_URL}` 也不是 `:-`。

    为什么（spec §4-D5 补强）：`.env` 丢失或在错误目录 `up` 时，插值会得到**空串**，
    而 `os.environ.get("DATABASE_URL")` 对空串返回假值 → 后端静默回落 InMemory，
    服务照样 200 地跑着，只是一行数据都没有。空串比未设更阴险，`:-` 只挡未设。
    """
    value = str(_services()["api"]["environment"]["DATABASE_URL"])
    assert value.startswith("${DATABASE_URL:?"), (
        f"DATABASE_URL 没有用必需变量语法: {value!r}"
    )
    assert value.endswith("}")
    assert "${DATABASE_URL:-" not in value, "用了默认值语法 —— 挡不住空串"


def test_training_sets_host_dir_uses_required_variable_syntax():
    """宿主训练组目录同样没有合理默认值：配错会导致 download 一律 404，症状很难认。"""
    volumes = [str(v) for v in _services()["api"]["volumes"]]
    matching = [v for v in volumes if f":{TRAINING_SETS_CONTAINER_PATH}:" in v]
    assert matching, "找不到训练组挂载项"
    assert all(v.startswith("${TRAINING_SETS_HOST_DIR:?") for v in matching), (
        f"训练组宿主目录没有用必需变量语法: {matching!r}"
    )
