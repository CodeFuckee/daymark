#!/usr/bin/env python3
# update_defines.py — 生成自动更新 dart-define 参数（issue #5）
#
# 打包时将更新源地址写入软件（--dart-define），stdout 输出参数串（空格分隔）：
#   --dart-define=DAYMARK_APP_VERSION=0.1.3 --dart-define=DAYMARK_UPDATE_SOURCES_B64=...
#
# 用法:
#   python3 scripts/update_defines.py --version X.Y.Z [--gitlab | --github] [--repo owner/repo]
#
# 源 JSON 结构（应用内 UpdateConfig.parse 解析，base64 避免转义问题）:
#   [{"type":"gitlab","api":"https://host/api/v4","project":"ns%2Fproj","token":"..."}]
#   [{"type":"github","repo":"owner/repo"}]
#
# GitLab 源自动取 CI 环境（CI_SERVER_URL/CI_PROJECT_PATH）；token 从
# GITLAB_READ_API_TOKEN 读取（只读 token，private 仓库 release 检测必需）。

import argparse
import base64
import json
import os
import urllib.parse


def gitlab_source():
    host = os.environ.get("CI_SERVER_URL", "").rstrip("/")
    path = os.environ.get("CI_PROJECT_PATH", "")
    token = os.environ.get("GITLAB_READ_API_TOKEN", "")
    if not host or not path:
        raise SystemExit("--gitlab 需要 CI_SERVER_URL / CI_PROJECT_PATH 环境变量")
    return {
        "type": "gitlab",
        "api": f"{host}/api/v4",
        "project": urllib.parse.quote(path, safe=""),
        "token": token,
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
    if sources:
        defines["DAYMARK_UPDATE_SOURCES_B64"] = base64.b64encode(
            json.dumps(sources).encode()
        ).decode()

    print(" ".join(f"--dart-define={k}={v}" for k, v in defines.items()))


if __name__ == "__main__":
    main()
