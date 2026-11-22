#!/usr/bin/env python3
"""Release tooling, verification, and CI orchestration for Synurang."""

from __future__ import annotations

import argparse
import base64
import datetime
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass
from pathlib import Path
from urllib import parse as urllib_parse

ROOT = Path(__file__).resolve().parent.parent

CANONICAL_BINARY = "protoc-gen-synurang-ffi"
MAVEN_GROUP_ID = "io.github.ivere27"
MAVEN_UPLOAD_URL = "https://central.sonatype.com/api/v1/publisher/upload"
MAVEN_STATUS_URL = "https://central.sonatype.com/api/v1/publisher/status"
MAVEN_PUBLISHING_TYPES = ("AUTOMATIC", "USER_MANAGED")
DEFAULT_MAVEN_POLL_INTERVAL = 15.0
DEFAULT_MAVEN_POLL_TIMEOUT = 1200.0
DEFAULT_SOURCE_DATE_EPOCH = 315532800

DEFAULT_CODEGEN_TARGETS = (
    "x86_64-unknown-linux-musl",
    "aarch64-unknown-linux-musl",
    "x86_64-pc-windows-msvc",
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
)

ALL_SUPPORTED_CODEGEN_TARGETS = (
    *DEFAULT_CODEGEN_TARGETS,
    "x86_64-pc-windows-gnu",
)

DESKTOP_JNI_PATHS = (
    "native/linux-x86_64/libsynurang_jni.so",
    "native/linux-x86/libsynurang_jni.so",
    "native/linux-armv7/libsynurang_jni.so",
    "native/linux-aarch64/libsynurang_jni.so",
    "native/windows-x86_64/synurang_jni.dll",
    "native/windows-x86/synurang_jni.dll",
    "native/macos-x86_64/libsynurang_jni.dylib",
    "native/macos-aarch64/libsynurang_jni.dylib",
)

ANDROID_ABIS = ("arm64-v8a", "armeabi-v7a")

MAVEN_ARTIFACTS = (
    ("synurang-android", "aar", False),
    ("synurang-android-grpc", "aar", True),
    ("synurang-desktop", "jar", False),
    ("synurang-desktop-grpc", "jar", True),
)

_SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
_SHA_RE = re.compile(r"^[0-9a-fA-F]{7,40}$")
_REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_GITHUB_DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
_SHA256_LINE_RE = re.compile(r"^([0-9a-f]{64})  ([^\s/\\]+)$")


class ReleaseError(ValueError):
    """Raised when version, artifact, or release verification fails."""


def require(condition: object, message: str) -> None:
    if not condition:
        raise ReleaseError(message)


def parse_bool_flag(raw: str, *, name: str) -> bool:
    normalized = raw.strip().lower()
    if not normalized or normalized in ("0", "false", "no"):
        return False
    if normalized in ("1", "true", "yes"):
        return True
    raise ReleaseError(
        f"Invalid boolean value for {name}: {raw!r} (expected one of 1, true, yes, 0, false, no)"
    )


@dataclass(frozen=True)
class SemVer:
    major: int
    minor: int
    patch: int
    prerelease: tuple[str, ...]
    build: str
    raw: str

    @property
    def is_prerelease(self) -> bool:
        return bool(self.prerelease)

    @property
    def core(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"

    @property
    def pep440(self) -> str:
        if not self.prerelease:
            return self.core
        joined_dots = ".".join(self.prerelease)
        match = re.fullmatch(r"(?:(alpha|a)|(beta|b)|(rc))\.?([0-9]+)", joined_dots, re.IGNORECASE)
        if match:
            if match.group(1):
                return f"{self.core}a{int(match.group(4))}"
            if match.group(2):
                return f"{self.core}b{int(match.group(4))}"
            if match.group(3):
                return f"{self.core}rc{int(match.group(4))}"
        dev_match = re.fullmatch(r"dev\.?([0-9]+)", joined_dots, re.IGNORECASE)
        if dev_match:
            return f"{self.core}.dev{int(dev_match.group(1))}"
        raise ReleaseError(
            f"Prerelease {self.raw!r} cannot map to a PyPI-compatible PEP 440 version without local '+'; "
            "use -alpha.N, -beta.N, -rc.N, or -dev.N"
        )

    def compare_key(self) -> tuple[int, int, int, int, tuple[tuple[int, int | str], ...]]:
        if not self.prerelease:
            return (self.major, self.minor, self.patch, 1, ())
        parts: list[tuple[int, int | str]] = []
        for ident in self.prerelease:
            if ident.isdigit():
                parts.append((0, int(ident)))
            else:
                parts.append((1, ident))
        return (self.major, self.minor, self.patch, 0, tuple(parts))


def parse_semver(version: str, *, allow_snapshot: bool = False) -> SemVer:
    require(isinstance(version, str) and version.strip() == version and version, f"Empty version: {version!r}")
    match = _SEMVER_RE.fullmatch(version)
    require(match is not None, f"Version must follow SemVer (MAJOR.MINOR.PATCH[-prerelease]): {version!r}")
    assert match is not None
    major, minor, patch = int(match.group(1)), int(match.group(2)), int(match.group(3))
    pre_raw = match.group(4) or ""
    build = match.group(5) or ""
    require(not build, f"Build metadata '+{build}' is not allowed in release version {version!r}")
    prerelease: tuple[str, ...] = ()
    if pre_raw:
        idents = pre_raw.split(".")
        for ident in idents:
            if ident.isdigit() and len(ident) > 1 and ident.startswith("0"):
                raise ReleaseError(f"Numeric prerelease identifier has leading zero in {version!r}")
        if not allow_snapshot and any(ident.upper() == "SNAPSHOT" for ident in idents):
            raise ReleaseError(f"SNAPSHOT versions are not allowed for releases: {version!r}")
        prerelease = tuple(idents)
    return SemVer(major=major, minor=minor, patch=patch, prerelease=prerelease, build=build, raw=version)


def canonical_version(root: Path = ROOT) -> str:
    pubspec = root / "pubspec.yaml"
    require(pubspec.is_file(), f"Missing {pubspec}")
    content = pubspec.read_text(encoding="utf-8")
    match = re.search(r"(?m)^version:\s*([^\s#]+)\s*$", content)
    require(match is not None, f"Could not find 'version:' in {pubspec}")
    assert match is not None
    version = match.group(1)
    parse_semver(version)
    return version


@dataclass(frozen=True)
class VersionRule:
    relpath: str
    pattern: re.Pattern[str]
    expected_fn: object
    replace_fn: object
    expected_count: int = 1


def _literal_rules() -> tuple[VersionRule, ...]:
    ver_pat = r"(?P<version>[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)(?![0-9A-Za-z._+-])"
    py_ver_pat = r"(?P<version>[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*)(?![0-9A-Za-z._+-])"
    aar_help_ver_pat = (
        r"(?P<version>[0-9]+\.[0-9]+\.[0-9]+(?:-(?!SNAPSHOT(?![0-9A-Za-z._+-]))[0-9A-Za-z.]+)*)"
        r"(?P<snapshot>-SNAPSHOT)?(?![0-9A-Za-z._+-])"
    )
    return (
        VersionRule(
            "pubspec.yaml",
            re.compile(rf"(?m)^(version:\s*){ver_pat}(\s*)$"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
        ),
        VersionRule(
            "python/setup.cfg",
            re.compile(rf"(?m)^(version\s*=\s*){py_ver_pat}(\s*)$"),
            lambda v: {parse_semver(v).pep440},
            lambda m, v: f"{m.group(1)}{parse_semver(v).pep440}{m.group(3)}",
        ),
        VersionRule(
            "python/synurang/__init__.py",
            re.compile(rf'(?m)^(__version__\s*=\s*"){py_ver_pat}(")$'),
            lambda v: {parse_semver(v).pep440},
            lambda m, v: f'{m.group(1)}{parse_semver(v).pep440}{m.group(3)}',
        ),
        VersionRule(
            "ios/synurang.podspec",
            re.compile(rf"(?m)^(\s*s\.version\s*=\s*'){ver_pat}('\s*)$"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
        ),
        VersionRule(
            "macos/synurang.podspec",
            re.compile(rf"(?m)^(\s*s\.version\s*=\s*'){ver_pat}('\s*)$"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
        ),
        VersionRule(
            "swift/SynurangLite.podspec",
            re.compile(rf"(?m)^(\s*s\.version\s*=\s*'){ver_pat}('\s*)$"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
        ),
        VersionRule(
            "makefile",
            re.compile(rf"(?m)^(AAR_VERSION\s*\?=\s*){ver_pat}(\s*)$"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
        ),
        VersionRule(
            "makefile",
            re.compile(rf"(?m)^(DESKTOP_VERSION\s*\?=\s*){ver_pat}(\s*)$"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
        ),
        VersionRule(
            "makefile",
            re.compile(rf"(CODEGEN_VERSION=){ver_pat}"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}",
        ),
        VersionRule(
            "makefile",
            re.compile(rf"(AAR_VERSION=){aar_help_ver_pat}"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group('snapshot') or ''}",
            expected_count=2,
        ),
        VersionRule(
            "docker/build_android_aar_inside.sh",
            re.compile(rf'(?m)^(VERSION="\$\{{VERSION:-){ver_pat}(\}}")$'),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
        ),
        VersionRule(
            "docker/build_desktop_jar.sh",
            re.compile(rf"(?m)^(# Usage \(inside Docker\): VERSION=){ver_pat}( /opt/synurang/build_desktop_jar\.sh)$"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
        ),
        VersionRule(
            "docker/build_desktop_jar.sh",
            re.compile(rf'(?m)^(VERSION="\$\{{VERSION:-){ver_pat}(\}}")$'),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
        ),
        VersionRule(
            "docker/build_codegen_release.sh",
            re.compile(rf"(for example: CODEGEN_VERSION=){ver_pat}( \$0)"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
        ),
        VersionRule(
            "README.md",
            re.compile(rf"(?m)^(VERSION=){ver_pat}(\s*)$"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
        ),
        VersionRule(
            "README.md",
            re.compile(rf"(implementation 'io\.github\.ivere27:synurang-(?:android|android-grpc|desktop|desktop-grpc):){ver_pat}(')"),
            lambda v: {v},
            lambda m, v: f"{m.group(1)}{v}{m.group(3)}",
            expected_count=4,
        ),
    )


def check_versions(root: Path = ROOT, expected: str | None = None) -> str:
    target = expected if expected is not None else canonical_version(root)
    parse_semver(target)
    errors: list[str] = []
    for rule in _literal_rules():
        require("version" in rule.pattern.groupindex, f"{rule.relpath}: pattern missing (?P<version>...) group")
        path = root / rule.relpath
        if not path.is_file():
            errors.append(f"{rule.relpath}: missing file")
            continue
        text = path.read_text(encoding="utf-8")
        matches = list(rule.pattern.finditer(text))
        if len(matches) != rule.expected_count:
            errors.append(
                f"{rule.relpath}: expected {rule.expected_count} match(es) for {rule.pattern.pattern}, found {len(matches)}"
            )
            continue
        allowed = rule.expected_fn(target)
        for match in matches:
            found = match.group("version")
            if found not in allowed:
                errors.append(
                    f"{rule.relpath}: found version {found!r}, expected one of {sorted(allowed)}"
                )
    if errors:
        raise ReleaseError("Version mismatch(es):\n  - " + "\n  - ".join(errors))
    return target


def set_versions(new_version: str, *, root: Path = ROOT, check_only: bool = False) -> list[Path]:
    parsed = parse_semver(new_version)
    _ = parsed.pep440
    if check_only:
        current = check_versions(root, expected=new_version)
        require(current == new_version, f"Version mismatch: {current} != {new_version}")
        return []
    rules_by_file: dict[str, list[VersionRule]] = {}
    for rule in _literal_rules():
        rules_by_file.setdefault(rule.relpath, []).append(rule)
    pending_writes: list[tuple[Path, str]] = []
    for relpath, rules in rules_by_file.items():
        path = root / relpath
        require(path.is_file(), f"Missing versioned file: {relpath}")
        original = path.read_text(encoding="utf-8")
        updated = original
        for rule in rules:
            count = 0

            def _repl(match: re.Match[str], r: VersionRule = rule) -> str:
                nonlocal count
                count += 1
                return r.replace_fn(match, new_version)

            updated = rule.pattern.sub(_repl, updated)
            require(
                count == rule.expected_count,
                f"{relpath}: expected {rule.expected_count} match(es) for {rule.pattern.pattern}, found {count}",
            )
        if updated != original:
            pending_writes.append((path, updated))
    changed: list[Path] = []
    for path, updated in pending_writes:
        path.write_text(updated, encoding="utf-8")
        changed.append(path)
    check_versions(root, expected=new_version)
    return changed


def extract_changelog(version: str, *, root: Path = ROOT, required: bool = True) -> str:
    changelog_path = root / "CHANGELOG.md"
    if not changelog_path.is_file():
        if required:
            raise ReleaseError(f"Missing {changelog_path}")
        return ""
    lines = changelog_path.read_text(encoding="utf-8").splitlines()
    header_re = re.compile(rf"^##\s+(?:\[{re.escape(version)}\]|{re.escape(version)})(?:\s|$)")
    next_re = re.compile(r"^##\s+")
    capturing = False
    captured: list[str] = []
    for line in lines:
        if not capturing:
            if header_re.match(line):
                capturing = True
            continue
        if next_re.match(line):
            break
        captured.append(line)
    body = "\n".join(captured).strip()
    if required:
        require(capturing, f"CHANGELOG.md is missing a section for '## {version}'")
        require(bool(body), f"CHANGELOG.md section '## {version}' is empty")
    return body


def validate_release_tag(
    tag: str,
    *,
    root: Path = ROOT,
    require_changelog: bool = False,
) -> SemVer:
    require(isinstance(tag, str) and tag.startswith("v"), f"Release tag must start with 'v': {tag!r}")
    tag_version = tag[1:]
    parsed = parse_semver(tag_version)
    repo_version = check_versions(root)
    require(
        tag_version == repo_version,
        f"Release tag {tag!r} does not match project version v{repo_version}",
    )
    if require_changelog and not parsed.is_prerelease:
        extract_changelog(tag_version, root=root, required=True)
    elif require_changelog:
        extract_changelog(tag_version, root=root, required=False)
    return parsed


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def _resolve_source_date_epoch(explicit: int | None, root: Path = ROOT) -> int:
    if explicit is not None:
        epoch = explicit
    else:
        raw = os.environ.get("SOURCE_DATE_EPOCH", "").strip()
        if raw:
            require(raw.isdigit(), f"SOURCE_DATE_EPOCH must be an integer, got {raw!r}")
            epoch = int(raw)
        else:
            git_ts = subprocess.run(
                ["git", "-C", str(root), "log", "-1", "--format=%ct"],
                capture_output=True,
                text=True,
                check=False,
            )
            val = git_ts.stdout.strip() if git_ts.returncode == 0 else ""
            epoch = int(val) if val.isdigit() else DEFAULT_SOURCE_DATE_EPOCH
    require(epoch >= DEFAULT_SOURCE_DATE_EPOCH, f"SOURCE_DATE_EPOCH must be >= {DEFAULT_SOURCE_DATE_EPOCH}, got {epoch}")
    return epoch


def _validate_archive_member_path(name: str, *, allow_dir: bool = False) -> None:
    require(bool(name), "Archive contains empty entry path")
    require("\x00" not in name and all(ord(ch) >= 32 for ch in name), f"Control character in archive path: {name!r}")
    require("\\" not in name and ":" not in name, f"Unsafe path separator/drive in archive path: {name!r}")
    require(not name.startswith("/"), f"Absolute path in archive: {name!r}")
    stripped = name.rstrip("/") if allow_dir else name
    require(bool(stripped), f"Invalid archive path: {name!r}")
    parts = stripped.split("/")
    for part in parts:
        require(part not in ("", ".", ".."), f"Unsafe path traversal component in archive path: {name!r}")


def _validate_zip_container(path: Path) -> dict[str, bytes]:
    require(path.is_file() and not path.is_symlink(), f"Missing or symlink archive: {path}")
    seen_exact: set[str] = set()
    seen_lower: set[str] = set()
    files: dict[str, bytes] = {}
    with zipfile.ZipFile(path, "r") as zf:
        bad = zf.testzip()
        require(bad is None, f"Corrupt CRC in ZIP {path.name}: {bad}")
        for info in zf.infolist():
            mode = (info.external_attr >> 16) & 0o170000
            require(mode != stat.S_IFLNK, f"Symlink entry disallowed in {path.name}: {info.filename}")
            is_dir = info.is_dir()
            _validate_archive_member_path(info.filename, allow_dir=is_dir)
            key = info.filename.rstrip("/")
            require(key not in seen_exact, f"Duplicate ZIP entry in {path.name}: {info.filename}")
            lower_key = key.lower()
            require(lower_key not in seen_lower, f"Case-colliding ZIP entry in {path.name}: {info.filename}")
            seen_exact.add(key)
            seen_lower.add(lower_key)
            if not is_dir:
                files[key] = zf.read(info.filename)
    return files


def _validate_targz_container(path: Path) -> dict[str, tuple[tarfile.TarInfo, bytes]]:
    require(path.is_file() and not path.is_symlink(), f"Missing or symlink archive: {path}")
    seen_exact: set[str] = set()
    seen_lower: set[str] = set()
    entries: dict[str, tuple[tarfile.TarInfo, bytes]] = {}
    with gzip.open(path, "rb") as gz:
        raw_tar = gz.read()
    with tarfile.open(fileobj=io.BytesIO(raw_tar), mode="r:") as tf:
        for member in tf.getmembers():
            require(not member.issym() and not member.islnk(), f"Link entry disallowed in {path.name}: {member.name}")
            require(member.isdir() or member.isreg(), f"Special file disallowed in {path.name}: {member.name}")
            _validate_archive_member_path(member.name, allow_dir=member.isdir())
            key = member.name.rstrip("/")
            require(key not in seen_exact, f"Duplicate TAR entry in {path.name}: {member.name}")
            lower_key = key.lower()
            require(lower_key not in seen_lower, f"Case-colliding TAR entry in {path.name}: {member.name}")
            seen_exact.add(key)
            seen_lower.add(lower_key)
            payload = b""
            if member.isreg():
                extracted = tf.extractfile(member)
                require(extracted is not None, f"Could not read TAR member {member.name} in {path.name}")
                assert extracted is not None
                payload = extracted.read()
            entries[key] = (member, payload)
    return entries


def _check_elf_static(binary: Path, target: str) -> None:
    require(shutil.which("readelf") is not None, "readelf is required to verify static *-linux-musl binaries")
    env = {**os.environ, "LC_ALL": "C"}
    phdrs = subprocess.run(["readelf", "-l", str(binary)], capture_output=True, text=True, env=env, check=False)
    require(phdrs.returncode == 0, f"readelf -l failed on {binary}: {phdrs.stderr.strip()}")
    require("INTERP" not in phdrs.stdout, f"Linux release binary is dynamically linked (PT_INTERP): {binary}")
    dyn = subprocess.run(["readelf", "-d", str(binary)], capture_output=True, text=True, env=env, check=False)
    require(dyn.returncode == 0, f"readelf -d failed on {binary}: {dyn.stderr.strip()}")
    require("NEEDED" not in dyn.stdout, f"Linux release binary has dynamic NEEDED dependencies: {binary}")
    hdr = subprocess.run(["readelf", "-h", str(binary)], capture_output=True, text=True, env=env, check=False)
    require(hdr.returncode == 0, f"readelf -h failed on {binary}: {hdr.stderr.strip()}")
    if target.startswith("x86_64-"):
        require("X86-64" in hdr.stdout, f"Expected x86-64 ELF binary for {target}, got:\n{hdr.stdout}")
    elif target.startswith("aarch64-"):
        require("AArch64" in hdr.stdout, f"Expected AArch64 ELF binary for {target}, got:\n{hdr.stdout}")


def _check_binary_magic(data: bytes, target: str, context: str) -> None:
    require(len(data) > 0, f"Binary is empty: {context}")
    if "-windows-" in target or target.startswith("windows-"):
        require(data[:2] == b"MZ", f"Expected PE executable/DLL (MZ header) for {target}: {context}")
    elif "-apple-darwin" in target or target.startswith("macos-"):
        macho_magics = (
            b"\xcf\xfa\xed\xfe",
            b"\xfe\xed\xfa\xcf",
            b"\xce\xfa\xed\xfe",
            b"\xfe\xed\xfa\xce",
            b"\xca\xfe\xba\xbe",
        )
        require(data[:4] in macho_magics, f"Expected Mach-O binary for {target}: {context}")
    elif "-linux-" in target or target.startswith("linux-") or target in ANDROID_ABIS:
        require(data[:4] == b"\x7fELF", f"Expected ELF binary for {target}: {context}")


def smoke_test_generator_binary(binary: Path) -> None:
    require(shutil.which("protoc") is not None, "protoc is required for generator smoke test")
    with tempfile.TemporaryDirectory(prefix="synurang-codegen-smoke-") as tmp:
        work = Path(tmp)
        proto = work / "smoke.proto"
        proto.write_text(
            'syntax = "proto3";\n'
            'package synurang.release.smoke;\n'
            'option go_package = "example.com/synurang/release/smoke";\n'
            "message PingRequest {}\n"
            "message PingResponse {}\n"
            "service SmokeService {\n"
            "  rpc Ping(PingRequest) returns (PingResponse);\n"
            "}\n",
            encoding="utf-8",
        )
        go_out = work / "go-out"
        py_out = work / "py-out"
        go_out.mkdir()
        py_out.mkdir()

        bin_resolved = binary.resolve()

        subprocess.run(
            [
                "protoc",
                f"--proto_path={work}",
                f"--plugin={CANONICAL_BINARY}={bin_resolved}",
                f"--synurang-ffi_out={go_out}",
                "--synurang-ffi_opt=lang=go",
                "smoke.proto",
            ],
            check=True,
        )
        go_file = go_out / "smoke_ffi.pb.go"
        require(go_file.is_file() and go_file.stat().st_size > 0, f"Missing Go smoke output: {go_file}")
        require("SmokeService" in go_file.read_text(encoding="utf-8"), f"Go smoke output missing SmokeService: {go_file}")

        subprocess.run(
            [
                "protoc",
                f"--proto_path={work}",
                f"--plugin={CANONICAL_BINARY}={bin_resolved}",
                f"--synurang-ffi_out={py_out}",
                "--synurang-ffi_opt=lang=python",
                "smoke.proto",
            ],
            check=True,
        )
        py_lite = py_out / "smoke_lite.py"
        py_ffi = py_out / "smoke_ffi.py"
        require(py_lite.is_file() and py_lite.stat().st_size > 0, f"Missing Python smoke output: {py_lite}")
        require(py_ffi.is_file() and py_ffi.stat().st_size > 0, f"Missing Python smoke output: {py_ffi}")
        py_ffi_text = py_ffi.read_text(encoding="utf-8")
        require("class SmokeServiceClient" in py_ffi_text, "Python smoke output missing SmokeServiceClient")
        require("class SmokeServiceFfi" in py_ffi_text, "Python smoke output missing SmokeServiceFfi")
        subprocess.run([sys.executable, "-m", "py_compile", str(py_lite), str(py_ffi)], check=True)


def codegen_archive_name(version: str, target: str) -> str:
    ext = "zip" if "-windows-" in target else "tar.gz"
    return f"{CANONICAL_BINARY}-{version}-{target}.{ext}"


def package_codegen(
    *,
    target: str,
    version: str,
    binary: Path,
    out_dir: Path,
    root: Path = ROOT,
    source_date_epoch: int | None = None,
    skip_elf_check: bool = False,
    smoke_test: bool = False,
) -> Path:
    require(target in ALL_SUPPORTED_CODEGEN_TARGETS, f"Unsupported codegen target: {target}")
    parse_semver(version)
    require(binary.is_file() and not binary.is_symlink(), f"Generator binary not found: {binary}")
    bin_bytes = binary.read_bytes()
    _check_binary_magic(bin_bytes, target, str(binary))

    if target.endswith("-linux-musl") and not skip_elf_check:
        _check_elf_static(binary, target)

    if smoke_test:
        smoke_test_generator_binary(binary)

    license_path = root / "LICENSE"
    require(license_path.is_file(), f"Missing license file: {license_path}")
    license_bytes = license_path.read_bytes()
    require(len(license_bytes) > 0, f"License file is empty: {license_path}")

    epoch = _resolve_source_date_epoch(source_date_epoch, root=root)
    is_windows = "-windows-" in target
    bin_name = f"{CANONICAL_BINARY}.exe" if is_windows else CANONICAL_BINARY
    bundle_name = f"{CANONICAL_BINARY}-{version}-{target}"
    archive_name = codegen_archive_name(version, target)
    out_dir.mkdir(parents=True, exist_ok=True)
    archive_path = out_dir / archive_name

    if is_windows:
        dt = datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc)
        zip_dt = (dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            for member_name, mode, payload in (
                (f"{bundle_name}/LICENSE", 0o644, license_bytes),
                (f"{bundle_name}/{bin_name}", 0o755, bin_bytes),
            ):
                info = zipfile.ZipInfo(member_name, date_time=zip_dt)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | mode) << 16
                zf.writestr(info, payload)
    else:
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:", format=tarfile.USTAR_FORMAT) as tf:
            dir_info = tarfile.TarInfo(bundle_name)
            dir_info.type = tarfile.DIRTYPE
            dir_info.mode = 0o755
            dir_info.mtime = epoch
            dir_info.uid = 0
            dir_info.gid = 0
            dir_info.uname = ""
            dir_info.gname = ""
            tf.addfile(dir_info)

            for member_name, mode, payload in (
                (f"{bundle_name}/LICENSE", 0o644, license_bytes),
                (f"{bundle_name}/{bin_name}", 0o755, bin_bytes),
            ):
                info = tarfile.TarInfo(member_name)
                info.type = tarfile.REGTYPE
                info.mode = mode
                info.size = len(payload)
                info.mtime = epoch
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                tf.addfile(info, io.BytesIO(payload))

        with archive_path.open("wb") as raw_out:
            with gzip.GzipFile(filename="", mode="wb", compresslevel=9, fileobj=raw_out, mtime=epoch) as gz:
                gz.write(buf.getvalue())

    verify_codegen_archive(archive_path, expected_version=version, expected_target=target)
    return archive_path


def verify_codegen_archive(
    archive: Path,
    *,
    expected_version: str | None = None,
    expected_target: str | None = None,
) -> tuple[str, str]:
    name = archive.name
    version = None
    target = None
    ext = None
    for candidate in sorted(ALL_SUPPORTED_CODEGEN_TARGETS, key=len, reverse=True):
        cand_ext = "zip" if "-windows-" in candidate else "tar.gz"
        cand_suffix = f"-{candidate}.{cand_ext}"
        if name.startswith(f"{CANONICAL_BINARY}-") and name.endswith(cand_suffix):
            version = name[len(CANONICAL_BINARY) + 1 : -len(cand_suffix)]
            target = candidate
            ext = cand_ext
            break
    require(version is not None and target is not None and ext is not None, f"Unexpected codegen archive name: {name}")
    assert version is not None and target is not None and ext is not None
    parse_semver(version)
    require(target in ALL_SUPPORTED_CODEGEN_TARGETS, f"Unknown codegen target in {name}: {target}")
    if expected_version is not None:
        require(version == expected_version, f"Archive {name} version {version} != expected {expected_version}")
    if expected_target is not None:
        require(target == expected_target, f"Archive {name} target {target} != expected {expected_target}")

    bundle_name = f"{CANONICAL_BINARY}-{version}-{target}"
    is_windows = "-windows-" in target
    expected_ext = "zip" if is_windows else "tar.gz"
    require(ext == expected_ext, f"Archive {name} must end with .{expected_ext}")
    bin_rel = f"{bundle_name}/{CANONICAL_BINARY}.exe" if is_windows else f"{bundle_name}/{CANONICAL_BINARY}"
    license_rel = f"{bundle_name}/LICENSE"

    if is_windows:
        files = _validate_zip_container(archive)
        require(set(files.keys()) == {bin_rel, license_rel}, f"Unexpected contents in {name}: {sorted(files.keys())}")
        _check_binary_magic(files[bin_rel], target, f"{name}:{bin_rel}")
        require(len(files[license_rel]) > 0, f"Empty LICENSE in {name}")
    else:
        entries = _validate_targz_container(archive)
        reg_keys = {k for k, (info, _) in entries.items() if info.isreg()}
        require(reg_keys == {bin_rel, license_rel}, f"Unexpected contents in {name}: {sorted(reg_keys)}")
        bin_info, bin_bytes = entries[bin_rel]
        require((bin_info.mode & 0o111) != 0, f"Generator binary lacks executable permissions in {name}")
        _check_binary_magic(bin_bytes, target, f"{name}:{bin_rel}")
        _, lic_bytes = entries[license_rel]
        require(len(lic_bytes) > 0, f"Empty LICENSE in {name}")

    return version, target


def _verify_pom(pom_path: Path, *, artifact: str, version: str, packaging: str, expects_core_dep: bool) -> None:
    require(pom_path.is_file() and not pom_path.is_symlink(), f"Missing POM: {pom_path}")
    tree = ET.parse(pom_path)
    root = tree.getroot()
    ns = ""
    if root.tag.startswith("{"):
        ns = root.tag[: root.tag.index("}") + 1]

    def text_of(elem: ET.Element, tag: str) -> str:
        child = elem.find(f"{ns}{tag}")
        return child.text.strip() if child is not None and child.text else ""

    require(text_of(root, "groupId") == MAVEN_GROUP_ID, f"{pom_path.name}: groupId mismatch")
    require(text_of(root, "artifactId") == artifact, f"{pom_path.name}: artifactId mismatch")
    require(text_of(root, "version") == version, f"{pom_path.name}: version mismatch")
    require(text_of(root, "packaging") == packaging, f"{pom_path.name}: packaging mismatch")
    if expects_core_dep:
        deps = root.findall(f"{ns}dependencies/{ns}dependency")
        core_artifact = artifact.removesuffix("-grpc")
        matched = [
            dep for dep in deps
            if text_of(dep, "groupId") == MAVEN_GROUP_ID
            and text_of(dep, "artifactId") == core_artifact
            and text_of(dep, "version") == version
        ]
        require(len(matched) == 1, f"{pom_path.name}: missing dependency on {MAVEN_GROUP_ID}:{core_artifact}:{version}")


def _verify_embedded_classes_jar(raw_jar: bytes, label: str) -> None:
    with zipfile.ZipFile(io.BytesIO(raw_jar), "r") as zf:
        bad = zf.testzip()
        require(bad is None, f"Corrupt ZIP inside {label}: {bad}")
        classes = [
            name for name in zf.namelist()
            if name.startswith("io/github/ivere27/synurang/") and name.endswith(".class")
        ]
        require(len(classes) > 0, f"{label} has no compiled classes under io/github/ivere27/synurang/")


def expected_maven_filenames(version: str) -> set[str]:
    names: set[str] = set()
    for artifact, ext, _ in MAVEN_ARTIFACTS:
        names.update(
            {
                f"{artifact}-{version}.{ext}",
                f"{artifact}-{version}.pom",
                f"{artifact}-{version}-sources.jar",
                f"{artifact}-{version}-javadoc.jar",
            }
        )
    return names


def verify_maven(dist_dir: Path, *, version: str) -> list[Path]:
    parse_semver(version)
    require(dist_dir.is_dir(), f"Maven dist directory not found: {dist_dir}")
    paths: list[Path] = []

    for artifact, ext, expects_core_dep in MAVEN_ARTIFACTS:
        main_path = dist_dir / f"{artifact}-{version}.{ext}"
        pom_path = dist_dir / f"{artifact}-{version}.pom"
        sources_path = dist_dir / f"{artifact}-{version}-sources.jar"
        javadoc_path = dist_dir / f"{artifact}-{version}-javadoc.jar"

        _verify_pom(pom_path, artifact=artifact, version=version, packaging=ext, expects_core_dep=expects_core_dep)

        main_files = _validate_zip_container(main_path)
        if ext == "aar":
            require("AndroidManifest.xml" in main_files, f"{main_path.name} missing AndroidManifest.xml")
            require("classes.jar" in main_files, f"{main_path.name} missing classes.jar")
            _verify_embedded_classes_jar(main_files["classes.jar"], f"{main_path.name}:classes.jar")
            if artifact == "synurang-android":
                for abi in ANDROID_ABIS:
                    so_rel = f"jni/{abi}/libsynurang_jni.so"
                    require(so_rel in main_files, f"{main_path.name} missing {so_rel}")
                    _check_binary_magic(main_files[so_rel], abi, f"{main_path.name}:{so_rel}")
                    require(
                        b"Java_io_github_ivere27_synurang_ModuleJni_" in main_files[so_rel],
                        f"{main_path.name}:{so_rel} is missing ModuleJni JNI symbols",
                    )
        else:
            classes = [
                name for name in main_files
                if name.startswith("io/github/ivere27/synurang/") and name.endswith(".class")
            ]
            require(len(classes) > 0, f"{main_path.name} has no classes under io/github/ivere27/synurang/")
            if artifact == "synurang-desktop":
                for jni_rel in DESKTOP_JNI_PATHS:
                    require(jni_rel in main_files, f"{main_path.name} missing embedded JNI library {jni_rel}")
                    platform = jni_rel.split("/")[1]
                    native_bytes = main_files[jni_rel]
                    _check_binary_magic(native_bytes, platform, f"{main_path.name}:{jni_rel}")
                    require(
                        b"Java_io_github_ivere27_synurang_ModuleJni_" in native_bytes,
                        f"{main_path.name}:{jni_rel} is missing ModuleJni JNI symbols",
                    )
                    require(
                        b"Java_io_github_ivere27_synurang_PluginHost" in native_bytes
                        or b"Java_io_github_ivere27_synurang_SynurangJni_" in native_bytes
                        or b"synurang_stream_open" in native_bytes,
                        f"{main_path.name}:{jni_rel} looks incomplete",
                    )

        sources_files = _validate_zip_container(sources_path)
        require(
            any(k.endswith(".java") for k in sources_files),
            f"{sources_path.name} contains no .java source files",
        )
        javadoc_files = _validate_zip_container(javadoc_path)
        require(
            any(k.endswith(".html") for k in javadoc_files),
            f"{javadoc_path.name} contains no .html javadoc files",
        )

        paths.extend([main_path, pom_path, sources_path, javadoc_path])

    return paths


def expected_python_filenames(version: str) -> set[str]:
    pep = parse_semver(version).pep440
    return {
        f"synurang-{pep}-py3-none-any.whl",
        f"synurang-{pep}.tar.gz",
    }


def _parse_pkg_metadata_headers(raw: bytes) -> dict[str, str]:
    headers: dict[str, str] = {}
    for line in raw.decode("utf-8", errors="replace").splitlines():
        if not line:
            break
        if ":" in line and not line[0].isspace():
            key, val = line.split(":", 1)
            headers.setdefault(key.strip(), val.strip())
    return headers


def verify_python(dist_dir: Path, *, version: str) -> list[Path]:
    pep = parse_semver(version).pep440
    require(dist_dir.is_dir(), f"Python dist directory not found: {dist_dir}")
    wheel_path = dist_dir / f"synurang-{pep}-py3-none-any.whl"
    sdist_path = dist_dir / f"synurang-{pep}.tar.gz"

    whl_files = _validate_zip_container(wheel_path)
    meta_keys = [k for k in whl_files if k.endswith(".dist-info/METADATA")]
    require(len(meta_keys) == 1, f"{wheel_path.name} missing .dist-info/METADATA")
    whl_meta = _parse_pkg_metadata_headers(whl_files[meta_keys[0]])
    require(whl_meta.get("Name") == "synurang", f"{wheel_path.name} metadata Name={whl_meta.get('Name')!r}")
    require(whl_meta.get("Version") == pep, f"{wheel_path.name} metadata Version={whl_meta.get('Version')!r} != {pep!r}")
    require("synurang/__init__.py" in whl_files, f"{wheel_path.name} missing synurang/__init__.py")

    sdist_entries = _validate_targz_container(sdist_path)
    pkg_infos = [
        k for k, (info, _) in sdist_entries.items()
        if info.isreg() and k.count("/") == 1 and k.endswith("/PKG-INFO")
    ]
    require(len(pkg_infos) == 1, f"{sdist_path.name} expected top-level <dir>/PKG-INFO, found: {pkg_infos}")
    _, pkg_bytes = sdist_entries[pkg_infos[0]]
    sdist_meta = _parse_pkg_metadata_headers(pkg_bytes)
    require(sdist_meta.get("Name") == "synurang", f"{sdist_path.name} PKG-INFO Name={sdist_meta.get('Name')!r}")
    require(sdist_meta.get("Version") == pep, f"{sdist_path.name} PKG-INFO Version={sdist_meta.get('Version')!r} != {pep!r}")
    require(
        any(info.isreg() and k.endswith("/synurang/__init__.py") for k, (info, _) in sdist_entries.items()),
        f"{sdist_path.name} missing synurang/__init__.py",
    )

    return [wheel_path, sdist_path]


def _discover_codegen_archives(
    search_dirs: list[Path],
    *,
    version: str,
    required_targets: tuple[str, ...],
) -> dict[str, Path]:
    found: dict[str, Path] = {}
    for base in search_dirs:
        require(base.is_dir(), f"Codegen search directory does not exist: {base}")
        for entry in sorted(base.rglob("*")):
            if not entry.is_file() or entry.is_symlink():
                continue
            if not entry.name.startswith(f"{CANONICAL_BINARY}-"):
                continue
            if not (entry.name.endswith(".tar.gz") or entry.name.endswith(".zip")):
                continue
            ver, target = verify_codegen_archive(entry, expected_version=version)
            require(ver == version, f"Archive {entry} version mismatch")
            if target in found:
                raise ReleaseError(f"Duplicate codegen archive for target {target}: {found[target]} and {entry}")
            found[target] = entry
    missing = [t for t in required_targets if t not in found]
    require(not missing, f"Missing codegen archives for targets: {', '.join(missing)}")
    return found


def checksum_text(paths: list[Path]) -> str:
    ordered = sorted(paths, key=lambda p: p.name)
    return "".join(f"{_sha256_file(path)}  {path.name}\n" for path in ordered)


def _validate_stage_out_dir(out_dir: Path, *, input_dirs: list[Path], root: Path) -> None:
    resolved_out = out_dir.resolve()
    resolved_root = root.resolve()
    require(resolved_out != resolved_root, f"Refusing to use repository root as stage output directory: {out_dir}")
    require(
        not resolved_root.is_relative_to(resolved_out),
        f"Refusing to stage into ancestor of repository root: {out_dir}",
    )
    for src_dir in input_dirs:
        resolved_src = src_dir.resolve()
        require(
            resolved_out != resolved_src and not resolved_src.is_relative_to(resolved_out),
            f"Stage output directory {out_dir} overlaps or contains input directory {src_dir}",
        )
        require(
            not resolved_out.is_relative_to(resolved_src),
            f"Stage output directory {out_dir} must not be inside input directory {src_dir}",
        )


def stage_ci(
    *,
    out_dir: Path,
    codegen_dirs: list[Path],
    maven_dir: Path | None = None,
    python_dir: Path | None = None,
    required_codegen_targets: tuple[str, ...] = DEFAULT_CODEGEN_TARGETS,
    include_maven: bool = True,
    include_python: bool = True,
    version: str | None = None,
    root: Path = ROOT,
) -> list[Path]:
    ver = version if version is not None else check_versions(root)
    input_dirs: list[Path] = list(codegen_dirs)
    if include_maven:
        require(maven_dir is not None, "--maven-dir is required when Maven packages are included")
        assert maven_dir is not None
        input_dirs.append(maven_dir)
    if include_python:
        require(python_dir is not None, "--python-dir is required when Python packages are included")
        assert python_dir is not None
        input_dirs.append(python_dir)
    _validate_stage_out_dir(out_dir, input_dirs=input_dirs, root=root)

    staged_sources: list[Path] = []
    codegen_map = _discover_codegen_archives(codegen_dirs, version=ver, required_targets=required_codegen_targets)
    staged_sources.extend(codegen_map[target] for target in required_codegen_targets)

    if include_maven:
        assert maven_dir is not None
        staged_sources.extend(verify_maven(maven_dir, version=ver))

    if include_python:
        assert python_dir is not None
        staged_sources.extend(verify_python(python_dir, version=ver))

    names = [p.name for p in staged_sources]
    require(len(names) == len(set(names)), "Duplicate staged asset filenames detected")

    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    staged_files: list[Path] = []
    for src in sorted(staged_sources, key=lambda p: p.name):
        dst = out_dir / src.name
        shutil.copy2(src, dst)
        staged_files.append(dst)

    sums_path = out_dir / "SHA256SUMS"
    sums_path.write_text(checksum_text(staged_files), encoding="utf-8")

    verify_ci(
        dist_dir=out_dir,
        version=ver,
        required_codegen_targets=required_codegen_targets,
        require_maven=include_maven,
        require_python=include_python,
        require_checksums=True,
        root=root,
    )
    return staged_files


def _parse_sha256sums(sums_path: Path) -> dict[str, str]:
    require(sums_path.is_file() and not sums_path.is_symlink(), f"Missing SHA256SUMS: {sums_path}")
    lines = sums_path.read_text(encoding="utf-8").splitlines()
    parsed_sums: dict[str, str] = {}
    for line in lines:
        if not line.strip():
            continue
        match = _SHA256_LINE_RE.fullmatch(line)
        require(match is not None, f"Malformed SHA256SUMS line: {line!r}")
        assert match is not None
        digest_hex, fname = match.group(1), match.group(2)
        require(fname not in parsed_sums, f"Duplicate SHA256SUMS entry: {fname}")
        parsed_sums[fname] = digest_hex
    return parsed_sums


def verify_ci(
    *,
    dist_dir: Path,
    version: str | None = None,
    tag: str = "",
    required_codegen_targets: tuple[str, ...] = DEFAULT_CODEGEN_TARGETS,
    require_maven: bool = True,
    require_python: bool = True,
    require_checksums: bool = True,
    root: Path = ROOT,
) -> tuple[str, list[Path]]:
    require(not (tag and version), "Specify either --tag or --version, not both")
    if tag:
        ver = validate_release_tag(tag, root=root).raw
    elif version:
        parse_semver(version)
        ver = version
    else:
        ver = check_versions(root)

    require(dist_dir.is_dir(), f"Staged release directory does not exist: {dist_dir}")
    all_entries = sorted(dist_dir.iterdir(), key=lambda p: p.name)
    for entry in all_entries:
        require(not entry.is_symlink(), f"Symlinks disallowed in staged release directory: {entry}")
        require(entry.is_file(), f"Subdirectories disallowed in staged release directory: {entry}")

    expected_names: set[str] = {codegen_archive_name(ver, t) for t in required_codegen_targets}
    if require_maven:
        expected_names.update(expected_maven_filenames(ver))
    if require_python:
        expected_names.update(expected_python_filenames(ver))

    actual_names = {entry.name for entry in all_entries}
    checksum_file = dist_dir / "SHA256SUMS"
    if require_checksums:
        require(checksum_file.is_file(), f"Missing SHA256SUMS in {dist_dir}")
        expected_with_sums = expected_names | {"SHA256SUMS"}
    else:
        expected_with_sums = expected_names | ({"SHA256SUMS"} if checksum_file.exists() else set())

    missing = sorted(expected_names - actual_names)
    unexpected = sorted(actual_names - expected_with_sums)
    require(not missing, f"Missing expected release asset(s) in {dist_dir}: {', '.join(missing)}")
    require(not unexpected, f"Unexpected extra file(s) in {dist_dir}: {', '.join(unexpected)}")

    for target in required_codegen_targets:
        verify_codegen_archive(dist_dir / codegen_archive_name(ver, target), expected_version=ver, expected_target=target)
    if require_maven:
        verify_maven(dist_dir, version=ver)
    if require_python:
        verify_python(dist_dir, version=ver)

    assets = [dist_dir / name for name in sorted(expected_names)]

    if checksum_file.is_file():
        parsed_sums = _parse_sha256sums(checksum_file)
        require(
            set(parsed_sums.keys()) == expected_names,
            f"SHA256SUMS asset list mismatch: expected {sorted(expected_names)}, got {sorted(parsed_sums.keys())}",
        )
        for asset in assets:
            actual_hex = _sha256_file(asset)
            require(
                parsed_sums[asset.name] == actual_hex,
                f"SHA256 mismatch for {asset.name}: manifest={parsed_sums[asset.name]} actual={actual_hex}",
            )

    return ver, assets


def resolve_repository(repo: str, root: Path = ROOT) -> str:
    if repo:
        require(_REPO_RE.fullmatch(repo) is not None, f"Repository must be OWNER/REPO, got {repo!r}")
        return repo
    env_repo = os.environ.get("GH_REPO", "") or os.environ.get("GITHUB_REPOSITORY", "")
    if env_repo:
        require(_REPO_RE.fullmatch(env_repo) is not None, f"Invalid GH_REPO/GITHUB_REPOSITORY: {env_repo!r}")
        return env_repo
    resp = subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    resolved = resp.stdout.strip()
    require(resp.returncode == 0 and _REPO_RE.fullmatch(resolved) is not None, "Could not resolve GitHub repository")
    return resolved


def _resolve_gh_host() -> str:
    return os.environ.get("GH_HOST", "").strip() or "github.com"


def _gh_api(
    path: str,
    *,
    root: Path = ROOT,
    paginate: bool = False,
    method: str | None = None,
    fields: list[tuple[str, str]] | None = None,
):
    cmd = ["gh", "api", "--hostname", _resolve_gh_host(), path]
    if paginate:
        cmd += ["--paginate", "--slurp"]
    if method:
        cmd += ["--method", method]
    if fields:
        for flag, value in fields:
            cmd += [flag, value]
    response = subprocess.run(cmd, cwd=root, capture_output=True, text=True, check=False)
    if response.returncode != 0:
        detail = response.stderr.strip() or response.stdout.strip() or f"exit {response.returncode}"
        raise ReleaseError(f"gh api failed ({path}): {detail}")
    raw = response.stdout.strip()
    if not raw:
        return None
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as err:
        raise ReleaseError(f"GitHub API returned invalid JSON for {path}") from err
    if paginate:
        require(
            isinstance(value, list) and all(isinstance(page, list) for page in value),
            f"GitHub API returned invalid paginated response for {path}",
        )
        return [item for page in value for item in page]
    return value


def list_releases(repo: str, root: Path = ROOT) -> list[dict]:
    return _gh_api(f"repos/{repo}/releases?per_page=100", root=root, paginate=True)


def list_release_assets(repo: str, release_id: int, root: Path = ROOT) -> list[dict]:
    return _gh_api(f"repos/{repo}/releases/{release_id}/assets?per_page=100", root=root, paginate=True)


def _is_positive_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def verify_release_assets(
    repo: str,
    tag: str,
    upload_paths: list[Path],
    *,
    expected_draft: bool | None,
    expected_prerelease: bool,
    root: Path = ROOT,
) -> dict:
    found = [rel for rel in list_releases(repo, root=root) if rel.get("tag_name") == tag]
    draft_ok = expected_draft is None or (len(found) == 1 and found[0].get("draft") is expected_draft)
    prerelease_ok = len(found) == 1 and found[0].get("prerelease") is expected_prerelease
    if len(found) != 1 or not draft_ok or not prerelease_ok:
        raise ReleaseError(
            f"Expected one release for tag {tag!r} matching draft={expected_draft!r}, prerelease={expected_prerelease!r}"
        )
    release = found[0]
    release_id = release.get("id")
    if _is_positive_int(release_id):
        actual = list_release_assets(repo, release_id, root=root)
    else:
        actual = release.get("assets") or []

    expected = {}
    for path in upload_paths:
        raw = path.read_bytes()
        expected[path.name] = (len(raw), "sha256:" + _sha256_bytes(raw))

    require(isinstance(actual, list), f"Invalid asset payload on release {tag!r}")
    actual_names = {item.get("name") for item in actual if isinstance(item, dict) and item.get("name")}
    require(
        len(actual) == len(expected) and actual_names == set(expected),
        f"Uploaded assets for {tag!r} do not match expected set: "
        f"missing={sorted(set(expected) - actual_names)}, extra={sorted(actual_names - set(expected))}",
    )
    for asset in actual:
        name = asset.get("name", "")
        exp_size, exp_digest = expected[name]
        if asset.get("state") != "uploaded" or asset.get("size") != exp_size:
            raise ReleaseError(f"Release asset {name!r} is incomplete on GitHub (state={asset.get('state')!r}, size={asset.get('size')!r})")
        reported = asset.get("digest")
        if not isinstance(reported, str) or not _GITHUB_DIGEST_RE.fullmatch(reported):
            raise ReleaseError(f"Release asset {name!r} has no valid GitHub SHA-256 digest: {reported!r}")
        if reported != exp_digest:
            raise ReleaseError(f"Release asset {name!r} digest mismatch: github={reported} local={exp_digest}")
    return release


def update_nightly_git_ref(repo: str, sha: str, root: Path = ROOT) -> None:
    refs = _gh_api(f"repos/{repo}/git/matching-refs/tags/nightly", root=root)
    has_exact = isinstance(refs, list) and any(
        isinstance(item, dict) and item.get("ref") == "refs/tags/nightly" for item in refs
    )
    if has_exact:
        _gh_api(
            f"repos/{repo}/git/refs/tags/nightly",
            root=root,
            method="PATCH",
            fields=[("-f", f"sha={sha}"), ("-F", "force=true")],
        )
    else:
        _gh_api(
            f"repos/{repo}/git/refs",
            root=root,
            method="POST",
            fields=[("-f", "ref=refs/tags/nightly"), ("-f", f"sha={sha}")],
        )


def _ci_release_notes(channel: str, version: str, *, sha: str, tag: str, changelog: str = "", is_prerelease: bool = False) -> str:
    if channel == "nightly":
        intro = (
            f"Rolling nightly pre-release built transparently by GitHub Actions from commit `{sha}`.\n\n"
            f"- Version: `{version}` (`{sha[:7]}`)\n"
            f"- Note: Only published to GitHub Releases (not pushed to Maven Central, PyPI, or pub.dev)."
        )
    elif is_prerelease:
        intro = (
            f"Pre-release `{tag}` built and published transparently by GitHub Actions from commit `{sha}`.\n\n"
            f"- Note: Tagged pre-releases are published to GitHub Releases only (not pushed to Maven Central, PyPI, or pub.dev)."
        )
    else:
        intro = f"Release `{tag}` built and published transparently by GitHub Actions from commit `{sha}`."
    changelog_block = f"\n\n### Changes in {version}\n\n{changelog}\n" if changelog else ""
    install_block = (
        "\n### Artifacts\n"
        "- `protoc-gen-synurang-ffi-<version>-<target>.(tar.gz|zip)`: Code generator binaries (`x86_64-unknown-linux-musl`, `aarch64-unknown-linux-musl`, `x86_64-pc-windows-msvc`, `aarch64-apple-darwin`, `x86_64-apple-darwin`).\n"
        "- `synurang-android`, `synurang-android-grpc`: Android AAR libraries (`io.github.ivere27`).\n"
        "- `synurang-desktop`, `synurang-desktop-grpc`: Desktop JAR libraries with embedded JNI natives (`linux`, `windows`, `macos`).\n"
        "- `synurang-<version>.tar.gz`, `synurang-<version>-py3-none-any.whl`: Python runtime distribution.\n"
        "- `SHA256SUMS`: Cryptographic checksums for all release assets (`sha256sum --check SHA256SUMS`).\n"
    )
    return intro + changelog_block + install_block


def _newer_published_stable_releases(existing_releases: list[dict], *, target_tag: str, parsed_ver: SemVer) -> list[str]:
    if parsed_ver.is_prerelease:
        return []
    new_key = parsed_ver.compare_key()
    newer: list[tuple[tuple[int, int, int, int, tuple[tuple[int, int | str], ...]], str]] = []
    for rel in existing_releases:
        rel_tag = rel.get("tag_name", "")
        if rel_tag == target_tag:
            continue
        if not rel.get("draft") and not rel.get("prerelease") and rel_tag.startswith("v"):
            try:
                prev_key = parse_semver(rel_tag[1:]).compare_key()
            except ReleaseError:
                continue
            if prev_key == new_key:
                raise ReleaseError(f"Release {target_tag!r} has same SemVer precedence as published release {rel_tag!r}")
            if prev_key > new_key:
                newer.append((prev_key, rel_tag))
    newer.sort(key=lambda item: item[0])
    return [tag for _, tag in newer]


def release_ci(
    *,
    channel: str,
    dist_dir: Path,
    sha: str,
    tag: str = "",
    repo: str = "",
    allow_older: bool = False,
    dry_run: bool = False,
    root: Path = ROOT,
) -> None:
    require(channel in ("nightly", "draft-stable", "finalize-stable", "stable"), f"Unsupported channel: {channel!r}")
    require(isinstance(sha, str) and _SHA_RE.fullmatch(sha) is not None, f"Invalid commit SHA: {sha!r}")
    sha_lower = sha.lower()

    is_nightly = channel == "nightly"
    if is_nightly:
        require(tag in ("", "nightly"), f"--tag must be 'nightly' or omitted for --channel nightly, got {tag!r}")
        target_tag = "nightly"
        ver, assets = verify_ci(dist_dir=dist_dir, require_checksums=True, root=root)
        is_prerelease = True
        parsed_ver = parse_semver(ver)
    else:
        parsed_ver = validate_release_tag(tag, root=root, require_changelog=True)
        target_tag = tag
        ver, assets = verify_ci(dist_dir=dist_dir, tag=target_tag, require_checksums=True, root=root)
        is_prerelease = parsed_ver.is_prerelease

    sums_path = dist_dir / "SHA256SUMS"
    upload_paths = [*assets, sums_path]

    if dry_run:
        display_repo = repo or "<resolved-repo>"
        print(
            f"Dry run ({channel} -> {target_tag} @ {sha_lower[:7]} on {display_repo}): "
            + ", ".join(p.name for p in upload_paths),
            flush=True,
        )
        return

    target_repo = resolve_repository(repo, root=root)
    existing_releases = list_releases(target_repo, root=root)
    newer_stable = _newer_published_stable_releases(
        existing_releases,
        target_tag=target_tag,
        parsed_ver=parsed_ver,
    ) if not is_nightly else []
    is_latest_release = (not is_prerelease) and (not newer_stable)

    if channel in ("draft-stable", "stable"):
        exact_matches = [rel for rel in existing_releases if rel.get("tag_name") == target_tag]
        require(len(exact_matches) <= 1, f"Multiple GitHub releases found for tag {target_tag!r}")
        existing_for_tag = exact_matches[0] if exact_matches else None
        if existing_for_tag is not None and not existing_for_tag.get("draft"):
            raise ReleaseError(
                f"Release {target_tag!r} is already published; refusing to overwrite existing release"
            )
        if existing_for_tag is not None and channel == "stable":
            raise ReleaseError(
                f"Release {target_tag!r} already exists (including draft); remove it before retrying stable release"
            )
        if newer_stable and not allow_older:
            raise ReleaseError(
                f"Release {target_tag!r} must be newer than published stable release {newer_stable[-1]!r} "
                "(pass --allow-older or set SYNURANG_ALLOW_OLDER_RELEASE=1 for backport/maintenance releases)"
            )
        changelog = extract_changelog(ver, root=root, required=not is_prerelease)
    elif channel == "finalize-stable":
        exact_matches = [rel for rel in existing_releases if rel.get("tag_name") == target_tag]
        require(len(exact_matches) == 1, f"Draft release {target_tag!r} not found")
        existing_for_tag = exact_matches[0]
        require(existing_for_tag.get("draft") is True, f"Release {target_tag!r} is not a draft")
        verify_release_assets(
            target_repo,
            target_tag,
            upload_paths,
            expected_draft=True,
            expected_prerelease=is_prerelease,
            root=root,
        )
        edit_cmd = [
            "gh", "release", "edit", target_tag,
            "--repo", target_repo,
            "--draft=false",
        ]
        if is_prerelease:
            edit_cmd += ["--prerelease", "--latest=false"]
        else:
            edit_cmd += ["--prerelease=false", "--latest" if is_latest_release else "--latest=false"]
        subprocess.run(edit_cmd, cwd=root, check=True)
        print(f"Finalized https://github.com/{target_repo}/releases/tag/{target_tag}", flush=True)
        return
    else:
        nightly_matches = [rel for rel in existing_releases if rel.get("tag_name") == "nightly"]
        require(len(nightly_matches) <= 1, "Multiple 'nightly' releases found; clean up duplicates first")
        existing_for_tag = nightly_matches[0] if nightly_matches else None
        if existing_for_tag is not None:
            require(
                existing_for_tag.get("prerelease") is True,
                "Existing 'nightly' release is not marked as a prerelease; refusing overwrite",
            )
        changelog = ""

    with tempfile.TemporaryDirectory(prefix="synurang-release-ci-") as tmp:
        work = Path(tmp)
        staging = work / "assets"
        staging.mkdir()
        staged_paths: list[Path] = []
        for src in upload_paths:
            dst = staging / src.name
            shutil.copy2(src, dst)
            staged_paths.append(dst)
        notes_file = work / "notes.md"
        notes_file.write_text(
            _ci_release_notes(channel, ver, sha=sha_lower, tag=target_tag, changelog=changelog, is_prerelease=is_prerelease),
            encoding="utf-8",
        )

        if not is_nightly:
            title = f"Synurang {target_tag}"
            if existing_for_tag is None:
                create_cmd = [
                    "gh", "release", "create", target_tag,
                    *(str(p) for p in staged_paths),
                    "--repo", target_repo,
                    "--target", sha_lower,
                    "--draft",
                    *(["--prerelease"] if is_prerelease else []),
                    "--title", title,
                    "--notes-file", str(notes_file),
                ]
                subprocess.run(create_cmd, cwd=root, check=True)
            else:
                expected_names = {p.name for p in staged_paths}
                draft_id = existing_for_tag.get("id")
                existing_assets = (
                    list_release_assets(target_repo, draft_id, root=root)
                    if _is_positive_int(draft_id)
                    else (existing_for_tag.get("assets") or [])
                )
                for stale in [
                    item["name"] for item in existing_assets
                    if isinstance(item, dict) and item.get("name") and item["name"] not in expected_names
                ]:
                    subprocess.run(
                        ["gh", "release", "delete-asset", target_tag, stale, "--repo", target_repo, "--yes"],
                        cwd=root,
                        check=True,
                    )
                subprocess.run(
                    [
                        "gh", "release", "upload", target_tag,
                        *(str(p) for p in staged_paths),
                        "--repo", target_repo,
                        "--clobber",
                    ],
                    cwd=root,
                    check=True,
                )
                subprocess.run(
                    [
                        "gh", "release", "edit", target_tag,
                        "--repo", target_repo,
                        "--draft=true",
                        *(["--prerelease"] if is_prerelease else ["--prerelease=false"]),
                        "--target", sha_lower,
                        "--title", title,
                        "--notes-file", str(notes_file),
                    ],
                    cwd=root,
                    check=True,
                )

            verify_release_assets(
                target_repo,
                target_tag,
                staged_paths,
                expected_draft=True,
                expected_prerelease=is_prerelease,
                root=root,
            )
            if channel == "stable":
                edit_cmd = [
                    "gh", "release", "edit", target_tag,
                    "--repo", target_repo,
                    "--draft=false",
                ]
                if is_prerelease:
                    edit_cmd += ["--prerelease", "--latest=false"]
                else:
                    edit_cmd += ["--prerelease=false", "--latest" if is_latest_release else "--latest=false"]
                subprocess.run(edit_cmd, cwd=root, check=True)
                print(f"Published https://github.com/{target_repo}/releases/tag/{target_tag}", flush=True)
            else:
                print(f"Prepared verified draft release {target_tag} on {target_repo}", flush=True)
            return

        # Rolling nightly prerelease
        title = f"Synurang nightly ({sha_lower[:7]})"
        if existing_for_tag is None:
            subprocess.run(
                [
                    "gh", "release", "create", "nightly",
                    *(str(p) for p in staged_paths),
                    "--repo", target_repo,
                    "--target", sha_lower,
                    "--draft",
                    "--prerelease",
                    "--latest=false",
                    "--title", title,
                    "--notes-file", str(notes_file),
                ],
                cwd=root,
                check=True,
            )
            verify_release_assets(
                target_repo,
                "nightly",
                staged_paths,
                expected_draft=True,
                expected_prerelease=True,
                root=root,
            )
            subprocess.run(
                [
                    "gh", "release", "edit", "nightly",
                    "--repo", target_repo,
                    "--draft=false",
                    "--prerelease",
                    "--latest=false",
                ],
                cwd=root,
                check=True,
            )
        else:
            expected_names = {p.name for p in staged_paths}
            nightly_id = existing_for_tag.get("id")
            existing_assets = (
                list_release_assets(target_repo, nightly_id, root=root)
                if _is_positive_int(nightly_id)
                else (existing_for_tag.get("assets") or [])
            )
            stale_names = [
                item["name"] for item in existing_assets
                if isinstance(item, dict) and item.get("name") and item["name"] not in expected_names
            ]
            subprocess.run(
                [
                    "gh", "release", "upload", "nightly",
                    *(str(p) for p in staged_paths),
                    "--repo", target_repo,
                    "--clobber",
                ],
                cwd=root,
                check=True,
            )
            for stale in stale_names:
                subprocess.run(
                    ["gh", "release", "delete-asset", "nightly", stale, "--repo", target_repo, "--yes"],
                    cwd=root,
                    check=True,
                )
            verify_release_assets(
                target_repo,
                "nightly",
                staged_paths,
                expected_draft=None,
                expected_prerelease=True,
                root=root,
            )
            update_nightly_git_ref(target_repo, sha_lower, root=root)
            subprocess.run(
                [
                    "gh", "release", "edit", "nightly",
                    "--repo", target_repo,
                    "--draft=false",
                    "--prerelease",
                    "--latest=false",
                    "--target", sha_lower,
                    "--title", title,
                    "--notes-file", str(notes_file),
                ],
                cwd=root,
                check=True,
            )
        print(f"Updated https://github.com/{target_repo}/releases/tag/nightly ({sha_lower[:7]})", flush=True)


def _write_maven_checksums(path: Path) -> tuple[Path, Path]:
    data = path.read_bytes()
    md5_path = Path(f"{path}.md5")
    sha1_path = Path(f"{path}.sha1")
    md5_path.write_text(hashlib.md5(data).hexdigest(), encoding="utf-8")
    sha1_path.write_text(hashlib.sha1(data).hexdigest(), encoding="utf-8")
    return md5_path, sha1_path


def _gpg_sign_file(file_path: Path, *, gnupghome: Path, gpg_passphrase: str = "") -> Path:
    asc_path = Path(f"{file_path}.asc")
    cmd = [
        "gpg",
        "--homedir", str(gnupghome),
        "--batch",
        "--yes",
        "--pinentry-mode", "loopback",
        "--armor",
        "--detach-sign",
        "--output", str(asc_path),
    ]
    if gpg_passphrase:
        cmd.extend(["--passphrase-fd", "0"])
    else:
        cmd.extend(["--passphrase", ""])
    cmd.extend(["--", str(file_path)])
    env = os.environ.copy()
    env["GNUPGHOME"] = str(gnupghome)
    res = subprocess.run(
        cmd,
        input=gpg_passphrase if gpg_passphrase else None,
        check=False,
        env=env,
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        detail = res.stderr.strip() or res.stdout.strip() or f"exit {res.returncode}"
        raise ReleaseError(f"Failed to GPG-sign {file_path.name}: {detail}")
    require(asc_path.is_file() and asc_path.stat().st_size > 0, f"GPG signature not created: {asc_path}")
    return asc_path


def build_maven_bundle_zip(
    *,
    dist_dir: Path,
    version: str,
    out_zip: Path,
    artifacts: tuple[tuple[str, str], ...] | None = None,
    artifact: str | None = None,
    ext: str | None = None,
    sign_fn=None,
) -> Path:
    if artifacts is not None:
        selected = artifacts
    elif artifact is not None and ext is not None:
        selected = ((artifact, ext),)
    else:
        selected = tuple((a, e) for a, e, _ in MAVEN_ARTIFACTS)

    group_path = Path(*MAVEN_GROUP_ID.split("."))
    with tempfile.TemporaryDirectory(prefix="synurang-maven-bundle-") as tmp:
        stage_root = Path(tmp)
        all_files: list[Path] = []
        for art_id, art_ext in selected:
            files = [
                dist_dir / f"{art_id}-{version}.{art_ext}",
                dist_dir / f"{art_id}-{version}.pom",
                dist_dir / f"{art_id}-{version}-sources.jar",
                dist_dir / f"{art_id}-{version}-javadoc.jar",
            ]
            for src in files:
                require(src.is_file(), f"Missing Maven artifact for bundle: {src}")
            target_dir = stage_root / group_path / art_id / version
            target_dir.mkdir(parents=True, exist_ok=True)
            for src in files:
                dst = target_dir / src.name
                shutil.copy2(src, dst)
                md5_path, sha1_path = _write_maven_checksums(dst)
                all_files.extend([dst, md5_path, sha1_path])
                if sign_fn is not None:
                    asc_path = sign_fn(dst)
                    all_files.append(asc_path)

        with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            for item in sorted(all_files, key=lambda p: p.relative_to(stage_root).as_posix()):
                zf.write(item, arcname=item.relative_to(stage_root).as_posix())
    return out_zip


def _maven_curl_auth_config(username: str, password: str) -> str:
    require("\r" not in username and "\n" not in username, "SONATYPE_USERNAME must not contain newlines")
    require("\r" not in password and "\n" not in password, "SONATYPE_PASSWORD must not contain newlines")
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return f'header = "Authorization: Bearer {token}"\n'


def _validate_http_url(url: str, *, label: str) -> str:
    require(isinstance(url, str) and bool(url.strip()), f"{label} must not be empty")
    normalized = url.strip()
    require(not any(ch.isspace() for ch in normalized), f"Invalid {label}: {url!r}")
    parsed = urllib_parse.urlsplit(normalized)
    require(
        parsed.scheme in ("http", "https") and bool(parsed.netloc) and bool(parsed.hostname),
        f"Invalid {label}: {url!r}",
    )
    return normalized


def _derive_maven_status_url(upload_url: str, status_url: str | None = None) -> str:
    normalized_upload = _validate_http_url(upload_url, label="Maven upload URL")
    if status_url is not None:
        return _validate_http_url(status_url, label="Maven status URL")
    parsed = urllib_parse.urlsplit(normalized_upload)
    require(
        parsed.path.endswith("/upload"),
        f"Cannot derive Maven status URL from upload URL {upload_url!r} "
        "(expected path ending with '/upload' or pass --status-url)",
    )
    status_path = parsed.path[: -len("/upload")] + "/status"
    return urllib_parse.urlunsplit((parsed.scheme, parsed.netloc, status_path, "", ""))


def _upload_maven_bundle_curl(
    *,
    bundle_zip: Path,
    bundle_name: str,
    username: str,
    password: str,
    upload_url: str,
    publishing_type: str = "AUTOMATIC",
) -> str:
    require(publishing_type in MAVEN_PUBLISHING_TYPES, f"Unsupported publishing_type: {publishing_type!r}")
    require(shutil.which("curl") is not None, "curl is required to upload bundles to Maven Central")
    parsed = urllib_parse.urlsplit(upload_url)
    query = [
        (k, v)
        for k, v in urllib_parse.parse_qsl(parsed.query, keep_blank_values=True)
        if k not in ("name", "publishingType")
    ]
    query.extend([("name", bundle_name), ("publishingType", publishing_type)])
    target_url = urllib_parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path, urllib_parse.urlencode(query), parsed.fragment)
    )
    config_text = _maven_curl_auth_config(username, password)
    cmd = [
        "curl",
        "-sS",
        "-K", "-",
        "--max-time", "300",
        "-w", "\n%{http_code}",
        "-X", "POST",
        target_url,
        "-F", f"bundle=@{bundle_zip}",
    ]
    res = subprocess.run(cmd, input=config_text, text=True, capture_output=True, check=False)
    if res.returncode != 0:
        raise ReleaseError(f"curl upload failed for {bundle_name}: {res.stderr.strip()}")
    lines = res.stdout.rstrip("\n").splitlines()
    code_str = lines[-1] if lines else ""
    body = "\n".join(lines[:-1])
    require(code_str.isdigit(), f"Unexpected HTTP status output uploading {bundle_name}: {res.stdout!r}")
    http_code = int(code_str)
    if not (200 <= http_code < 300):
        raise ReleaseError(f"Maven Central rejected {bundle_name} (HTTP {http_code}): {body}")
    deployment_id = body.strip()
    if len(deployment_id) >= 2 and deployment_id.startswith('"') and deployment_id.endswith('"'):
        deployment_id = deployment_id[1:-1].strip()
    require(
        bool(deployment_id) and "\n" not in deployment_id and "\r" not in deployment_id,
        f"Maven Central upload succeeded (HTTP {http_code}) but returned invalid deploymentId: {body!r}",
    )
    print(f"Uploaded {bundle_name} to Maven Central (HTTP {http_code}, deploymentId={deployment_id})", flush=True)
    return deployment_id


class _TransientMavenStatusError(ReleaseError):
    """Raised when a Maven Central deployment status poll fails transiently and can be retried."""


def _kill_gpg_agent(gnupghome: Path) -> None:
    if shutil.which("gpgconf") is None or not gnupghome.is_dir():
        return
    env = os.environ.copy()
    env["GNUPGHOME"] = str(gnupghome)
    subprocess.run(
        ["gpgconf", "--homedir", str(gnupghome), "--kill", "gpg-agent"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def _check_maven_deployment_status_once(
    *,
    deployment_id: str,
    username: str,
    password: str,
    status_url: str,
) -> dict:
    require(shutil.which("curl") is not None, "curl is required to check Maven Central deployment status")
    parsed = urllib_parse.urlsplit(status_url)
    query = [(k, v) for k, v in urllib_parse.parse_qsl(parsed.query, keep_blank_values=True) if k != "id"]
    query.append(("id", deployment_id))
    target_url = urllib_parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path, urllib_parse.urlencode(query), parsed.fragment)
    )
    config_text = _maven_curl_auth_config(username, password)
    cmd = [
        "curl",
        "-sS",
        "-K", "-",
        "--max-time", "60",
        "-w", "\n%{http_code}",
        "-X", "POST",
        target_url,
    ]
    res = subprocess.run(cmd, input=config_text, text=True, capture_output=True, check=False)
    if res.returncode != 0:
        raise _TransientMavenStatusError(f"curl status check failed for {deployment_id} (exit {res.returncode}): {res.stderr.strip()}")
    lines = res.stdout.rstrip("\n").splitlines()
    code_str = lines[-1] if lines else ""
    body = "\n".join(lines[:-1])
    if not code_str.isdigit():
        raise _TransientMavenStatusError(f"Unexpected HTTP status checking Maven deployment {deployment_id}: {res.stdout!r}")
    http_code = int(code_str)
    if http_code in (404, 408, 429) or 500 <= http_code < 600:
        raise _TransientMavenStatusError(f"Maven Central status check returned transient HTTP {http_code} for {deployment_id}: {body}")
    if not (200 <= http_code < 300):
        raise ReleaseError(f"Maven Central status check failed for {deployment_id} (HTTP {http_code}): {body}")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as err:
        raise _TransientMavenStatusError(f"Maven Central returned invalid JSON status for {deployment_id}: {body!r}") from err
    require(isinstance(payload, dict), f"Maven Central returned non-object JSON status for {deployment_id}: {payload!r}")
    return payload


def _wait_maven_deployment(
    *,
    deployment_id: str,
    username: str,
    password: str,
    status_url: str,
    publishing_type: str = "AUTOMATIC",
    poll_interval: float = DEFAULT_MAVEN_POLL_INTERVAL,
    poll_timeout: float = DEFAULT_MAVEN_POLL_TIMEOUT,
    max_transient_errors: int = 5,
) -> dict:
    require(publishing_type in MAVEN_PUBLISHING_TYPES, f"Unsupported publishing_type: {publishing_type!r}")
    require(poll_interval >= 0, f"poll_interval must be >= 0, got {poll_interval}")
    require(poll_timeout >= 0, f"poll_timeout must be >= 0, got {poll_timeout}")
    require(max_transient_errors >= 1, f"max_transient_errors must be >= 1, got {max_transient_errors}")
    target_state = "PUBLISHED" if publishing_type == "AUTOMATIC" else "VALIDATED"
    deadline = time.monotonic() + poll_timeout
    last_state: str | None = None
    consecutive_errors = 0
    while True:
        try:
            payload = _check_maven_deployment_status_once(
                deployment_id=deployment_id,
                username=username,
                password=password,
                status_url=status_url,
            )
            consecutive_errors = 0
        except _TransientMavenStatusError as err:
            consecutive_errors += 1
            remaining = deadline - time.monotonic()
            if consecutive_errors >= max_transient_errors or remaining <= 0:
                raise ReleaseError(
                    f"Maven Central status polling aborted after {consecutive_errors} consecutive transient error(s) "
                    f"for deployment {deployment_id}: {err}"
                ) from err
            backoff = 0.0 if poll_interval == 0.0 else min(remaining, min(60.0, poll_interval * (2 ** (consecutive_errors - 1))))
            print(
                f"Transient error polling Maven Central deployment {deployment_id} "
                f"(attempt {consecutive_errors}/{max_transient_errors}): {err}; retrying in {backoff:.2f}s",
                flush=True,
            )
            time.sleep(backoff)
            continue

        state = payload.get("deploymentState")
        require(isinstance(state, str) and state, f"Missing deploymentState in Maven Central response: {payload!r}")
        if state != last_state:
            print(f"Maven Central deployment {deployment_id} state: {state}", flush=True)
            last_state = state
        if state in (target_state, "PUBLISHED"):
            return payload
        if state == "FAILED":
            errors = payload.get("errors")
            raise ReleaseError(
                f"Maven Central validation/publishing FAILED for deployment {deployment_id}: {json.dumps(errors or payload)}"
            )
        if state not in ("PENDING", "VALIDATING", "VALIDATED", "PUBLISHING"):
            raise ReleaseError(f"Unexpected Maven Central deployment state {state!r} for {deployment_id}: {payload!r}")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ReleaseError(
                f"Timed out after {poll_timeout:.2f}s waiting for Maven Central deployment {deployment_id} "
                f"(expected {target_state}, last state={last_state!r})"
            )
        time.sleep(min(poll_interval, remaining))


def _write_secret_file(path: Path, text: str) -> Path:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        fh = os.fdopen(fd, "w", encoding="utf-8")
    except BaseException:
        os.close(fd)
        raise
    with fh:
        fh.write(text)
    os.chmod(path, 0o600)
    return path


def _gpg_sign_file_local(
    file_path: Path,
    *,
    gpg_key: str = "",
    gpg_passphrase: str = "",
) -> Path:
    asc_path = Path(f"{file_path}.asc")
    if gpg_passphrase:
        cmd = [
            "gpg",
            "--batch",
            "--yes",
            "--pinentry-mode", "loopback",
            "--armor",
            "--detach-sign",
            "--passphrase-fd", "0",
        ]
        if gpg_key:
            cmd.extend(["--local-user", gpg_key])
        cmd.extend(["--output", str(asc_path), "--", str(file_path)])
        res = subprocess.run(cmd, input=gpg_passphrase, check=False, capture_output=True, text=True)
        if res.returncode != 0:
            detail = res.stderr.strip() or res.stdout.strip() or f"exit {res.returncode}"
            raise ReleaseError(f"Failed to GPG-sign {file_path.name}: {detail}")
    else:
        cmd = [
            "gpg",
            "--yes",
            "--armor",
            "--detach-sign",
        ]
        if gpg_key:
            cmd.extend(["--local-user", gpg_key])
        cmd.extend(["--output", str(asc_path), "--", str(file_path)])
        env = os.environ.copy()
        if (
            not env.get("GPG_TTY", "").strip()
            and sys.stdin is not None
            and sys.stdin.isatty()
            and hasattr(os, "ttyname")
        ):
            try:
                env["GPG_TTY"] = os.ttyname(sys.stdin.fileno())
            except OSError:
                pass
        res = subprocess.run(cmd, check=False, env=env)
        if res.returncode != 0:
            raise ReleaseError(
                f"Failed to GPG-sign {file_path.name} (gpg exit {res.returncode}). "
                "For SSH or non-interactive sessions without a cached gpg-agent passphrase, "
                "export GPG_TTY=$(tty) or set MAVEN_GPG_PASSPHRASE."
            )
    require(asc_path.is_file() and asc_path.stat().st_size > 0, f"GPG signature not created: {asc_path}")
    return asc_path


def _parse_maven_settings_credentials(settings_path: Path, *, server_id: str = "central") -> tuple[str, str]:
    require(
        settings_path.is_file(),
        f"Maven settings not found: {settings_path} (create it or set SONATYPE_USERNAME/SONATYPE_PASSWORD)",
    )
    target_server_id = server_id.strip()
    require(bool(target_server_id), "Maven settings server_id must not be empty")
    try:
        tree = ET.parse(settings_path)
    except ET.ParseError as err:
        raise ReleaseError(f"Malformed Maven settings XML in {settings_path}: {err}") from err
    root = tree.getroot()
    ns = ""
    if root.tag.startswith("{"):
        ns = root.tag[: root.tag.index("}") + 1]

    def raw_text_of(elem: ET.Element, tag: str) -> str:
        child = elem.find(f"{ns}{tag}")
        return child.text if child is not None and child.text is not None else ""

    matches = [
        server
        for server in root.findall(f"{ns}servers/{ns}server")
        if raw_text_of(server, "id").strip() == target_server_id
    ]
    require(
        len(matches) <= 1,
        f"Duplicate <server><id>{target_server_id}</id> entries in {settings_path}",
    )
    require(
        len(matches) == 1,
        f"Server {target_server_id!r} not found in {settings_path} (pass --server-id to select another <server>)",
    )
    server = matches[0]
    raw_username = raw_text_of(server, "username")
    raw_password = raw_text_of(server, "password")
    require("\r" not in raw_username and "\n" not in raw_username, f"Invalid newline in <username> in {settings_path}")
    require("\r" not in raw_password and "\n" not in raw_password, f"Invalid newline in <password> in {settings_path}")
    username = raw_username.strip()
    password = raw_password
    require(bool(username), f"Missing <username> for server {target_server_id!r} in {settings_path}")
    require(bool(password.strip()), f"Missing <password> for server {target_server_id!r} in {settings_path}")
    if password.startswith("{") and password.endswith("}"):
        raise ReleaseError(
            f"Encrypted Maven <password> ({{...}}) is not supported in {settings_path}; "
            "use a plaintext Sonatype Central User Token in <password> or set SONATYPE_USERNAME/SONATYPE_PASSWORD"
        )
    return username, password


def _resolve_local_maven_credentials(*, settings_path: Path, server_id: str = "central") -> tuple[str, str]:
    raw_user = os.environ.get("SONATYPE_USERNAME", "")
    raw_pass = os.environ.get("SONATYPE_PASSWORD", "")
    if raw_user or raw_pass:
        require("\r" not in raw_user and "\n" not in raw_user, "SONATYPE_USERNAME must not contain newlines")
        require("\r" not in raw_pass and "\n" not in raw_pass, "SONATYPE_PASSWORD must not contain newlines")
        env_user = raw_user.strip()
        env_pass = raw_pass
        require(
            bool(env_user) and bool(env_pass.strip()),
            "Both SONATYPE_USERNAME and SONATYPE_PASSWORD must be set when using environment credentials",
        )
        return env_user, env_pass
    return _parse_maven_settings_credentials(settings_path, server_id=server_id)


def _download_maven_from_github_release(
    *,
    tag: str,
    version: str,
    repo: str = "",
    download_dir: Path,
    allow_prerelease: bool = False,
    allow_draft: bool = False,
    root: Path = ROOT,
) -> None:
    require(shutil.which("gh") is not None, "gh CLI is required to download GitHub release assets")
    target_repo = resolve_repository(repo, root=root)
    matches = [rel for rel in list_releases(target_repo, root=root) if rel.get("tag_name") == tag]
    require(len(matches) == 1, f"Expected one GitHub release for tag {tag!r} on {target_repo}, found {len(matches)}")
    release = matches[0]
    is_draft = release.get("draft") is True
    if is_draft and not allow_draft:
        raise ReleaseError(f"GitHub release {tag!r} is a draft (pass --allow-draft to override)")
    if release.get("prerelease") is True and not allow_prerelease:
        raise ReleaseError(
            f"GitHub release {tag!r} is a prerelease (pass --allow-prerelease to override)"
        )

    release_id = release.get("id")
    if _is_positive_int(release_id):
        actual_assets = list_release_assets(target_repo, release_id, root=root)
    else:
        actual_assets = release.get("assets") or []
    require(isinstance(actual_assets, list), f"Invalid asset payload on release {tag!r}")

    asset_by_name = {
        item.get("name"): item
        for item in actual_assets
        if isinstance(item, dict) and item.get("name")
    }
    expected_maven = expected_maven_filenames(version)
    required_assets = expected_maven | {"SHA256SUMS"}
    missing_remote = sorted(required_assets - set(asset_by_name))
    require(
        not missing_remote,
        f"GitHub release {tag!r} is missing expected Maven/checksum asset(s): {', '.join(missing_remote)}",
    )
    for name in sorted(required_assets):
        meta = asset_by_name[name]
        if meta.get("state") != "uploaded" or not _is_positive_int(meta.get("size")):
            raise ReleaseError(
                f"GitHub release asset {name!r} on {tag!r} is incomplete (state={meta.get('state')!r}, size={meta.get('size')!r})"
            )
        asset_id = meta.get("id")
        if is_draft and not _is_positive_int(asset_id):
            raise ReleaseError(f"GitHub release asset {name!r} on draft {tag!r} lacks a valid asset id")
        digest = meta.get("digest")
        if not isinstance(digest, str) or not _GITHUB_DIGEST_RE.fullmatch(digest):
            raise ReleaseError(f"GitHub release asset {name!r} on {tag!r} lacks a valid SHA-256 digest: {digest!r}")

    if download_dir.exists():
        require(
            download_dir.is_dir() and not download_dir.is_symlink(),
            f"Download target must be a directory: {download_dir}",
        )
    download_dir.mkdir(parents=True, exist_ok=True)
    gh_host = _resolve_gh_host()
    if is_draft:
        # Draft releases do not have a finalized git tag, so fetch directly by asset ID
        # instead of `gh release download <tag>` which can fail with 404.
        for name in sorted(required_assets):
            asset_id = asset_by_name[name]["id"]
            local_path = download_dir / name
            cmd = [
                "gh", "api", "--hostname", gh_host,
                "-H", "Accept: application/octet-stream",
                f"repos/{target_repo}/releases/assets/{asset_id}",
            ]
            with local_path.open("wb") as fh:
                res = subprocess.run(cmd, cwd=root, stdout=fh, stderr=subprocess.PIPE, check=False)
            if res.returncode != 0:
                local_path.unlink(missing_ok=True)
                detail = res.stderr.decode("utf-8", errors="replace").strip() or f"exit {res.returncode}"
                raise ReleaseError(f"gh api failed downloading draft asset {name!r} (id={asset_id}): {detail}")
    else:
        dl_cmd = [
            "gh", "release", "download", tag,
            "--repo", f"{gh_host}/{target_repo}",
            "--dir", str(download_dir),
            "--clobber",
        ]
        for name in sorted(required_assets):
            dl_cmd.extend(["-p", name])
        res = subprocess.run(dl_cmd, cwd=root, capture_output=True, text=True, check=False)
        if res.returncode != 0:
            detail = (res.stderr or "").strip() or (res.stdout or "").strip() or f"exit {res.returncode}"
            raise ReleaseError(f"gh release download failed for {tag!r}: {detail}")

    local_sha256_by_name: dict[str, str] = {}
    for name in sorted(required_assets):
        local_path = download_dir / name
        require(local_path.is_file() and not local_path.is_symlink(), f"Downloaded asset missing: {local_path}")
        actual_size = local_path.stat().st_size
        meta = asset_by_name[name]
        require(
            actual_size == meta["size"],
            f"Downloaded asset {name!r} size mismatch: local={actual_size} github={meta['size']}",
        )
        actual_hex = _sha256_file(local_path)
        actual_digest = "sha256:" + actual_hex
        require(
            actual_digest == meta["digest"],
            f"Downloaded asset {name!r} digest mismatch: local={actual_digest} github={meta['digest']}",
        )
        local_sha256_by_name[name] = actual_hex

    parsed_sums = _parse_sha256sums(download_dir / "SHA256SUMS")
    for name in sorted(expected_maven):
        require(name in parsed_sums, f"SHA256SUMS on release {tag!r} is missing entry for {name}")
        actual_hex = local_sha256_by_name[name]
        require(
            parsed_sums[name] == actual_hex,
            f"SHA256SUMS mismatch for {name}: manifest={parsed_sums[name]} actual={actual_hex}",
        )

    verify_maven(download_dir, version=version)


def _publish_signed_maven_bundle(
    *,
    dist_dir: Path,
    version: str,
    username: str,
    password: str,
    upload_url: str,
    status_url: str | None,
    publishing_type: str,
    poll_interval: float,
    poll_timeout: float,
    max_transient_errors: int,
    sign_fn,
) -> dict[str, str]:
    bundle_name = f"synurang-{version}"
    resolved_status_url = _derive_maven_status_url(upload_url, status_url)
    with tempfile.TemporaryDirectory(prefix="synurang-maven-upload-") as tmp:
        bundle_zip = Path(tmp) / f"{bundle_name}-maven-bundle.zip"
        build_maven_bundle_zip(
            dist_dir=dist_dir,
            version=version,
            out_zip=bundle_zip,
            sign_fn=sign_fn,
        )
        signed_files = _validate_zip_container(bundle_zip)
        require(
            len(signed_files) == len(MAVEN_ARTIFACTS) * 4 * 4,
            f"Expected {len(MAVEN_ARTIFACTS) * 16} signed files in Maven bundle, got {len(signed_files)}",
        )
        deployment_id = _upload_maven_bundle_curl(
            bundle_zip=bundle_zip,
            bundle_name=bundle_name,
            username=username,
            password=password,
            upload_url=upload_url,
            publishing_type=publishing_type,
        )
        final_status = _wait_maven_deployment(
            deployment_id=deployment_id,
            username=username,
            password=password,
            status_url=resolved_status_url,
            publishing_type=publishing_type,
            poll_interval=poll_interval,
            poll_timeout=poll_timeout,
            max_transient_errors=max_transient_errors,
        )
        final_state = str(final_status.get("deploymentState", ""))
    return {"bundle": bundle_name, "deployment_id": deployment_id, "state": final_state}


def publish_maven_ci(
    *,
    dist_dir: Path,
    tag: str = "",
    version: str = "",
    upload_url: str = MAVEN_UPLOAD_URL,
    status_url: str | None = None,
    publishing_type: str = "AUTOMATIC",
    poll_interval: float = DEFAULT_MAVEN_POLL_INTERVAL,
    poll_timeout: float = DEFAULT_MAVEN_POLL_TIMEOUT,
    max_transient_errors: int = 5,
    allow_prerelease: bool = False,
    dry_run: bool = False,
    root: Path = ROOT,
) -> dict[str, str]:
    require(publishing_type in MAVEN_PUBLISHING_TYPES, f"Unsupported publishing_type: {publishing_type!r}")
    require(not (tag and version), "Specify either --tag or --version, not both")
    if tag:
        parsed_ver = validate_release_tag(tag, root=root)
    elif version:
        parsed_ver = parse_semver(version)
    else:
        parsed_ver = parse_semver(check_versions(root))
    ver = parsed_ver.raw
    if parsed_ver.is_prerelease and not allow_prerelease:
        raise ReleaseError(
            f"Refusing to publish prerelease version {ver!r} to Maven Central (pass --allow-prerelease to override)"
        )
    normalized_upload_url = _validate_http_url(upload_url, label="Maven upload URL")
    resolved_status_url = _derive_maven_status_url(normalized_upload_url, status_url)

    verify_maven(dist_dir, version=ver)

    bundle_name = f"synurang-{ver}"
    if dry_run:
        with tempfile.TemporaryDirectory(prefix="synurang-maven-dryrun-") as tmp:
            bundle_zip = Path(tmp) / f"{bundle_name}-maven-bundle.zip"
            build_maven_bundle_zip(dist_dir=dist_dir, version=ver, out_zip=bundle_zip)
            files = _validate_zip_container(bundle_zip)
            require(len(files) == len(MAVEN_ARTIFACTS) * 4 * 3, f"Unexpected dry-run Maven bundle file count: {len(files)}")
        artifact_list = ", ".join(f"{artifact}-{ver}" for artifact, _, _ in MAVEN_ARTIFACTS)
        print(f"Dry run (Maven Central -> {normalized_upload_url}): {bundle_name} ({artifact_list})", flush=True)
        return {"bundle": bundle_name, "deployment_id": "dry-run", "state": "DRY_RUN"}

    raw_username = os.environ.get("SONATYPE_USERNAME", "")
    raw_password = os.environ.get("SONATYPE_PASSWORD", "")
    require("\r" not in raw_username and "\n" not in raw_username, "SONATYPE_USERNAME must not contain newlines")
    require("\r" not in raw_password and "\n" not in raw_password, "SONATYPE_PASSWORD must not contain newlines")
    username = raw_username.strip()
    password = raw_password
    gpg_key = os.environ.get("MAVEN_GPG_PRIVATE_KEY", "")
    gpg_passphrase = os.environ.get("MAVEN_GPG_PASSPHRASE", "")

    require(bool(username), "SONATYPE_USERNAME environment variable is required")
    require(bool(password.strip()), "SONATYPE_PASSWORD environment variable is required")
    require(bool(gpg_key.strip()), "MAVEN_GPG_PRIVATE_KEY environment variable is required")
    require(shutil.which("gpg") is not None, "gpg is required to sign Maven Central artifacts")
    require(shutil.which("curl") is not None, "curl is required to upload bundles to Maven Central")

    with tempfile.TemporaryDirectory(prefix="synurang-gnupg-") as gpg_tmp:
        gnupghome = Path(gpg_tmp) / "gnupg"
        gnupghome.mkdir(mode=0o700)
        os.chmod(gnupghome, 0o700)
        try:
            passphrase_file: Path | None = None
            if gpg_passphrase:
                passphrase_file = _write_secret_file(Path(gpg_tmp) / "passphrase", gpg_passphrase)

            env = os.environ.copy()
            env["GNUPGHOME"] = str(gnupghome)
            import_cmd = [
                "gpg",
                "--homedir", str(gnupghome),
                "--batch",
                "--yes",
                "--pinentry-mode", "loopback",
            ]
            if passphrase_file is not None:
                import_cmd.extend(["--passphrase-file", str(passphrase_file)])
            else:
                import_cmd.extend(["--passphrase", ""])
            import_cmd.append("--import")
            try:
                imp = subprocess.run(import_cmd, input=gpg_key, text=True, capture_output=True, env=env, check=False)
            finally:
                if passphrase_file is not None:
                    passphrase_file.unlink(missing_ok=True)
            require(imp.returncode == 0, f"Failed to import MAVEN_GPG_PRIVATE_KEY: {imp.stderr.strip()}")

            return _publish_signed_maven_bundle(
                dist_dir=dist_dir,
                version=ver,
                username=username,
                password=password,
                upload_url=normalized_upload_url,
                status_url=resolved_status_url,
                publishing_type=publishing_type,
                poll_interval=poll_interval,
                poll_timeout=poll_timeout,
                max_transient_errors=max_transient_errors,
                sign_fn=lambda path: _gpg_sign_file(path, gnupghome=gnupghome, gpg_passphrase=gpg_passphrase),
            )
        finally:
            _kill_gpg_agent(gnupghome)


def publish_maven_local(
    *,
    dist_dir: Path | None = None,
    tag: str = "",
    version: str = "",
    repo: str = "",
    settings_path: Path | None = None,
    server_id: str = "central",
    gpg_key: str = "",
    upload_url: str = MAVEN_UPLOAD_URL,
    status_url: str | None = None,
    publishing_type: str = "AUTOMATIC",
    poll_interval: float = DEFAULT_MAVEN_POLL_INTERVAL,
    poll_timeout: float = DEFAULT_MAVEN_POLL_TIMEOUT,
    max_transient_errors: int = 5,
    allow_prerelease: bool = False,
    allow_draft: bool = False,
    dry_run: bool = False,
    root: Path = ROOT,
) -> dict[str, str]:
    require(publishing_type in MAVEN_PUBLISHING_TYPES, f"Unsupported publishing_type: {publishing_type!r}")
    require(bool(tag) ^ (dist_dir is not None), "Specify exactly one of --tag or --dist")
    if tag:
        require(tag.startswith("v"), f"Release tag must start with 'v': {tag!r}")
        require(not version, "Do not pass --version together with --tag")
        ver = tag[1:]
    else:
        assert dist_dir is not None
        require(not repo, "Do not pass --repo together with --dist")
        require(not allow_draft, "Do not pass --allow-draft together with --dist")
        ver = version if version else check_versions(root)
    parsed_ver = parse_semver(ver)
    if parsed_ver.is_prerelease and not allow_prerelease:
        raise ReleaseError(
            f"Refusing to publish prerelease version {ver!r} to Maven Central (pass --allow-prerelease to override)"
        )

    normalized_upload_url = _validate_http_url(upload_url, label="Maven upload URL")
    resolved_status_url = _derive_maven_status_url(normalized_upload_url, status_url)

    resolved_settings = settings_path if settings_path is not None else (root / ".maven-settings.xml")
    resolved_gpg_key = gpg_key.strip() or os.environ.get("MAVEN_GPG_KEY", "").strip()

    username = ""
    password = ""
    if not dry_run:
        username, password = _resolve_local_maven_credentials(
            settings_path=resolved_settings,
            server_id=server_id,
        )
        require(shutil.which("gpg") is not None, "gpg is required to sign Maven Central artifacts")
        require(shutil.which("curl") is not None, "curl is required to upload bundles to Maven Central")

    with tempfile.TemporaryDirectory(prefix="synurang-maven-local-") as work_tmp:
        work_path = Path(work_tmp)
        if tag:
            maven_dir = work_path / "downloaded-maven"
            _download_maven_from_github_release(
                tag=tag,
                version=ver,
                repo=repo,
                download_dir=maven_dir,
                allow_prerelease=allow_prerelease,
                allow_draft=allow_draft,
                root=root,
            )
        else:
            assert dist_dir is not None
            maven_dir = dist_dir
            verify_maven(maven_dir, version=ver)

        bundle_name = f"synurang-{ver}"
        if dry_run:
            bundle_zip = work_path / f"{bundle_name}-maven-bundle.zip"
            build_maven_bundle_zip(dist_dir=maven_dir, version=ver, out_zip=bundle_zip)
            files = _validate_zip_container(bundle_zip)
            require(
                len(files) == len(MAVEN_ARTIFACTS) * 4 * 3,
                f"Unexpected dry-run Maven bundle file count: {len(files)}",
            )
            artifact_list = ", ".join(f"{artifact}-{ver}" for artifact, _, _ in MAVEN_ARTIFACTS)
            print(f"Dry run (Maven Central -> {normalized_upload_url}): {bundle_name} ({artifact_list})", flush=True)
            return {"bundle": bundle_name, "deployment_id": "dry-run", "state": "DRY_RUN"}

        gpg_passphrase = os.environ.get("MAVEN_GPG_PASSPHRASE", "")

        return _publish_signed_maven_bundle(
            dist_dir=maven_dir,
            version=ver,
            username=username,
            password=password,
            upload_url=normalized_upload_url,
            status_url=resolved_status_url,
            publishing_type=publishing_type,
            poll_interval=poll_interval,
            poll_timeout=poll_timeout,
            max_transient_errors=max_transient_errors,
            sign_fn=lambda path: _gpg_sign_file_local(
                path,
                gpg_key=resolved_gpg_key,
                gpg_passphrase=gpg_passphrase,
            ),
        )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("print-version", help="Print the canonical SemVer version from pubspec.yaml")
    sub.add_parser("print-prerelease", help="Print 'true' if canonical version is a SemVer prerelease, else 'false'")

    cv = sub.add_parser("check-versions", help="Verify all versioned files match pubspec.yaml")
    cv.add_argument("--expected", default=None, help="Optional expected version string")

    ct = sub.add_parser("check-tag", help="Verify a git release tag matches project versions")
    ct.add_argument("--tag", required=True, help="Release tag (e.g. v0.8.0)")
    ct.add_argument("--require-changelog", action="store_true", help="Require matching CHANGELOG.md section for stable releases")

    sv = sub.add_parser("set-version", help="Synchronize version strings across all project files")
    sv.add_argument("version", help="Target SemVer version (e.g. 0.8.1)")
    sv.add_argument("--check", action="store_true", help="Check only; fail if files do not match")

    ec = sub.add_parser("extract-changelog", help="Print CHANGELOG.md section for a release version")
    ec.add_argument("--version", required=True, help="Version header without leading 'v'")
    ec.add_argument("--optional", action="store_true", help="Succeed cleanly if section is absent")

    pc = sub.add_parser("package-codegen", help="Verify and package protoc-gen-synurang-ffi binary")
    pc.add_argument("--target", required=True, choices=ALL_SUPPORTED_CODEGEN_TARGETS)
    pc.add_argument("--version", required=True)
    pc.add_argument("--binary", required=True, type=Path)
    pc.add_argument("--out", required=True, type=Path)
    pc.add_argument("--source-date-epoch", type=int, default=None)
    pc.add_argument("--skip-elf-check", action="store_true")
    pc.add_argument("--smoke-test", action="store_true")

    vc = sub.add_parser("verify-codegen-archive", help="Validate a packaged codegen archive")
    vc.add_argument("archive", type=Path)
    vc.add_argument("--version", default=None)
    vc.add_argument("--target", default=None)

    vm = sub.add_parser("verify-maven", help="Validate Android AAR and Desktop JAR Maven artifacts")
    vm.add_argument("--dist", required=True, type=Path)
    vm.add_argument("--version", default=None)

    vp = sub.add_parser("verify-python", help="Validate Python sdist and wheel artifacts")
    vp.add_argument("--dist", required=True, type=Path)
    vp.add_argument("--version", default=None)

    sc = sub.add_parser("stage-ci", help="Collect, verify, and checksum CI release artifacts")
    sc.add_argument("--out", required=True, type=Path)
    sc.add_argument("--codegen-dir", action="append", type=Path, required=True)
    sc.add_argument("--maven-dir", type=Path, default=None)
    sc.add_argument("--python-dir", type=Path, default=None)
    sc.add_argument("--require-codegen-target", action="append", dest="targets", default=[])
    sc.add_argument("--skip-maven", action="store_true")
    sc.add_argument("--skip-python", action="store_true")
    sc.add_argument("--version", default=None)

    vci = sub.add_parser("verify-ci", help="Validate staged release directory and SHA256SUMS")
    vci.add_argument("--dist", required=True, type=Path)
    vci_ver = vci.add_mutually_exclusive_group()
    vci_ver.add_argument("--tag", default="")
    vci_ver.add_argument("--version", default=None)
    vci.add_argument("--require-codegen-target", action="append", dest="targets", default=[])
    vci.add_argument("--skip-maven", action="store_true")
    vci.add_argument("--skip-python", action="store_true")
    vci.add_argument("--no-require-checksums", action="store_true")

    rci = sub.add_parser("release-ci", help="Create, verify, or promote a GitHub Release")
    rci.add_argument("--channel", required=True, choices=("nightly", "draft-stable", "finalize-stable", "stable"))
    rci.add_argument("--dist", required=True, type=Path)
    rci.add_argument("--sha", required=True)
    rci.add_argument("--tag", default="")
    rci.add_argument("--repo", default="")
    rci.add_argument("--allow-older", action="store_true", help="Allow backport release older than an existing stable release")
    rci.add_argument("--dry-run", action="store_true")

    pmc = sub.add_parser("publish-maven-ci", help="Sign, upload, and verify Maven Central bundle via Sonatype Portal API")
    pmc.add_argument("--dist", required=True, type=Path)
    pmc_ver = pmc.add_mutually_exclusive_group()
    pmc_ver.add_argument("--tag", default="")
    pmc_ver.add_argument("--version", default="")
    pmc.add_argument("--upload-url", default=MAVEN_UPLOAD_URL)
    pmc.add_argument("--status-url", default=None)
    pmc.add_argument("--publishing-type", choices=MAVEN_PUBLISHING_TYPES, default="AUTOMATIC")
    pmc.add_argument("--poll-interval", type=float, default=DEFAULT_MAVEN_POLL_INTERVAL)
    pmc.add_argument("--poll-timeout", type=float, default=DEFAULT_MAVEN_POLL_TIMEOUT)
    pmc.add_argument("--max-transient-errors", type=int, default=5)
    pmc.add_argument("--allow-prerelease", action="store_true", help="Allow uploading a prerelease version to Maven Central")
    pmc.add_argument("--dry-run", action="store_true")

    pml = sub.add_parser(
        "publish-maven-local",
        help="Verify (or download from a GitHub Release), locally GPG-sign, and upload Maven Central bundle",
    )
    pml_src = pml.add_mutually_exclusive_group(required=True)
    pml_src.add_argument("--tag", default="", help="GitHub Release tag to download and publish (e.g. v0.8.1)")
    pml_src.add_argument("--dist", type=Path, default=None, help="Existing local Maven dist directory")
    pml.add_argument("--version", default="", help="Project version (with --dist)")
    pml.add_argument("--repo", default="", help="GitHub repository OWNER/REPO for --tag downloads")
    pml.add_argument("--settings", type=Path, default=None, help="Maven settings XML path (default: .maven-settings.xml)")
    pml.add_argument("--server-id", default="central", help="Maven settings <server><id> entry (default: central)")
    pml.add_argument("--gpg-key", default="", help="Optional GPG key ID or fingerprint for --local-user")
    pml.add_argument("--upload-url", default=MAVEN_UPLOAD_URL)
    pml.add_argument("--status-url", default=None)
    pml.add_argument("--publishing-type", choices=MAVEN_PUBLISHING_TYPES, default="AUTOMATIC")
    pml.add_argument("--poll-interval", type=float, default=DEFAULT_MAVEN_POLL_INTERVAL)
    pml.add_argument("--poll-timeout", type=float, default=DEFAULT_MAVEN_POLL_TIMEOUT)
    pml.add_argument("--max-transient-errors", type=int, default=5)
    pml.add_argument("--allow-prerelease", action="store_true", help="Allow uploading a prerelease release/version")
    pml.add_argument("--allow-draft", action="store_true", help="Allow downloading from a draft GitHub release")
    pml.add_argument("--dry-run", action="store_true")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    root: Path = args.root.resolve()
    try:
        if args.command == "print-version":
            print(canonical_version(root))
        elif args.command == "print-prerelease":
            ver = canonical_version(root)
            print("true" if parse_semver(ver).is_prerelease else "false")
        elif args.command == "check-versions":
            ver = check_versions(root, expected=args.expected)
            print(f"All version declarations match {ver}")
        elif args.command == "check-tag":
            parsed = validate_release_tag(args.tag, root=root, require_changelog=args.require_changelog)
            print(f"Tag {args.tag} verified (version={parsed.raw}, prerelease={parsed.is_prerelease})")
        elif args.command == "set-version":
            changed = set_versions(args.version, root=root, check_only=args.check)
            if args.check:
                print(f"All files match {args.version}")
            else:
                rels = [p.relative_to(root).as_posix() for p in changed]
                print(f"Updated {len(rels)} file(s) to {args.version}: {', '.join(rels)}")
        elif args.command == "extract-changelog":
            body = extract_changelog(args.version, root=root, required=not args.optional)
            if body:
                print(body)
        elif args.command == "package-codegen":
            out = package_codegen(
                target=args.target,
                version=args.version,
                binary=args.binary,
                out_dir=args.out,
                root=root,
                source_date_epoch=args.source_date_epoch,
                skip_elf_check=args.skip_elf_check,
                smoke_test=args.smoke_test,
            )
            print(out)
        elif args.command == "verify-codegen-archive":
            ver, target = verify_codegen_archive(
                args.archive,
                expected_version=args.version,
                expected_target=args.target,
            )
            print(f"Verified {args.archive.name} (version={ver}, target={target})")
        elif args.command == "verify-maven":
            ver = args.version if args.version else canonical_version(root)
            paths = verify_maven(args.dist, version=ver)
            print(f"Verified {len(paths)} Maven artifacts for {ver}")
        elif args.command == "verify-python":
            ver = args.version if args.version else canonical_version(root)
            paths = verify_python(args.dist, version=ver)
            print(f"Verified {len(paths)} Python artifacts for {ver}")
        elif args.command == "stage-ci":
            targets = tuple(args.targets) if args.targets else DEFAULT_CODEGEN_TARGETS
            staged = stage_ci(
                out_dir=args.out,
                codegen_dirs=args.codegen_dir,
                maven_dir=args.maven_dir,
                python_dir=args.python_dir,
                required_codegen_targets=targets,
                include_maven=not args.skip_maven,
                include_python=not args.skip_python,
                version=args.version,
                root=root,
            )
            print(f"Staged {len(staged)} verified artifacts + SHA256SUMS into {args.out}")
        elif args.command == "verify-ci":
            targets = tuple(args.targets) if args.targets else DEFAULT_CODEGEN_TARGETS
            ver, assets = verify_ci(
                dist_dir=args.dist,
                version=args.version,
                tag=args.tag,
                required_codegen_targets=targets,
                require_maven=not args.skip_maven,
                require_python=not args.skip_python,
                require_checksums=not args.no_require_checksums,
                root=root,
            )
            print(f"Verified {len(assets)} CI release artifacts for {ver}")
        elif args.command == "release-ci":
            env_allow_older = parse_bool_flag(
                os.environ.get("SYNURANG_ALLOW_OLDER_RELEASE", ""),
                name="SYNURANG_ALLOW_OLDER_RELEASE",
            )
            allow_older = args.allow_older or env_allow_older
            release_ci(
                channel=args.channel,
                dist_dir=args.dist,
                sha=args.sha,
                tag=args.tag,
                repo=args.repo,
                allow_older=allow_older,
                dry_run=args.dry_run,
                root=root,
            )
        elif args.command == "publish-maven-ci":
            res = publish_maven_ci(
                dist_dir=args.dist,
                tag=args.tag,
                version=args.version,
                upload_url=args.upload_url,
                status_url=args.status_url,
                publishing_type=args.publishing_type,
                poll_interval=args.poll_interval,
                poll_timeout=args.poll_timeout,
                max_transient_errors=args.max_transient_errors,
                allow_prerelease=args.allow_prerelease,
                dry_run=args.dry_run,
                root=root,
            )
            if not args.dry_run:
                print(
                    f"Completed Maven Central deployment for {res['bundle']} "
                    f"(deploymentId={res['deployment_id']}, state={res['state']})",
                    flush=True,
                )
        elif args.command == "publish-maven-local":
            res = publish_maven_local(
                dist_dir=args.dist,
                tag=args.tag,
                version=args.version,
                repo=args.repo,
                settings_path=args.settings,
                server_id=args.server_id,
                gpg_key=args.gpg_key,
                upload_url=args.upload_url,
                status_url=args.status_url,
                publishing_type=args.publishing_type,
                poll_interval=args.poll_interval,
                poll_timeout=args.poll_timeout,
                max_transient_errors=args.max_transient_errors,
                allow_prerelease=args.allow_prerelease,
                allow_draft=args.allow_draft,
                dry_run=args.dry_run,
                root=root,
            )
            if not args.dry_run:
                print(
                    f"Completed Maven Central deployment for {res['bundle']} "
                    f"(deploymentId={res['deployment_id']}, state={res['state']})",
                    flush=True,
                )
        return 0
    except (ReleaseError, OSError, ET.ParseError, tarfile.TarError, zipfile.BadZipFile, subprocess.CalledProcessError) as err:
        print(f"Release error: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
