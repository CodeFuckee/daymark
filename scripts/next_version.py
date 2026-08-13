#!/usr/bin/env python3
# next_version.py — 计算下一个发布版本 X.Y.Z（不带 v 前缀），stdout 输出
#
# 与 publish_release.py 的 next_version() 同一逻辑（版本以 GitLab releases
# 最新 tag 为权威，patch+1 递增）：构建与发布共用本脚本保证产物内嵌版本
# 与 release tag 严格一致（issue #5 自动更新的比较前提）。
#
# 认证：CI_JOB_TOKEN（GitLab CI 环境）；无 API 环境（本地构建）→ 回退读取
# pubspec.yaml 的 version（build-name 部分，如 1.0.0+1 → 1.0.0）。
#
# 环境变量:
#   GITLAB_API_URL    GitLab API 基址（如 https://home.chenkaidi.top:509/api/v4）
#   GITLAB_JOB_TOKEN  CI job token
#   GITLAB_PROJECT    项目 id（如 126）

import json
import os
import re
import sys
import urllib.request

GITLAB_API = os.environ.get("GITLAB_API_URL", "").rstrip("/")
GITLAB_JOB_TOKEN = os.environ.get("GITLAB_JOB_TOKEN", "")
GITLAB_PROJECT = os.environ.get("GITLAB_PROJECT", "")


def latest_release_tags():
    """GitLab releases 最新 tag 列表（新→旧）"""
    if not (GITLAB_API and GITLAB_JOB_TOKEN and GITLAB_PROJECT):
        return []
    req = urllib.request.Request(
        f"{GITLAB_API}/projects/{GITLAB_PROJECT}/releases?per_page=20",
        headers={"JOB-TOKEN": GITLAB_JOB_TOKEN},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            releases = json.loads(r.read())
        return [rel.get("tag_name", "") for rel in releases]
    except Exception as e:
        print(f"next_version: GitLab API 不可用（{e}），回退 pubspec 版本", file=sys.stderr)
        return []


def pubspec_version():
    """pubspec.yaml version 的 build-name 部分（本地开发构建回退）"""
    try:
        with open("pubspec.yaml", encoding="utf-8") as f:
            m = re.search(r"^version:\s*(\d+\.\d+\.\d+)", f.read(), re.M)
            if m:
                return m.group(1)
    except Exception:
        pass
    return "1.0.0"


def main():
    for tag in latest_release_tags():
        m = re.match(r"^v(\d+)\.(\d+)\.(\d+)$", tag)
        if m:
            maj, mino, pat = int(m[1]), int(m[2]), int(m[3])
            print(f"{maj}.{mino}.{pat + 1}")
            return
    print(pubspec_version())


if __name__ == "__main__":
    main()
