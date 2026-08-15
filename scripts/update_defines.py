#!/usr/bin/env python3
# update_defines.py — 生成自动更新 dart-define 参数（issue #5 / #7）
#
# 打包时将更新源地址写入软件（--dart-define），stdout 输出参数串（空格分隔）：
#   --dart-define=DAYMARK_APP_VERSION=0.1.3 --dart-define=DAYMARK_UPDATE_SOURCES_B64=...
#
# 用法:
#   python3 scripts/update_defines.py --version X.Y.Z [--gitlab | --github] [--repo owner/repo]
#
# 源 JSON 结构（应用内 UpdateConfig.parse 解析，base64 避免转义问题）:
#   [{"type":"gitlab","api":"https://host/api/v4","project":"ns%2Fproj"}]
#   [{"type":"github","repo":"owner/repo"}]
#
# GitLab 源自动取 CI 环境（CI_SERVER_URL/CI_PROJECT_PATH）。仓库为 public
# （issue #5 用户确认）→ 不内置 token，更新检测/下载全部匿名访问。
# 构建时间（issue #7）也在此注入：DAYMARK_BUILD_TIME = UTC ISO8601
# （prepare-version 运行时刻，约等于产物构建时间），设置页关于板块展示。

import argparse
import base64
import json
import os
import urllib.parse
from datetime import datetime, timezone


def gitlab_source():
    host = os.environ.get("CI_SERVER_URL", "").rstrip("/")
    path = os.environ.get("CI_PROJECT_PATH", "")
    if not host or not path:
        raise SystemExit("--gitlab 需要 CI_SERVER_URL / CI_PROJECT_PATH 环境变量")
    return {
        "type": "gitlab",
        "api": f"{host}/api/v4",
        "project": urllib.parse.quote(path, safe=""),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True, help="产物版本 X.Y.Z")
    parser.add_argument("--gitlab", action="store_true", help="注入 GitLab 更新源")
    parser.add_argument("--github", action="store_true", help="注入 GitHub 更新源")
    parser.add_argument("--repo", default="CodeFuckee/daymark", help="GitHub 仓库 owner/repo")
    args = parser.parse_args()

    sources = []
    if args.gitlab:
        sources.append(gitlab_source())
    if args.github:
        sources.append({"type": "github", "repo": args.repo})

    defines = {"DAYMARK_APP_VERSION": args.version}
    # 构建时间（issue #7）：UTC ISO8601，如 2026-08-15T07:30:00Z
    defines["DAYMARK_BUILD_TIME"] = datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    if sources:
        defines["DAYMARK_UPDATE_SOURCES_B64"] = base64.b64encode(
            json.dumps(sources).encode()
        ).decode()

    print(" ".join(f"--dart-define={k}={v}" for k, v in defines.items()))


if __name__ == "__main__":
    main()
