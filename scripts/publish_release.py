#!/usr/bin/env python3
# publish_release.py — 三端构建产物发布 release（每次 push 到 main 且全部 job 成功后由 CI 调用）
#
# 发布目标（issue #3）:
#   1. GitLab Releases（私有化部署，全量存档）:
#      - 产物上传 generic packages（永久存储）→ 创建 release，assets links 指向包文件
#   2. GitHub Releases（公开仓库 CodeFuckee/daymark，对外分发）:
#      - 创建 release + 上传 3 个资产（AppImage/dmg/exe，uploads.github.com）
#      - 滚动保留: 每次发布后删除最老 release（保留 RELEASE_KEEP=5 个，tag 保留不占空间）
#
# 版本号: vX.Y.Z 自动递增（patch+1），以 GitLab releases 最新 tag 为权威（全量保留不丢失）
# 构建时间: release 名称/描述中展示（CI_PIPELINE_CREATED_AT，UTC+8）
#
# 环境变量:
#   GITHUB_TOKEN      GitHub PAT（API 写权限）
#   GITLAB_API_URL    GitLab API 基址（如 https://home.chenkaidi.top:509/api/v4）
#   GITLAB_JOB_TOKEN  用于 GitLab API（CI_JOB_TOKEN，需项目 API 权限）
#   GITLAB_PROJECT    项目 id（如 126）
#   RELEASE_KEEP      GitHub 保留 release 数（默认 5）
#   CI_PROJECT_DIR    构建产物目录（默认 .）
#   CI_PIPELINE_CREATED_AT  流水线创建时间（构建时间显示）

import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

GITHUB_REPO = os.environ.get("GITHUB_REPO", "CodeFuckee/daymark")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
GITLAB_API = os.environ.get("GITLAB_API_URL", "").rstrip("/")
GITLAB_JOB_TOKEN = os.environ.get("GITLAB_JOB_TOKEN", "")
GITLAB_PROJECT = os.environ.get("GITLAB_PROJECT", "")
KEEP = int(os.environ.get("RELEASE_KEEP", "5"))
BUILD_TIME = os.environ.get("CI_PIPELINE_CREATED_AT", "")

# 三端产物（CI artifacts 文件名 → release 资产名）
ASSETS = [
    ("daymark-x86_64.AppImage", "daymark-linux-x86_64.AppImage"),
    ("daymark-macos-arm64.dmg", "daymark-macos-arm64.dmg"),
    ("daymark-windows-x64-setup.exe", "daymark-windows-x64-setup.exe"),
]

PACKAGE_NAME = "daymark"


def report_failure(msg):
    """失败诊断：宿主 /tmp 日志（shell executor 可直接读取）"""
    log = f"/tmp/publish_release_debug_{os.environ.get('CI_JOB_ID', 'local')}.log"
    try:
        with open(log, "w") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] publish-release 失败\n{msg}\n")
    except Exception:
        pass
    print("!! 发布失败:", msg[:500], file=sys.stderr)


def gh_api(method, path, body=None, binary=None, retries=3):
    """GitHub API（api.github.com / uploads.github.com 均走此通道）"""
    url = path if path.startswith("http") else f"https://api.github.com{path}"
    headers = {"Authorization": f"token {GITHUB_TOKEN}",
               "Accept": "application/vnd.github+json"}
    data = binary if binary is not None else (json.dumps(body).encode() if body is not None else None)
    if binary is not None:
        headers["Content-Type"] = "application/octet-stream"
    for i in range(retries):
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            err = e.read().decode()[:300]
            if e.code in (401, 403):
                raise RuntimeError(f"GitHub API {e.code}: {err}")
            if 400 <= e.code < 500 and e.code not in (408, 429):
                raise RuntimeError(f"GitHub API {e.code}: {err}")
            if i == retries - 1:
                raise
            time.sleep(2 * (i + 1))
        except OSError:
            if i == retries - 1:
                raise
            time.sleep(2 * (i + 1))


def gl_api(method, path, body=None, binary=None, content_type=None, retries=3):
    """GitLab API（CI_JOB_TOKEN 认证）"""
    url = f"{GITLAB_API}{path}"
    headers = {"JOB-TOKEN": GITLAB_JOB_TOKEN}
    data = binary if binary is not None else (json.dumps(body).encode() if body is not None else None)
    if binary is not None:
        headers["Content-Type"] = content_type or "application/octet-stream"
    elif body is not None:
        headers["Content-Type"] = "application/json"
    for i in range(retries):
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            err = e.read().decode()[:300]
            if 400 <= e.code < 500 and e.code not in (408, 429):
                raise RuntimeError(f"GitLab API {e.code}: {err}")
            if i == retries - 1:
                raise
            time.sleep(2 * (i + 1))
        except OSError:
            if i == retries - 1:
                raise
            time.sleep(2 * (i + 1))


def next_version():
    """从 GitLab releases 最新 tag 递增 patch；无 release 则 v0.1.0"""
    try:
        rels = gl_api("GET", f"/projects/{GITLAB_PROJECT}/releases?per_page=20")
        tags = [r.get("tag_name", "") for r in rels]
    except RuntimeError:
        tags = []
    for t in tags:
        m = re.match(r"^v(\d+)\.(\d+)\.(\d+)$", t)
        if m:
            maj, mino, pat = int(m[1]), int(m[2]), int(m[3])
            return f"v{maj}.{mino}.{pat + 1}"
    return "v0.1.0"


def fmt_build_time():
    """CI_PIPELINE_CREATED_AT（UTC ISO）→ 本地 +08:00 展示"""
    if not BUILD_TIME:
        return time.strftime("%Y-%m-%d %H:%M")
    try:
        t = time.strptime(BUILD_TIME[:19], "%Y-%m-%dT%H:%M:%S")
        ts = int(time.mktime(t)) + 8 * 3600  # UTC → UTC+8
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts))
    except Exception:
        return BUILD_TIME[:16]


def release_body(version, sha):
    return (
        f"**构建时间**: {fmt_build_time()}（UTC+8）\n"
        f"**来源提交**: {sha}\n"
        f"**下载**（三端）:\n"
        f"- Linux: `daymark-linux-x86_64.AppImage`\n"
        f"- macOS (arm64): `daymark-macos-arm64.dmg`\n"
        f"- Windows x64: `daymark-windows-x64-setup.exe`\n"
    )


def publish_gitlab(version, sha):
    """GitLab：generic packages 上传 3 个产物 → 创建 release（assets links 指向包文件）"""
    print("==> GitLab 发布（packages + release）")
    links = []
    with ThreadPoolExecutor(max_workers=3) as pool:
        futs = {}
        for local, remote in ASSETS:
            path = os.path.join(os.environ.get("CI_PROJECT_DIR", "."), local)
            if not os.path.exists(path):
                raise RuntimeError(f"缺少产物: {local}")
            futs[pool.submit(gl_api, "PUT",
                             f"/projects/{GITLAB_PROJECT}/packages/generic/{PACKAGE_NAME}/{version}/{remote}",
                             binary=open(path, "rb").read())] = (local, remote)
        for fut, (local, remote) in futs.items():
            try:
                fut.result()
            except RuntimeError as e:
                if "422" not in str(e) and "409" not in str(e):
                    raise  # 422/409 = 同版本包已存在（重跑幂等），跳过
            links.append({
                "name": remote,
                "url": f"{GITLAB_API}/projects/{GITLAB_PROJECT}/packages/generic/{PACKAGE_NAME}/{version}/{remote}",
                "link_type": "package",
            })
    release = gl_api("POST", f"/projects/{GITLAB_PROJECT}/releases", {
        "tag_name": version, "name": f"Daymark {version}",
        "description": release_body(version, sha),
        "ref": os.environ.get("CI_COMMIT_SHA", "main"),  # GitLab 要求 ref（tag 指向的提交）
        "assets": {"links": links},
    })
    print(f"    已发布 {release.get('_links', {}).get('web_url', version)}")


def publish_github(version, sha):
    """GitHub：创建 release（自动打 tag）→ 上传 3 资产 → 滚动保留 KEEP 个"""
    print("==> GitHub 发布（release + 资产上传 + 滚动保留）")
    rel = gh_api("POST", f"/repos/{GITHUB_REPO}/releases", {
        "tag_name": version, "name": f"Daymark {version}",
        "body": release_body(version, sha),
        "target_commitish": "main",
    })
    upload_url = rel["upload_url"].replace("{?name,label}", "")
    with ThreadPoolExecutor(max_workers=3) as pool:
        futs = {}
        for local, remote in ASSETS:
            path = os.path.join(os.environ.get("CI_PROJECT_DIR", "."), local)
            futs[pool.submit(gh_api, "POST",
                             f"{upload_url}?name={urllib.parse.quote(remote)}",
                             binary=open(path, "rb").read())] = remote
        for fut, remote in futs.items():
            asset = fut.result()
            print(f"    资产 {remote} ({asset.get('size', 0) // 1024} KB)")
    print(f"    已发布 {rel['html_url']}")

    # 滚动保留：按发布时间排序，删除最老的（保留 KEEP 个）
    all_rel = gh_api("GET", f"/repos/{GITHUB_REPO}/releases?per_page=100")
    all_rel.sort(key=lambda r: r.get("created_at", ""), reverse=True)
    for old in all_rel[KEEP:]:
        gh_api("DELETE", f"/repos/{GITHUB_REPO}/releases/{old['id']}")
        print(f"    滚动保留: 删除旧 release {old['tag_name']}")


def main():
    if not GITHUB_TOKEN:
        raise RuntimeError("GITHUB_TOKEN 未设置")
    if not (GITLAB_API and GITLAB_JOB_TOKEN and GITLAB_PROJECT):
        raise RuntimeError("GitLab API 配置缺失（GITLAB_API_URL/GITLAB_JOB_TOKEN/GITLAB_PROJECT）")
    sha = os.environ.get("CI_COMMIT_SHORT_SHA", "unknown")

    # CI 流水线内由 prepare-version job 传入（与构建产物内嵌版本严格一致，
    # 自动更新比较的前提）；本地/无参数运行时仍自动递增
    version = os.environ.get("RELEASE_VERSION", "")
    if not version:
        version = next_version()
    print(f"==> 发布版本 {version}（来源 GitLab {sha}，构建时间 {fmt_build_time()}）")

    publish_gitlab(version, sha)
    publish_github(version, sha)
    print("==> 发布完成 ✅")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        report_failure(f"{type(e).__name__}: {e}\n{tb}")
        print(tb, file=sys.stderr)
        sys.exit(1)
