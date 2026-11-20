"""验证发布参数、草稿流程和临时签名凭据清理，不读取真实账户凭据。"""
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch, call


def module(name):
    """从含横线的脚本路径加载模块，避免脚本导入时执行发布动作。"""
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / (name + ".py"))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


# 被测脚本只在显式运行时操作应用或钥匙串。
metadata = module("build-metadata")
release = module("prepare-release")
signing = module("ci-signing")


class ReleaseTests(unittest.TestCase):
    """覆盖本地开发、发行版本、重复上传及失败保护。"""

    def test_default_dev_and_formal_metadata(self):
        """本地默认 dev，预发布展示值与 Apple 数字字段分别保存。"""
        local = metadata.metadata({})
        self.assertEqual(local["ZooDirectorDisplayVersion"], "dev")
        self.assertEqual(local["CFBundleShortVersionString"], "0.0.0")
        formal = metadata.metadata({"APP_VERSION": "1.2.3-beta.1", "BUILD_NUMBER": "42.2", "DISTRIBUTION_CHANNEL": "github"})
        self.assertEqual(formal["ZooDirectorDisplayVersion"], "1.2.3-beta.1")
        self.assertEqual(formal["CFBundleShortVersionString"], "1.2.3")
        self.assertEqual(formal["CFBundleVersion"], "42.2")
        store = metadata.metadata({"APP_VERSION": "1.2.3", "DISTRIBUTION_CHANNEL": "appstore"})
        self.assertEqual(store["ZooDirectorDistributionChannel"], "appstore")

    def test_reject_invalid_versions_before_build(self):
        """非法标签、版本和构建号均拒绝进入耗时构建与签名阶段。"""
        cases = [{"APP_VERSION": value} for value in ["v1.0.0", "1.0", "01.0.0", "1.0.0/a", "1.0.0\nx=1"]]
        cases += [{"BUILD_NUMBER": value} for value in ["0", "10000", "1.123", "1.a", "$(echo secret)"]]
        cases += [{"DISTRIBUTION_CHANNEL": "other"}, {"DISTRIBUTION_CHANNEL": "github"},
                  {"APP_VERSION": "1.0.0-beta", "DISTRIBUTION_CHANNEL": "appstore"}]
        for environment in cases:
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                metadata.metadata(environment)
        with self.assertRaises(ValueError):
            release.release_values("main", "1", "1")
        values = release.release_values("v1.0.0", "42", "2")
        self.assertEqual(values["BUILD_NUMBER"], "42.2")

    def test_plist_write_keeps_identity_and_resources(self):
        """真实执行清单更新只修改版本键，保留应用标识及其他资源设置。"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "Info.plist"
            path.write_bytes(plistlib.dumps({"CFBundleIdentifier": "fan.yanan.zoodirector", "CFBundleIconFile": "ZooDirector.icns"}))
            env = dict(os.environ, APP_VERSION="1.0.0", BUILD_NUMBER="42.1", DISTRIBUTION_CHANNEL="github")
            subprocess.run(["python3", str(Path(metadata.__file__)), str(path)], env=env, check=True)
            result = plistlib.loads(path.read_bytes())
            self.assertEqual(result["CFBundleIdentifier"], "fan.yanan.zoodirector")
            self.assertEqual(result["CFBundleIconFile"], "ZooDirector.icns")
            self.assertEqual(result["CFBundleShortVersionString"], "1.0.0")
            self.assertEqual(result["ZooDirectorDisplayVersion"], "1.0.0")

    def test_release_preflight_never_uses_credentials_for_invalid_channel(self):
        """版本非法或选择未实现的商店渠道时，在访问钥匙串之前立即失败。"""
        script = Path(__file__).resolve().parents[1] / "release-app.sh"
        for version, channel, message in [("bad", "github", "APP_VERSION"), ("1.0.0", "appstore", "App Store")]:
            env = dict(os.environ, GITHUB_ACTIONS="true", APP_VERSION=version, DISTRIBUTION_CHANNEL=channel, BUILD_NUMBER="1")
            result = subprocess.run(["zsh", str(script), "arm64"], env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
            self.assertNotIn("Developer ID Application 身份", result.stderr)

    def test_published_draft_and_immutable_release(self):
        """草稿构建完成后再发布会跳过重复构建，不修改已锁定的资产。"""
        complete = {"assets": [{"name": f"ZooDirector-1.0.0-{arch}.dmg"} for arch in ["arm64", "x86_64"]]}
        self.assertTrue(release.should_build("workflow_dispatch", None, "1.0.0"))
        self.assertFalse(release.should_build("release", complete, "1.0.0"))
        self.assertTrue(release.should_build("workflow_dispatch", complete, "1.0.0"))
        self.assertFalse(release.should_build("workflow_dispatch", dict(complete, immutable=True), "1.0.0"))
        with self.assertRaises(ValueError):
            release.should_build("release", {"immutable": True, "assets": []}, "1.0.0")

    def test_signing_credentials_use_temporary_keychain(self):
        """凭据仅进入任务目录，导入成功后删除原始文件，清理时恢复搜索列表。"""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "signing"
            env = {name: "test-only" for name in ["MACOS_CERTIFICATE_PASSWORD", "SIGNING_IDENTITY", "APPLE_API_KEY_ID", "APPLE_API_ISSUER_ID"]}
            env.update(MACOS_CERTIFICATE_P12_BASE64=base64.b64encode(b"test-certificate").decode(),
                       APPLE_API_KEY_P8_BASE64=base64.b64encode(b"test-api-key").decode(), GITHUB_ENV=str(Path(temporary) / "environment"))
            with patch.dict(os.environ, env, clear=True), patch.object(signing, "run") as run:
                with patch.object(signing.subprocess, "check_output", return_value='"/original/login.keychain-db"\n'):
                    signing.setup(directory)
                self.assertFalse((directory / "notary.p8").exists())
                self.assertFalse((directory / "certificate.p12").exists())
                exported = Path(env["GITHUB_ENV"]).read_text()
                self.assertNotIn("test-only", exported)
                self.assertIn("NOTARY_KEYCHAIN=", exported)
                signing.cleanup(directory)
                self.assertFalse(directory.exists())
                self.assertIn(call("security", "list-keychains", "-d", "user", "-s", "/original/login.keychain-db"), run.call_args_list)

    def test_signing_failure_does_not_print_password(self):
        """安全工具失败时不把包含私钥口令的完整命令加入异常文本。"""
        failure = subprocess.CalledProcessError(1, ["security", "-P", "test-secret"])
        with patch.object(signing.subprocess, "run", side_effect=failure):
            with self.assertRaises(ValueError) as caught:
                signing.run("security", "-P", "test-secret")
            self.assertNotIn("test-secret", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
