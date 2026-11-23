"""验证商店构建号递增、记录恢复、手动覆盖和跨进程号码分配。"""
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


# 独立导入分配器，测试只写入临时目录，不预留项目的实际构建号。
SCRIPT = Path(__file__).resolve().parents[1] / "appstore-build-number.py"
SPEC = importlib.util.spec_from_file_location("appstore_build_number", SCRIPT)
NUMBERS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NUMBERS)


class BuildNumberTests(unittest.TestCase):
    """保证失败重试和并发分配不会自动复用本机已预留的号码。"""

    def test_preview_does_not_reserve_and_failed_builds_do_not_reuse(self):
        """预览不写文件，实际预留后即使未生成安装包也继续使用下一号。"""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "dist"
            self.assertEqual(NUMBERS.reserve_number(directory, peek=True), "1")
            self.assertFalse(directory.exists())
            self.assertEqual(NUMBERS.reserve_number(directory), "1")
            self.assertEqual(NUMBERS.reserve_number(directory), "2")
            self.assertEqual(NUMBERS.reserve_number(directory, peek=True), "3")

    def test_existing_packages_seed_first_automatic_build(self):
        """从用户已有的商店包接续递增，跨版本不把构建号重置为一。"""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in ["ZooDirector-1.0.0-2-appstore.pkg", "ZooDirector-2.0.0-1-appstore.pkg",
                         "ZooDirector-dev-invalid-appstore.pkg"]:
                (directory / name).touch()
            self.assertEqual(NUMBERS.reserve_number(directory), "3")

    def test_manual_numbers_preserve_history_floor(self):
        """显式构建号保留原值，但手动回退不能拉低后续自动号码。"""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.assertEqual(NUMBERS.reserve_number(directory, "42.1"), "42.1")
            self.assertEqual(NUMBERS.reserve_number(directory), "43")
            self.assertEqual(NUMBERS.reserve_number(directory, "1"), "1")
            self.assertEqual(NUMBERS.reserve_number(directory), "44")

    def test_store_app_cache_survives_missing_distribution_directory(self):
        """分发目录丢失时参考商店应用清单，忽略其他渠道的构建号。"""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for architecture, channel, number in [("arm64", "appstore", "2"), ("x86_64", "github", "99")]:
                path = root / f".build/apps/{architecture}/ZooDirector.app/Contents/Info.plist"
                path.parent.mkdir(parents=True)
                path.write_bytes(plistlib.dumps({"ZooDirectorDistributionChannel": channel, "CFBundleVersion": number}))
            self.assertEqual(NUMBERS.reserve_number(root / "dist"), "3")

    def test_corrupt_invalid_or_exhausted_records_stop_without_overwriting(self):
        """记录损坏或格式溢出时停止，不能静默重置并产生重复号码。"""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            record = directory / ".appstore-build-number"
            for value in ["invalid", "9999"]:
                record.write_text(value)
                with self.assertRaises(ValueError):
                    NUMBERS.reserve_number(directory)
                self.assertEqual(record.read_text(), value)
            record.unlink()
            with self.assertRaises(ValueError):
                NUMBERS.reserve_number(directory, "$(not-a-build)")
            self.assertFalse(record.exists())

    def reserve_in_process(self, directory):
        """每个独立进程通过真实命令入口预留号码，覆盖文件锁而非内存锁。"""
        environment = dict(os.environ)
        environment.pop("BUILD_NUMBER", None)
        return subprocess.check_output(["python3", str(SCRIPT), "--directory", str(directory)],
                                       env=environment, text=True).strip()

    def test_parallel_processes_reserve_unique_numbers(self):
        """同时预留的六个进程必须拿到连续且互不相同的号码。"""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "dist"
            with ThreadPoolExecutor(max_workers=6) as pool:
                values = list(pool.map(self.reserve_in_process, [directory] * 6))
            self.assertEqual(sorted(map(int, values)), list(range(1, 7)))
            self.assertEqual(NUMBERS.reserve_number(directory, peek=True), "7")


if __name__ == "__main__":
    unittest.main()
