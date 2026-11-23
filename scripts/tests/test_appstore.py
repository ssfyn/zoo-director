"""验证商店签名的团队隔离、描述文件约束和显式上传，不使用真实凭据。"""
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


# 商店签名模块仅在显式调用主函数时操作本机钥匙串。
SCRIPT_DIRECTORY = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("appstore_signing", SCRIPT_DIRECTORY / "appstore-signing.py")
SIGNING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNING)


class AppStoreTests(unittest.TestCase):
    """覆盖混用团队、误用站外证书、错误描述文件和默认禁止上传。"""

    def certificate(self, name="Apple Distribution: Tester (ABCDEFGHIJ)"):
        """生成只包含公开字段的测试签名身份。"""
        return {"name": name, "sha1": hashlib.sha1(b"fixture-certificate").hexdigest().upper()}

    def profile(self):
        """生成显式匹配应用与证书的测试描述文件，不包含真实签名。"""
        return {"ExpirationDate": datetime.now(timezone.utc) + timedelta(days=1), "Platform": ["OSX"],
                "TeamIdentifier": ["ABCDEFGHIJ"], "ApplicationIdentifierPrefix": ["ABCDEFGHIJ"],
                "DeveloperCertificates": [b"fixture-certificate"], "Entitlements": {
                    "com.apple.application-identifier": "ABCDEFGHIJ.fan.yanan.zoodirector",
                    "com.apple.developer.team-identifier": "ABCDEFGHIJ", "beta-reports-active": True}}

    def test_identity_requires_unique_store_certificate(self):
        """站外证书不能用于商店，多个候选必须显式选择完整名称或指纹。"""
        certificate = self.certificate()
        prefixes = ("Apple Distribution: ",)
        selected = SIGNING.choose_identity([certificate], certificate["sha1"], prefixes, "应用")
        self.assertEqual(selected, certificate)
        for candidates in [[], [self.certificate("Developer ID Application: Tester (ABCDEFGHIJ)")],
                           [certificate, self.certificate("Apple Distribution: Other (1234567890)")]]:
            with self.assertRaises(ValueError):
                SIGNING.choose_identity(candidates, "", prefixes, "应用")

    def test_reject_mismatched_certificate_teams(self):
        """即使两个身份均有效，也不能把不同团队的证书签进同一个发布包。"""
        app = self.certificate()
        installer = self.certificate("3rd Party Mac Developer Installer: Other (1234567890)")
        with tempfile.TemporaryDirectory() as temporary, patch.object(SIGNING, "identities", side_effect=[[app], [installer]]):
            with self.assertRaises(ValueError):
                SIGNING.prepare(Path(temporary), {})
            self.assertFalse((Path(temporary) / "signing.json").exists())

    def test_optional_profile_keeps_shared_sandbox(self):
        """无受限权限时不额外引入描述文件依赖，主应用保持共用沙箱配置。"""
        app = self.certificate()
        installer = self.certificate("3rd Party Mac Developer Installer: Tester (ABCDEFGHIJ)")
        with tempfile.TemporaryDirectory() as temporary, patch.object(SIGNING, "identities", side_effect=[[app], [installer]]):
            directory = Path(temporary)
            SIGNING.prepare(directory, {})
            actual = plistlib.loads((directory / "appstore.entitlements").read_bytes())
            expected = plistlib.loads((SCRIPT_DIRECTORY.parent / "Resources/ZooDirector.entitlements").read_bytes())
            self.assertEqual(actual, expected)
            self.assertNotIn("get-task-allow", actual)

    def test_profile_binds_application_team_and_certificate(self):
        """有效描述文件只能补充自身授权的应用标识、团队及测试报告权限。"""
        result = SIGNING.profile_entitlements(self.profile(), "ABCDEFGHIJ", self.certificate(), "fan.yanan.zoodirector")
        self.assertEqual(result["com.apple.application-identifier"], "ABCDEFGHIJ.fan.yanan.zoodirector")
        self.assertTrue(result["beta-reports-active"])
        self.assertNotIn("get-task-allow", result)

    def test_profile_rejects_wrong_platform_expiry_and_distribution(self):
        """开发、站外、过期和不匹配的描述文件都必须在构建前拒绝。"""
        cases = [{"ExpirationDate": datetime.now(timezone.utc) - timedelta(seconds=1)}, {"Platform": ["iOS"]},
                 {"TeamIdentifier": ["OTHERTEAM0"]}, {"ProvisionedDevices": []},
                 {"ProvisionsAllDevices": True}, {"DeveloperCertificates": [b"other-certificate"]},
                 {"Entitlements": {"com.apple.application-identifier": "ABCDEFGHIJ.*"}}]
        for updates in cases:
            with self.subTest(updates=updates), self.assertRaises(ValueError):
                SIGNING.profile_entitlements(dict(self.profile(), **updates), "ABCDEFGHIJ", self.certificate(),
                                               "fan.yanan.zoodirector")

    def run_uploader(self, mode, fail_validation=False):
        """通过受控命令记录操作顺序，不调用苹果服务或读取真实钥匙串。"""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            calls = directory / "calls"
            stub = directory / "stub"
            stub.write_text('''#!/bin/zsh
set -eu
if [[ "${0:t}" == xcrun && "$2" == --help ]]; then print -- --upload-package; exit 0; fi
print -r -- "${0:t} $*" >> "$CALLS"
if [[ "$FAIL_VALIDATION" == 1 && "${2:-}" == --validate-app ]]; then exit 1; fi
''')
            stub.chmod(0o755)
            for name in ["xcrun", "pkgutil", "open"]:
                (directory / name).symlink_to(stub)
            package = directory / "test appstore.pkg"
            package.write_text("test-only")
            env = dict(os.environ, PATH=str(directory) + ":" + os.environ["PATH"], GITHUB_ACTIONS="true",
                       CALLS=str(calls), APPSTORE_APPLE_ID="fixture@example.invalid", APPSTORE_PASSWORD_ITEM="fixture-item",
                       FAIL_VALIDATION="1" if fail_validation else "0")
            env.pop("APPSTORE_PROVIDER_ID", None)
            result = subprocess.run(["zsh", str(SCRIPT_DIRECTORY / "upload-appstore.sh"), *mode, str(package)],
                                    env=env, capture_output=True, text=True)
            return result.returncode, calls.read_text()

    def test_validation_is_default_and_upload_is_explicit(self):
        """默认只校验；显式上传必须先校验成功，且参数只引用钥匙串条目。"""
        code, calls = self.run_uploader([])
        self.assertEqual(code, 0)
        self.assertIn("--validate-app", calls)
        self.assertNotIn("--upload-package", calls)
        code, calls = self.run_uploader(["--upload"])
        self.assertEqual(code, 0)
        self.assertLess(calls.index("--validate-app"), calls.index("--upload-package"))
        self.assertIn("@keychain:fixture-item", calls)
        code, calls = self.run_uploader(["--upload"], fail_validation=True)
        self.assertNotEqual(code, 0)
        self.assertNotIn("--upload-package", calls)

    def test_transporter_does_not_invoke_command_line_upload(self):
        """图形交付入口只打开本地包，是否交付由用户在应用中决定。"""
        code, calls = self.run_uploader(["--transporter"])
        self.assertEqual(code, 0)
        self.assertIn("open -a Transporter", calls)
        self.assertNotIn("xcrun", calls)


if __name__ == "__main__":
    unittest.main()
