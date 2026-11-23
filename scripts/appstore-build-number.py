#!/usr/bin/env python3
"""为本机商店构建预留递增号码，参考已有产物并保留手动指定能力。"""
import argparse
import fcntl
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import tempfile


# 复用版本元信息模块的格式校验，避免生成无法签入应用的构建号。
SPEC = importlib.util.spec_from_file_location("build_metadata", Path(__file__).with_name("build-metadata.py"))
METADATA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METADATA)


def number_tuple(value):
    """将有效构建号补齐为三段数字，用于比较和保存历史上界。"""
    if not METADATA.BUILD_PATTERN.fullmatch(value):
        raise ValueError("本地构建号记录或 BUILD_NUMBER 无效，请使用如 3、42.1 的 Apple 构建号。")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def known_numbers(directory):
    """读取本机记录、已有商店包及商店应用清单，不访问苹果账号。"""
    numbers = [(0, 0, 0)]
    record = directory / ".appstore-build-number"
    if record.exists():
        numbers.append(number_tuple(record.read_text().strip()))
    for package in directory.glob("ZooDirector-*-appstore.pkg"):
        match = re.fullmatch(r"ZooDirector-.+-([0-9.]+)-appstore\.pkg", package.name)
        if match and METADATA.BUILD_PATTERN.fullmatch(match[1]):
            numbers.append(number_tuple(match[1]))
    for path in (directory.parent / ".build/apps").glob("*/ZooDirector.app/Contents/Info.plist"):
        info = plistlib.loads(path.read_bytes())
        if info.get("ZooDirectorDistributionChannel") == "appstore":
            numbers.append(number_tuple(info["CFBundleVersion"]))
    return numbers


def plan_number(numbers, explicit):
    """默认使用比本机历史更高的整数；显式指定时保持调用方的值。"""
    if explicit is not None:
        number_tuple(explicit)
        return explicit
    value = str(max(numbers)[0] + 1)
    if not METADATA.BUILD_PATTERN.fullmatch(value):
        raise ValueError("自动构建号已超出当前格式上限，请显式指定更高且符合 Apple 格式的 BUILD_NUMBER。")
    return value


def reserve_number(directory, explicit=None, peek=False):
    """加锁并原子保存历史上界，失败的构建也不回收已预留号码。"""
    if peek:
        return plan_number(known_numbers(directory), explicit)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".appstore-build-number.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        numbers = known_numbers(directory)
        planned = plan_number(numbers, explicit)
        # 手动重建旧号码不会使后续自动号码倒退。
        highest = max([*numbers, number_tuple(planned)])
        descriptor, temporary = tempfile.mkstemp(prefix=".appstore-build-number-", dir=directory)
        try:
            with os.fdopen(descriptor, "w") as stream:
                stream.write(".".join(map(str, highest)) + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, directory / ".appstore-build-number")
        finally:
            Path(temporary).unlink(missing_ok=True)
        return planned


def main():
    """输出单个构建号供打包脚本导出，预览模式不创建或更改任何记录。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path("dist"))
    parser.add_argument("--peek", action="store_true")
    args = parser.parse_args()
    print(reserve_number(args.directory, os.environ.get("BUILD_NUMBER"), args.peek))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error))
