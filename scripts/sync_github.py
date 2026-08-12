#!/usr/bin/env python3
# sync_github.py — 把当前提交的源码快照同步到 GitHub（每次 push 到 main 时由 CI 调用）
#
# 为什么用 GitHub REST API 而不是 git push:
#   国内网络对 github.com 域名的 SNI 干扰是间歇性的（TCP 通、TLS 握手被丢弃），
#   但 api.github.com 一直稳定可达。本脚本经 api.github.com 的 git database API
#   （blobs/trees/commits/refs）推送代码，绕开被干扰的 git 端点。
#
# 流程:
#   1. git ls-files -s 取本地快照（排除 .gitlab-ci.yml 脱敏）
#   2. 对比远程分支当前 tree（recursive），只上传差异文件的 blob
#   3. 递归构建新 tree → 创建 commit（parent = 远程 HEAD）→ 更新 refs/heads/main
#      （首次推送用 POST /git/refs 创建分支）
#
# 环境变量:
#   GITHUB_TOKEN  必填, GitHub PAT（GitLab CI variable 注入，需仓库写权限）
#   GITHUB_REPO   可选, 默认 CodeFuckee/daymark
#   GITHUB_BRANCH 可选, 默认 main
#
# 标准库实现（urllib），无第三方依赖；API 失败自动重试 3 次。

import base64
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

REPO = os.environ.get("GITHUB_REPO", "CodeFuckee/daymark").strip("/")
BRANCH = os.environ.get("GITHUB_BRANCH", "main")
TOKEN = os.environ.get("GITHUB_TOKEN", "")
EXCLUDE = {".gitlab-ci.yml"}  # 脱敏：不推送 GitLab CI 流水线文件

API = "https://api.github.com"
H = {"Authorization": f"token {TOKEN}", "Accept": "application/vnd.github+json"}


def probe():
    """网络预检：api.github.com 连通性（区分网络问题与权限问题）"""
    try:
        req = urllib.request.Request(API, headers=H)
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except OSError as e:
        raise SystemExit(f"!! 无法连接 api.github.com（网络不通）: {e}")


def api(method, path, body=None, retries=3):
    url = f"{API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    for i in range(retries):
        req = urllib.request.Request(url, data=data, method=method, headers=H)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            body = e.read().decode()[:300]
            if e.code in (401, 403):
                raise RuntimeError(f"GitHub API {e.code}: {body}")
            # 4xx 客户端错误（404/409 等）不重试，带响应 body 快速抛给调用方
            if 400 <= e.code < 500 and e.code not in (408, 429):
                raise RuntimeError(f"GitHub API {e.code}: {body}")
            if i == retries - 1:
                raise
            time.sleep(2 * (i + 1))
        except OSError:
            if i == retries - 1:
                raise
            time.sleep(2 * (i + 1))


def local_files():
    """解析 .git/index → {path: (mode, blob_sha)}（等价 git ls-files -s），排除脱敏文件。
    零外部依赖：不需要 git 命令（python 镜像/宿主机无 git 也能跑）。"""
    data = open(os.path.join(os.environ.get("CI_PROJECT_DIR", "."), ".git", "index"), "rb").read()
    assert data[:4] == b"DIRC", "invalid git index"
    count = struct.unpack(">II", data[4:12])[1]
    files = {}
    off = 12
    for _ in range(count):
        mode, = struct.unpack(">I", data[off + 24:off + 28])
        sha = data[off + 40:off + 60].hex()
        flags, = struct.unpack(">H", data[off + 60:off + 62])
        pathlen = flags & 0x0FFF
        if pathlen < 0x0FFF:
            path = data[off + 62:off + 62 + pathlen].decode()
            size = 62 + pathlen + 1  # + NUL
        else:
            end = data.index(b"\0", off + 62)
            path = data[off + 62:end].decode()
            size = end - off + 1
        off = off + ((size + 7) & ~7)  # 8 字节对齐
        if path not in EXCLUDE:
            files[path] = (f"{mode:o}", sha)
    return files


def remote_head_and_tree():
    """远程分支 HEAD sha + recursive tree {path: sha}；分支不存在返回 (None, {})"""
    try:
        ref = api("GET", f"/repos/{REPO}/git/refs/heads/{BRANCH}")
    except RuntimeError as e:
        # 404 = 分支不存在；409 = 仓库为空（GitHub 对空仓库的 refs 查询行为）
        if any(code in str(e) for code in ("404", "409")):
            return None, {}
        raise
    head = ref["object"]["sha"]
    tree = api("GET", f"/repos/{REPO}/git/trees/{head}?recursive=1")["tree"]
    return head, {t["path"]: t["sha"] for t in tree if t["type"] == "blob"}


def upload_blobs(paths):
    """按 blob sha 去重后并行上传（内容相同的文件只传一次，避免并发创建同对象
    被 GitHub 拒 409）；409 视为对象已存在（幂等）。返回 {path: (mode, blob_sha)}"""
    by_sha = {}
    for path, (mode, sha) in paths.items():
        if not os.path.exists(path):
            continue  # index 与工作树不一致（文件已删未提交），跳过
        by_sha.setdefault(sha, []).append((path, mode))
    with ThreadPoolExecutor(max_workers=8) as pool:
        futs = {}
        for sha, items in by_sha.items():
            content = open(items[0][0], "rb").read()
            futs[pool.submit(
                api, "POST", "/repos/%s/git/blobs" % REPO,
                {"content": base64.b64encode(content).decode(), "encoding": "base64"},
            )] = (sha, items)
        result = {}
        for fut, (sha, items) in futs.items():
            try:
                blob_sha = fut.result()["sha"]
            except RuntimeError as e:
                if "409" not in str(e):
                    raise
                blob_sha = sha  # 409 = 对象已存在
            for path, mode in items:
                result[path] = (mode, blob_sha)
        return result


def build_tree(prefix, files):
    """递归构建 tree：目录 → subtree；返回 (sha, {path: sha} 扁平映射)"""
    if prefix:
        items = [p for p in files if p.startswith(prefix + "/")]
    else:
        items = [p for p in files]
    dirs, entries = {}, []
    for p in items:
        rel = p[len(prefix) + 1:] if prefix else p
        if "/" in rel:
            d, _ = rel.split("/", 1)
            dirs.setdefault(d, []).append(p)
        else:
            mode, sha = files[p]
            entries.append({"path": rel, "mode": mode, "type": "blob", "sha": sha})
    flat = {}
    for d, children in dirs.items():
        sha, subflat = build_tree(f"{prefix}/{d}" if prefix else d, files)
        entries.append({"path": d, "mode": "040000", "type": "tree", "sha": sha})
        flat.update(subflat)
    tree = api("POST", f"/repos/{REPO}/git/trees",
               {"tree": entries})
    flat[prefix] = tree["sha"]
    return tree["sha"], flat


def report_failure(msg):
    """失败诊断上报（双通道）：
    1. 宿主 /tmp 日志（shell executor 场景，便于直接读取排查）
    2. GitLab issue 评论（若配置了 GITLAB_API_URL/JOB_TOKEN）"""
    log = f"/tmp/sync_github_debug_{os.environ.get('CI_JOB_ID', 'local')}.log"
    try:
        with open(log, "w") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] push-to-github 失败\n{msg}\n")
    except Exception:
        pass
    api_url = os.environ.get("GITLAB_API_URL", "")
    job_token = os.environ.get("GITLAB_JOB_TOKEN", "")
    issue = os.environ.get("GITLAB_ISSUE", "")  # 格式: project_id/work_item_iid
    if not (api_url and job_token and issue):
        return
    try:
        pid, iid = issue.split("/")
        req = urllib.request.Request(
            f"{api_url}/projects/{pid}/issues/{iid}/notes",
            data=json.dumps({"body": f"⚠️ push-to-github 同步失败：{msg[:1500]}"}).encode(),
            method="POST",
            headers={"JOB-TOKEN": job_token, "Content-Type": "application/json"},
        )
        urllib.request.urlopen(req, timeout=30)
    except Exception:
        pass


def main():
    if not TOKEN:
        print("!! GITHUB_TOKEN 未设置", file=sys.stderr)
        sys.exit(1)

    st = probe()
    print(f"==> api.github.com 预检: HTTP {st}（token 认证状态）")

    print(f"==> 本地快照（git ls-files，排除 {sorted(EXCLUDE)}）")
    local = local_files()
    print(f"    共 {len(local)} 个文件")

    head, remote = remote_head_and_tree()
    if head is None:
        # 空仓库 bootstrap：GitHub 不允许空仓库用 git database API 创建 tree
        # （409 "Git Repository is empty"），先用 Contents API 建首个提交，
        # .gitkeep 会在本次正式同步的新 tree 中被删除
        print("==> 空仓库，Contents API bootstrap 首个提交")
        try:
            api("PUT", f"/repos/{REPO}/contents/.gitkeep",
                {"message": "bootstrap empty repository", "content": base64.b64encode(b"").decode()})
        except RuntimeError as e:
            if "409" not in str(e):  # 409 = .gitkeep 已存在（上次 bootstrap 残留）
                raise
        head, remote = remote_head_and_tree()
    print(f"==> 远程 {BRANCH}: {'HEAD ' + head[:8] if head else '（分支不存在，首次推送）'}")

    # 差异：本地有而远程 sha 不同 → 上传；远程独有 → 新 tree 不含即删除
    changed = {p: (m, s) for p, (m, s) in local.items() if remote.get(p) != s}
    print(f"    差异文件 {len(changed)} 个，开始上传 blob")
    uploaded = upload_blobs(changed) if changed else {}

    # 目标 tree = 本地全部文件；变化文件用上传后的 sha，未变文件引用本地 git sha
    # （GitHub 已存在相同内容对象，无需重复上传）；远程独有文件不在其中即被删除
    files = dict(local)
    files.update(uploaded)

    print("==> 构建 tree")
    root_sha, _ = build_tree("", files)

    msg = f"sync from GitLab {os.environ.get('CI_COMMIT_SHORT_SHA', 'local')}"
    commit = api("POST", f"/repos/{REPO}/git/commits",
                 {"message": msg, "tree": root_sha,
                  "parents": [head] if head else [],
                  "author": {"name": "daymark CI", "email": "daymark-ci@users.noreply.github.com"},
                  "committer": {"name": "daymark CI", "email": "daymark-ci@users.noreply.github.com"}})
    sha = commit["sha"]
    print(f"==> commit {sha[:8]}")

    if head:
        api("PATCH", f"/repos/{REPO}/git/refs/heads/{BRANCH}", {"sha": sha, "force": False})
    else:
        api("POST", f"/repos/{REPO}/git/refs", {"ref": f"refs/heads/{BRANCH}", "sha": sha})
    print(f"==> 已同步 {REPO} ({BRANCH})，{len(files)} 个文件，来源 GitLab")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        report_failure(f"{type(e).__name__}: {e}\n{tb}")
        print("!! 同步失败:", e, file=sys.stderr)
        print(tb, file=sys.stderr)
        sys.exit(1)
