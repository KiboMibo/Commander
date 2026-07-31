#!/usr/bin/env python3
"""Покрытие изменённых строк: пересекает git diff с отчётом о покрытии.

Общий процент по репозиторию почти ничего не говорит о свежем коде — он
меняется на доли и одинаково выглядит и когда новый модуль покрыт полностью,
и когда он не покрыт вовсе. Этот скрипт считает то, что действительно
относится к текущей работе: какая доля изменённых исполняемых строк покрыта
тестами, и какие именно строки остались без покрытия.

Поддерживаемые форматы (определяются автоматически):
  lcov.info        — Vitest, Jest, c8, istanbul
  coverage.xml     — Cobertura: pytest-cov, coverage.py, JaCoCo-подобные
  coverage.json    — coverage.py --cov-report=json
  *.out / *.cov    — go test -coverprofile

Примеры:
  python diff_coverage.py --coverage coverage/lcov.info --base origin/main --min 80
  python diff_coverage.py --coverage coverage.xml --base HEAD~1 --json summary.json
  python diff_coverage.py --coverage coverage.out --staged

Код возврата: 0 — порог взят (или не задан), 1 — не взят, 2 — ошибка запуска.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------- git


def run_git(args: list[str], repo: Path) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def repo_root(start: Path) -> Path:
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=start,
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        raise RuntimeError("не git-репозиторий: не могу определить изменённые строки")
    return Path(out.stdout.strip())


def merge_base(base: str, repo: Path) -> str:
    """Точка расхождения с базовой веткой.

    Сравнение с веткой напрямую показало бы и чужие изменения, приехавшие
    в base после ветвления, — они не наша ответственность.
    """
    try:
        return run_git(["merge-base", "HEAD", base], repo).strip()
    except RuntimeError:
        return base


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def changed_lines(repo: Path, base: str | None, staged: bool) -> dict[str, set[int]]:
    """{путь относительно корня репозитория: {номера добавленных/изменённых строк}}.

    Удалённые строки не учитываем: покрывать нечего.
    """
    if staged:
        args = ["diff", "--cached", "--unified=0", "--no-color", "--diff-filter=ACMR"]
    elif base:
        args = [
            "diff", merge_base(base, repo), "--unified=0", "--no-color",
            "--diff-filter=ACMR",
        ]
    else:
        args = ["diff", "HEAD", "--unified=0", "--no-color", "--diff-filter=ACMR"]

    diff = run_git(args, repo)
    result: dict[str, set[int]] = defaultdict(set)
    current: str | None = None

    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[4:].strip()
            current = None if path == "/dev/null" else path[2:] if path.startswith("b/") else path
        elif line.startswith("@@") and current:
            m = HUNK_RE.match(line)
            if m:
                start = int(m.group(1))
                count = int(m.group(2) or 1)
                result[current].update(range(start, start + count))
    return {k: v for k, v in result.items() if v}


# ---------------------------------------------------------------- парсеры покрытия


def parse_lcov(path: Path) -> dict[str, dict[int, int]]:
    files: dict[str, dict[int, int]] = {}
    current: str | None = None
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("SF:"):
            current = line[3:]
            files.setdefault(current, {})
        elif line.startswith("DA:") and current:
            body = line[3:].split(",")
            if len(body) >= 2:
                try:
                    files[current][int(body[0])] = int(float(body[1]))
                except ValueError:
                    continue
        elif line == "end_of_record":
            current = None
    return files


def parse_cobertura(path: Path) -> dict[str, dict[int, int]]:
    root = ET.parse(path).getroot()
    sources = [s.text.strip() for s in root.findall("./sources/source") if s.text]
    files: dict[str, dict[int, int]] = {}
    for cls in root.iter("class"):
        filename = cls.get("filename")
        if not filename:
            continue
        # Cobertura хранит путь относительно <source>; берём оба варианта,
        # сопоставление всё равно идёт по суффиксу.
        candidates = [filename] + [os.path.join(s, filename) for s in sources]
        lines: dict[int, int] = {}
        for ln in cls.iter("line"):
            number, hits = ln.get("number"), ln.get("hits")
            if number is None or hits is None:
                continue
            try:
                lines[int(number)] = int(float(hits))
            except ValueError:
                continue
        for cand in candidates:
            files.setdefault(cand, {}).update(lines)
    return files


def parse_coverage_json(path: Path) -> dict[str, dict[int, int]]:
    data = json.loads(path.read_text())
    files: dict[str, dict[int, int]] = {}
    for name, info in (data.get("files") or {}).items():
        lines = {int(n): 1 for n in info.get("executed_lines", [])}
        lines.update({int(n): 0 for n in info.get("missing_lines", [])})
        files[name] = lines
    return files


GO_LINE_RE = re.compile(r"^(.+):(\d+)\.\d+,(\d+)\.\d+ \d+ (\d+)$")


def parse_go_profile(path: Path) -> dict[str, dict[int, int]]:
    files: dict[str, dict[int, int]] = defaultdict(dict)
    for raw in path.read_text(errors="replace").splitlines():
        if raw.startswith("mode:") or not raw.strip():
            continue
        m = GO_LINE_RE.match(raw.strip())
        if not m:
            continue
        name, start, end, count = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
        block = files[name]
        for ln in range(start, end + 1):
            block[ln] = max(block.get(ln, 0), count)
    return dict(files)


def load_coverage(path: Path) -> tuple[dict[str, dict[int, int]], str]:
    name = path.name.lower()
    head = path.read_text(errors="replace")[:400].lstrip()

    if name.endswith(".xml") or head.startswith("<?xml") or head.startswith("<coverage"):
        return parse_cobertura(path), "cobertura"
    if name.endswith(".json") or head.startswith("{"):
        return parse_coverage_json(path), "coverage.py json"
    if head.startswith("mode:") or name.endswith((".out", ".cov")):
        return parse_go_profile(path), "go coverprofile"
    if "SF:" in head or name.endswith(".info"):
        return parse_lcov(path), "lcov"
    raise RuntimeError(f"не удалось определить формат отчёта о покрытии: {path}")


# ---------------------------------------------------------------- сопоставление путей


def build_index(coverage: dict[str, dict[int, int]], repo: Path) -> dict[str, str]:
    """Ключ покрытия → путь относительно корня репозитория.

    Инструменты пишут пути по-разному: абсолютные, относительные к пакету,
    с префиксом модуля Go. Сопоставляем по самому длинному общему суффиксу
    из сегментов пути — это устойчиво ко всем трём случаям.
    """
    index: dict[str, str] = {}
    for key in coverage:
        norm = key.replace("\\", "/")
        try:
            rel = os.path.relpath(os.path.realpath(os.path.join(repo, norm)), repo)
        except ValueError:
            rel = norm
        if not rel.startswith(".."):
            index.setdefault(rel.replace("\\", "/"), key)
    return index


def match_path(changed: str, coverage: dict[str, dict[int, int]], index: dict[str, str]) -> str | None:
    if changed in index:
        return index[changed]
    changed_parts = changed.split("/")
    best_key, best_score = None, 0
    for key in coverage:
        parts = key.replace("\\", "/").split("/")
        score = 0
        for a, b in zip(reversed(changed_parts), reversed(parts)):
            if a != b:
                break
            score += 1
        if score > best_score:
            best_key, best_score = key, score
    return best_key if best_score > 0 else None


# ---------------------------------------------------------------- отчёт


def compress(numbers: list[int]) -> str:
    """[3,4,5,9] -> '3-5, 9' — так список непокрытых строк читается глазами."""
    if not numbers:
        return ""
    numbers = sorted(numbers)
    spans, start, prev = [], numbers[0], numbers[0]
    for n in numbers[1:]:
        if n == prev + 1:
            prev = n
            continue
        spans.append((start, prev))
        start = prev = n
    spans.append((start, prev))
    return ", ".join(str(a) if a == b else f"{a}-{b}" for a, b in spans)


def main() -> int:
    ap = argparse.ArgumentParser(description="Покрытие изменённых строк по git diff.")
    ap.add_argument("--coverage", required=True, help="файл отчёта о покрытии")
    ap.add_argument("--base", help="базовая ветка или ревизия (например origin/main)")
    ap.add_argument("--staged", action="store_true", help="брать staged-изменения вместо diff с base")
    ap.add_argument("--min", type=float, default=None, help="порог в процентах, например 80")
    ap.add_argument("--json", dest="json_out", help="сохранить сводку в JSON")
    ap.add_argument("--repo", default=".", help="путь к репозиторию (по умолчанию текущий)")
    ap.add_argument("--include", nargs="*", default=None,
                    help="ограничить файлами (пути относительно корня репозитория)")
    args = ap.parse_args()

    try:
        repo = repo_root(Path(args.repo).resolve())
        coverage, fmt = load_coverage(Path(args.coverage))
        changed = changed_lines(repo, args.base, args.staged)
    except (RuntimeError, OSError, ET.ParseError, json.JSONDecodeError) as exc:
        print(f"ошибка: {exc}", file=sys.stderr)
        return 2

    if args.include:
        allowed = set(args.include)
        changed = {k: v for k, v in changed.items() if k in allowed}

    index = build_index(coverage, repo)

    per_file, total_changed, total_covered = [], 0, 0
    unmatched = []

    for path in sorted(changed):
        key = match_path(path, coverage, index)
        if key is None:
            unmatched.append(path)
            continue
        lines = coverage[key]
        relevant = sorted(changed[path] & lines.keys())
        if not relevant:
            continue
        covered = [n for n in relevant if lines[n] > 0]
        uncovered = [n for n in relevant if lines[n] == 0]
        total_changed += len(relevant)
        total_covered += len(covered)
        per_file.append({
            "file": path,
            "changed_lines": len(relevant),
            "covered": len(covered),
            "pct": round(100 * len(covered) / len(relevant), 1),
            "uncovered_lines": uncovered,
        })

    pct = round(100 * total_covered / total_changed, 1) if total_changed else None

    print(f"Формат отчёта: {fmt}")
    print(f"Изменённых исполняемых строк: {total_changed}\n")
    for row in sorted(per_file, key=lambda r: r["pct"]):
        line = f"  {row['pct']:5.1f}%  {row['file']}  ({row['covered']}/{row['changed_lines']})"
        if row["uncovered_lines"]:
            line += f"  непокрыто: {compress(row['uncovered_lines'])}"
        print(line)

    if unmatched:
        print("\nНе нашлось в отчёте о покрытии (тесты, конфиги, неисполняемые файлы —"
              " либо код, который не участвовал в прогоне):")
        for path in unmatched:
            print(f"  {path}")

    if pct is None:
        print("\nИзменённых строк, которые отслеживает покрытие, нет — считать нечего.")
        verdict = None
    else:
        print(f"\nПокрытие изменённых строк: {pct}%", end="")
        if args.min is not None:
            verdict = pct >= args.min
            print(f"  (порог {args.min}%: {'взят' if verdict else 'НЕ взят'})")
        else:
            verdict = None
            print()

    if args.json_out:
        Path(args.json_out).write_text(json.dumps({
            "format": fmt,
            "changed_lines": total_changed,
            "covered_lines": total_covered,
            "changed_lines_pct": pct,
            "threshold": args.min,
            "threshold_met": verdict,
            "files": per_file,
            "unmatched_files": unmatched,
        }, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"Сводка сохранена: {args.json_out}")

    return 1 if verdict is False else 0


if __name__ == "__main__":
    sys.exit(main())
