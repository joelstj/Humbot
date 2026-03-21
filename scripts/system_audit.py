#!/usr/bin/env python3
import argparse
import importlib.util
import json
import os
import platform
import shutil
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, List


REQUIRED_PATHS = [
    "hummingbot",
    "hummingbot/core",
    "hummingbot/strategy_v2",
    "hummingbot/client",
    "scripts",
    "test",
]

REQUIRED_COMMANDS = [
    "python3",
    "git",
]

REQUIRED_PYTHON_MODULES = [
    "asyncio",
    "decimal",
    "json",
]

OPTIONAL_PYTHON_MODULES = [
    "pytest",
    "pandas",
]


@dataclass
class CheckResult:
    name: str
    passed: bool
    detail: str


def _module_available(module_name: str) -> bool:
    return importlib.util.find_spec(module_name) is not None


def _run_checks(root: Path) -> List[CheckResult]:
    results: List[CheckResult] = []

    for rel_path in REQUIRED_PATHS:
        full_path = root / rel_path
        results.append(
            CheckResult(
                name=f"path:{rel_path}",
                passed=full_path.exists(),
                detail=str(full_path),
            )
        )

    for command_name in REQUIRED_COMMANDS:
        resolved = shutil.which(command_name)
        results.append(
            CheckResult(
                name=f"command:{command_name}",
                passed=resolved is not None,
                detail=resolved or "not found",
            )
        )

    for module_name in REQUIRED_PYTHON_MODULES:
        is_available = _module_available(module_name)
        results.append(
            CheckResult(
                name=f"module:{module_name}",
                passed=is_available,
                detail="available" if is_available else "missing",
            )
        )

    for module_name in OPTIONAL_PYTHON_MODULES:
        is_available = _module_available(module_name)
        results.append(
            CheckResult(
                name=f"optional_module:{module_name}",
                passed=is_available,
                detail="available" if is_available else "missing (optional)",
            )
        )

    return results


def _render_human_report(results: List[CheckResult], root: Path) -> str:
    passed_count = sum(1 for result in results if result.passed)
    lines = [
        "Hummingbot System Audit Report",
        f"Repository root: {root}",
        f"OS: {platform.system()} {platform.release()}",
        f"Python: {platform.python_version()} ({sys.executable})",
        f"Checks passed: {passed_count}/{len(results)}",
        "",
    ]
    for result in results:
        status = "PASS" if result.passed else "FAIL"
        lines.append(f"[{status}] {result.name} -> {result.detail}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Run a local system audit for Hummingbot components.")
    parser.add_argument(
        "--check",
        action="store_true",
        help="Return non-zero exit code if any required check fails (optional checks do not fail).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print report in JSON format.",
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    results = _run_checks(root)

    if args.json:
        payload: Dict[str, object] = {
            "root": str(root),
            "results": [asdict(result) for result in results],
        }
        print(json.dumps(payload, indent=2))
    else:
        print(_render_human_report(results, root))

    if args.check:
        required_failures = [r for r in results if (not r.passed and not r.name.startswith("optional_module:"))]
        if required_failures:
            sys.exit(1)


if __name__ == "__main__":
    main()
