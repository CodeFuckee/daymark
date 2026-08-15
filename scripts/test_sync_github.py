#!/usr/bin/env python3
# test_sync_github.py — sync_github.py 仓库元信息同步功能的单元测试（issue #22）
#
# 契约：GitHub 仓库 About 栏信息（description / homepage / topics）无法用仓库
# 文件表达，必须经 GitHub REST API 设置；本测试验证：
#   1. sync_repo_metadata 正确调用 PATCH /repos/{repo}（description+homepage）
#      与 PUT /repos/{repo}/topics（names）
#   2. topics 配置满足 GitHub 规则（仅小写字母/数字/连字符、≤50 字符、≤20 个）
#   3. sync_metadata_safely 失败时仅告警上报（report_failure）、不抛异常，
#      不阻塞源码同步主流程
#
# 运行：cd scripts && python3 -m unittest test_sync_github -v
# 零第三方依赖（unittest + unittest.mock），与 CI python-test job 一致。

import unittest
from unittest import mock

import sync_github


class SyncRepoMetadataTest(unittest.TestCase):
    """sync_repo_metadata：About 栏信息设置的两条 API 调用及其参数"""

    def setUp(self):
        # 隔离网络：模块内所有 api() 调用一律走 mock，不产生真实 HTTP 请求
        patcher = mock.patch.object(sync_github, "api")
        self.api = patcher.start()
        self.addCleanup(patcher.stop)
        self.api.return_value = {}

    def test_正常流程设置description与homepage(self):
        sync_github.sync_repo_metadata()
        patch_calls = [
            c for c in self.api.call_args_list
            if c.args[:2] == ("PATCH", f"/repos/{sync_github.REPO}")
        ]
        self.assertEqual(len(patch_calls), 1, "应恰好调用一次 PATCH /repos/{repo}")
        body = patch_calls[0].args[2]
        self.assertEqual(body["description"], sync_github.REPO_DESCRIPTION)
        self.assertEqual(body["homepage"], sync_github.REPO_HOMEPAGE)

    def test_正常流程设置topics(self):
        sync_github.sync_repo_metadata()
        put_calls = [
            c for c in self.api.call_args_list
            if c.args[:2] == ("PUT", f"/repos/{sync_github.REPO}/topics")
        ]
        self.assertEqual(len(put_calls), 1, "应恰好调用一次 PUT /repos/{repo}/topics")
        self.assertEqual(put_calls[0].args[2], {"names": sync_github.REPO_TOPICS})

    def test_重复调用参数一致且幂等(self):
        """About 栏设置无状态、可重复执行：两次调用参数完全相同"""
        sync_github.sync_repo_metadata()
        sync_github.sync_repo_metadata()
        patch_calls = [
            c for c in self.api.call_args_list
            if c.args[:2] == ("PATCH", f"/repos/{sync_github.REPO}")
        ]
        self.assertEqual(len(patch_calls), 2)
        self.assertEqual(patch_calls[0].args, patch_calls[1].args)

    def test_description与homepage非空(self):
        self.assertTrue(sync_github.REPO_DESCRIPTION.strip())
        self.assertTrue(sync_github.REPO_HOMEPAGE.strip())

    def test_topics配置符合github规则(self):
        """GitHub topics 约束：≤20 个；每个仅小写字母/数字/连字符且 ≤50 字符"""
        self.assertLessEqual(len(sync_github.REPO_TOPICS), 20, "topics 最多 20 个")
        self.assertGreater(len(sync_github.REPO_TOPICS), 0, "topics 不能为空")
        for topic in sync_github.REPO_TOPICS:
            self.assertTrue(
                topic.replace("-", "").isalnum() and topic.islower(),
                f"非法 topic：{topic}（仅允许小写字母/数字/连字符）",
            )
            self.assertLessEqual(len(topic), 50, f"topic 超长：{topic}")

    def test_topics无重复(self):
        self.assertEqual(len(sync_github.REPO_TOPICS), len(set(sync_github.REPO_TOPICS)))


class SyncMetadataSafelyTest(unittest.TestCase):
    """sync_metadata_safely：元信息失败仅告警，不阻塞源码同步主流程"""

    def setUp(self):
        patcher = mock.patch.object(sync_github, "api")
        self.api = patcher.start()
        self.addCleanup(patcher.stop)
        self.api.return_value = {}

    def test_成功时不上报失败(self):
        with mock.patch.object(sync_github, "report_failure") as rf:
            sync_github.sync_metadata_safely()  # 不应抛异常
            rf.assert_not_called()

    def test_patch失败时告警上报但不抛出(self):
        def fail_patch(method, path, body=None, retries=3):
            if method == "PATCH":
                raise RuntimeError("GitHub API 403: 权限不足")
            return {}

        self.api.side_effect = fail_patch
        with mock.patch.object(sync_github, "report_failure") as rf:
            sync_github.sync_metadata_safely()  # 核心断言：不抛出
            rf.assert_called_once()

    def test_topics失败时告警上报但不抛出(self):
        def fail_topics(method, path, body=None, retries=3):
            if path.endswith("/topics"):
                raise RuntimeError("GitHub API 422: topics 校验失败")
            return {}

        self.api.side_effect = fail_topics
        with mock.patch.object(sync_github, "report_failure") as rf:
            sync_github.sync_metadata_safely()  # 不抛出
            rf.assert_called_once()

    def test_网络异常时告警上报但不抛出(self):
        self.api.side_effect = OSError("连接超时")
        with mock.patch.object(sync_github, "report_failure") as rf:
            sync_github.sync_metadata_safely()  # 不抛出
            rf.assert_called_once()


if __name__ == "__main__":
    unittest.main()
