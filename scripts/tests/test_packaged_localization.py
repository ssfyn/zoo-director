"""在独立应用包中执行生产翻译代码，避免构建机资源路径掩盖打包故障。"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "需要 macOS 的应用包资源布局")
class PackagedLocalizationTests(unittest.TestCase):
    """验证应用标准资源目录及资源缺失时的启动回退行为。"""

    @classmethod
    def setUpClass(cls):
        """只编译生产翻译入口，禁止使用 SwiftPM 兜底路径或用户首选项。"""
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(__file__).resolve().parents[2]
        cls.directory = Path(cls.temporary.name)
        probe = cls.directory / "Probe.swift"
        probe.write_text('''import Foundation

/// 探针固定语言，不访问用户偏好。
@MainActor
enum LanguagePreferences {
    /// 满足生产翻译入口的语言偏好依赖。
    static let shared = Selection()
    /// 探针使用的只读偏好。
    struct Selection {
        /// 固定使用简体中文。
        let resolvedLanguage = "zh-Hans"
    }
}

extension Bundle {
    /// 应用包不能依赖构建目录或生成代码提供的资源兜底。
    static var module: Bundle { fatalError("不应访问 SwiftPM 构建路径") }
}

/// 在没有业务连接和界面的进程中加载真实语言目录。
@main
struct Probe {
    /// 输出目录数量和翻译结果，供外部断言。
    @MainActor
    static func main() {
        print(L10n.catalogs["en", default: [:]].count)
        print(L10n.catalogs["zh-Hans", default: [:]].count)
        print(L10n.text("Preferences…", language: "zh-Hans"))
    }
}
''')
        environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cls.directory / "cache"))
        subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
                        str(cls.root / "Sources/ZooDirector/Localization.swift"), str(probe),
                        "-o", str(cls.directory / "Probe")], env=environment, check=True,
                       capture_output=True, text=True, timeout=120)

    def run_app(self, include_resources):
        """将探针装入临时应用，从应用外启动且不提供构建目录资源。"""
        with tempfile.TemporaryDirectory(dir=self.directory) as temporary:
            contents = Path(temporary) / "Probe.app/Contents"
            (contents / "MacOS").mkdir(parents=True)
            executable = contents / "MacOS/Probe"
            shutil.copy2(self.directory / "Probe", executable)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "Probe", "CFBundleIdentifier": "test.zoodirector.localization",
                "CFBundlePackageType": "APPL",
            }))
            if include_resources:
                destination = contents / "Resources/ZooDirector_ZooDirector.bundle/Localization"
                shutil.copytree(self.root / "Sources/ZooDirector/Resources/Localization", destination)
            result = subprocess.run([str(executable)], cwd=temporary, capture_output=True,
                                    text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.splitlines()

    def test_packaged_catalogs_load_without_build_directory(self):
        """标准资源目录可独立加载两种完整语言，且中文翻译实际生效。"""
        english, chinese, translated = self.run_app(True)
        self.assertGreater(int(english), 200)
        self.assertEqual(english, chinese)
        self.assertEqual(translated, "首选项…")

    def test_missing_bundle_keeps_source_text(self):
        """资源包缺失时保留源文案，不触发 SwiftPM 的致命断言。"""
        self.assertEqual(self.run_app(False), ["0", "0", "Preferences…"])
