#!/usr/bin/env python3
"""Unit tests for scripts/release.py."""

from __future__ import annotations

import base64
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
import threading
import unittest
import zipfile
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
from urllib import parse as urllib_parse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release  # noqa: E402


REPO_ROOT = Path(__file__).resolve().parents[2]


def _copy_versioned_files(dst: Path) -> None:
    relpaths = sorted({rule.relpath for rule in release._literal_rules()}) + [
        "CHANGELOG.md",
        "LICENSE",
    ]
    for rel in relpaths:
        src = REPO_ROOT / rel
        out = dst / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, out)


def _make_zip_bytes(entries: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries.items():
            zf.writestr(name, data)
    return buf.getvalue()


def _create_fake_maven_dist(dist_dir: Path, version: str, *, include_macos_module_symbol: bool = True) -> None:
    dist_dir.mkdir(parents=True, exist_ok=True)
    class_jar = _make_zip_bytes({"io/github/ivere27/synurang/PluginHost.class": b"CAFEBABE"})
    grpc_class_jar = _make_zip_bytes({"io/github/ivere27/synurang/SynurangChannel.class": b"CAFEBABE"})
    sources_jar = _make_zip_bytes({"io/github/ivere27/synurang/PluginHost.java": b"package io.github.ivere27.synurang;"})
    javadoc_jar = _make_zip_bytes({"index.html": b"<html></html>"})

    android_natives = {
        f"jni/{abi}/libsynurang_jni.so": b"\x7fELF\x00Java_io_github_ivere27_synurang_ModuleJni_load\x00Java_io_github_ivere27_synurang_SynurangJni_open\x00"
        for abi in release.ANDROID_ABIS
    }
    android_aar = _make_zip_bytes(
        {
            "AndroidManifest.xml": b'<manifest package="io.github.ivere27.synurang"/>',
            "classes.jar": class_jar,
            **android_natives,
        }
    )
    (dist_dir / f"synurang-android-{version}.aar").write_bytes(android_aar)

    android_grpc_aar = _make_zip_bytes(
        {
            "AndroidManifest.xml": b'<manifest package="io.github.ivere27.synurang.grpc"/>',
            "classes.jar": grpc_class_jar,
        }
    )
    (dist_dir / f"synurang-android-grpc-{version}.aar").write_bytes(android_grpc_aar)

    desktop_entries: dict[str, bytes] = {
        "io/github/ivere27/synurang/NativeLibLoader.class": b"CAFEBABE",
    }
    for rel in release.DESKTOP_JNI_PATHS:
        platform = rel.split("/")[1]
        if platform.startswith("windows-"):
            magic = b"MZ\x90\x00"
        elif platform.startswith("macos-"):
            magic = b"\xcf\xfa\xed\xfe"
        else:
            magic = b"\x7fELF"
        if platform.startswith("macos-") and not include_macos_module_symbol:
            symbols = b"Java_io_github_ivere27_synurang_SynurangJni_open\x00"
        else:
            symbols = b"Java_io_github_ivere27_synurang_ModuleJni_load\x00Java_io_github_ivere27_synurang_SynurangJni_open\x00"
        desktop_entries[rel] = magic + symbols
    (dist_dir / f"synurang-desktop-{version}.jar").write_bytes(_make_zip_bytes(desktop_entries))
    (dist_dir / f"synurang-desktop-grpc-{version}.jar").write_bytes(grpc_class_jar)

    for artifact, ext, has_dep in release.MAVEN_ARTIFACTS:
        (dist_dir / f"{artifact}-{version}-sources.jar").write_bytes(sources_jar)
        (dist_dir / f"{artifact}-{version}-javadoc.jar").write_bytes(javadoc_jar)
        core_name = artifact.removesuffix("-grpc")
        deps_xml = (
            f"""
  <dependencies>
    <dependency>
      <groupId>{release.MAVEN_GROUP_ID}</groupId>
      <artifactId>{core_name}</artifactId>
      <version>{version}</version>
    </dependency>
  </dependencies>"""
            if has_dep
            else ""
        )
        pom = f"""<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>{release.MAVEN_GROUP_ID}</groupId>
  <artifactId>{artifact}</artifactId>
  <version>{version}</version>
  <packaging>{ext}</packaging>{deps_xml}
</project>
"""
        (dist_dir / f"{artifact}-{version}.pom").write_text(pom, encoding="utf-8")


def _create_fake_python_dist(dist_dir: Path, version: str) -> None:
    dist_dir.mkdir(parents=True, exist_ok=True)
    pep = release.parse_semver(version).pep440
    whl_path = dist_dir / f"synurang-{pep}-py3-none-any.whl"
    with zipfile.ZipFile(whl_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("synurang/__init__.py", f'__version__ = "{pep}"\n')
        zf.writestr(f"synurang-{pep}.dist-info/METADATA", f"Metadata-Version: 2.1\nName: synurang\nVersion: {pep}\n")
        zf.writestr(f"synurang-{pep}.dist-info/WHEEL", "Wheel-Version: 1.0\n")

    sdist_path = dist_dir / f"synurang-{pep}.tar.gz"
    with tarfile.open(sdist_path, "w:gz") as tf:
        pkg_info = f"Metadata-Version: 2.1\nName: synurang\nVersion: {pep}\n".encode("utf-8")
        init_py = f'__version__ = "{pep}"\n'.encode("utf-8")
        for rel, payload in (
            (f"synurang-{pep}/PKG-INFO", pkg_info),
            (f"synurang-{pep}/synurang.egg-info/PKG-INFO", pkg_info),
            (f"synurang-{pep}/synurang/__init__.py", init_py),
        ):
            info = tarfile.TarInfo(rel)
            info.size = len(payload)
            info.mode = 0o644
            tf.addfile(info, io.BytesIO(payload))


def _create_fake_codegen_bins(bin_dir: Path) -> dict[str, Path]:
    bin_dir.mkdir(parents=True, exist_ok=True)
    magics = {
        "x86_64-unknown-linux-musl": b"\x7fELF\x02\x01\x01\x00dummy-x64-musl",
        "aarch64-unknown-linux-musl": b"\x7fELF\x02\x01\x01\x00dummy-arm64-musl",
        "x86_64-pc-windows-msvc": b"MZ\x90\x00dummy-win64",
        "aarch64-apple-darwin": b"\xcf\xfa\xed\xfedummy-macos-arm64",
        "x86_64-apple-darwin": b"\xcf\xfa\xed\xfedummy-macos-x64",
    }
    paths: dict[str, Path] = {}
    for target, payload in magics.items():
        ext = ".exe" if "-windows-" in target else ""
        p = bin_dir / f"{target}-{release.CANONICAL_BINARY}{ext}"
        p.write_bytes(payload)
        p.chmod(0o755)
        paths[target] = p
    return paths


class ReleaseToolTests(unittest.TestCase):
    def test_semver_and_pep440(self) -> None:
        v = release.parse_semver("0.8.0")
        self.assertFalse(v.is_prerelease)
        self.assertEqual(v.pep440, "0.8.0")

        self.assertEqual(release.parse_semver("0.8.1-alpha.1").pep440, "0.8.1a1")
        self.assertEqual(release.parse_semver("0.8.1-beta.2").pep440, "0.8.1b2")
        rc = release.parse_semver("0.8.1-rc.2")
        self.assertTrue(rc.is_prerelease)
        self.assertEqual(rc.pep440, "0.8.1rc2")
        self.assertEqual(release.parse_semver("0.8.1-dev.3").pep440, "0.8.1.dev3")
        self.assertLess(rc.compare_key(), release.parse_semver("0.8.1").compare_key())
        self.assertGreater(release.parse_semver("0.8.1-beta.10").compare_key(), release.parse_semver("0.8.1-beta.2").compare_key())

        # Non-standard prereleases must not synthesize PyPI-disallowed '+local' versions
        with self.assertRaises(release.ReleaseError):
            _ = release.parse_semver("0.8.1-preview.1").pep440

        for bad in ("", "0.8", "v0.8.0", "01.0.0", "0.8.0-01", "0.8.0+build1", "0.8.0-SNAPSHOT"):
            with self.assertRaises(release.ReleaseError):
                release.parse_semver(bad)

    def test_versions_and_tag_validation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _copy_versioned_files(root)
            current = release.canonical_version(root)
            self.assertEqual(release.check_versions(root), current)

            # set-version round-trip to prerelease and new stable
            changed = release.set_versions("0.9.0-rc.1", root=root)
            self.assertGreaterEqual(len(changed), 10)
            self.assertEqual(release.check_versions(root), "0.9.0-rc.1")
            self.assertEqual(release.set_versions("0.9.0-rc.1", root=root, check_only=True), [])

            # Python version declarations must use strict PEP 440 (not hyphenated SemVer)
            init_py = root / "python" / "synurang" / "__init__.py"
            orig_init = init_py.read_text(encoding="utf-8")
            init_py.write_text('__version__ = "0.9.0-rc.1"\n', encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.check_versions(root)
            init_py.write_text(orig_init, encoding="utf-8")

            setup_cfg = root / "python" / "setup.cfg"
            orig_cfg = setup_cfg.read_text(encoding="utf-8")
            setup_cfg.write_text(orig_cfg.replace("version = 0.9.0rc1", "version = 0.9.0-rc.1"), encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.check_versions(root)
            setup_cfg.write_text(orig_cfg, encoding="utf-8")

            # SNAPSHOT followed by punctuation or on unanchored CODEGEN_VERSION= must fail check_versions
            # and be cleanly replaced (without leaving a -SNAPSHOT tail) by set_versions
            makefile_path = root / "makefile"
            orig_makefile = makefile_path.read_text(encoding="utf-8")
            makefile_path.write_text(
                orig_makefile.replace("CODEGEN_VERSION=0.9.0-rc.1", "CODEGEN_VERSION=0.9.0-SNAPSHOT"),
                encoding="utf-8",
            )
            with self.assertRaises(release.ReleaseError):
                release.check_versions(root)
            release.set_versions("0.9.0-rc.1", root=root)
            self.assertNotIn("CODEGEN_VERSION=0.9.0-rc.1-SNAPSHOT", makefile_path.read_text(encoding="utf-8"))
            self.assertIn("CODEGEN_VERSION=0.9.0-rc.1)", makefile_path.read_text(encoding="utf-8"))

            # Corrupting 1 of the 4 Gradle dependency lines in README.md so it no longer matches the pattern
            # must be caught by expected_count=4
            gradle_snippet = root / "README.md"
            orig_readme = gradle_snippet.read_text(encoding="utf-8")
            self.assertIn("0.9.0-rc.1'", orig_readme)
            gradle_snippet.write_text(
                orig_readme.replace(
                    "implementation 'io.github.ivere27:synurang-desktop:0.9.0-rc.1'",
                    "implementation 'io.github.ivere27:synurang-desktop:BROKEN'",
                ),
                encoding="utf-8",
            )
            with self.assertRaises(release.ReleaseError):
                release.check_versions(root)
            gradle_snippet.write_text(orig_readme, encoding="utf-8")

            release.set_versions("0.9.0", root=root)
            self.assertEqual(release.check_versions(root), "0.9.0")

            # Missing CHANGELOG header must reject stable release tag with --require-changelog
            with self.assertRaises(release.ReleaseError):
                release.validate_release_tag("v0.9.0", root=root, require_changelog=True)

            # Add CHANGELOG section and validate
            changelog = root / "CHANGELOG.md"
            changelog.write_text("## 0.9.0\n\n* Automated CI release.\n\n" + changelog.read_text(encoding="utf-8"), encoding="utf-8")
            parsed = release.validate_release_tag("v0.9.0", root=root, require_changelog=True)
            self.assertEqual(parsed.raw, "0.9.0")

            # Drift detection on a single file must fail
            readme = root / "README.md"
            readme.write_text(readme.read_text(encoding="utf-8").replace("synurang-desktop:0.9.0", "synurang-desktop:0.8.9"), encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.check_versions(root)

            # set_versions must not partially mutate earlier files if a later file fails to match
            readme.write_text(orig_readme.replace("0.9.0-rc.1", "0.9.0"), encoding="utf-8")
            self.assertEqual(release.check_versions(root), "0.9.0")
            readme_corrupt = readme.read_text(encoding="utf-8").replace(
                "implementation 'io.github.ivere27:synurang-desktop:0.9.0'",
                "implementation 'io.github.ivere27:synurang-desktop:BROKEN'",
            )
            readme.write_text(readme_corrupt, encoding="utf-8")
            pubspec_before = (root / "pubspec.yaml").read_text(encoding="utf-8")
            makefile_before = makefile_path.read_text(encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.set_versions("0.9.1", root=root)
            self.assertEqual((root / "pubspec.yaml").read_text(encoding="utf-8"), pubspec_before)
            self.assertEqual(makefile_path.read_text(encoding="utf-8"), makefile_before)

            # set_versions must also reject non-PEP440 prereleases before touching pubspec.yaml
            readme.write_text(orig_readme.replace("0.9.0-rc.1", "0.9.0"), encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.set_versions("0.9.1-preview.1", root=root)
            self.assertEqual((root / "pubspec.yaml").read_text(encoding="utf-8"), pubspec_before)

            # aar_help_ver_pat must match versions followed by punctuation/quotes without accepting -SNAPSHOT2
            aar_rule = next(r for r in release._literal_rules() if r.relpath == "makefile" and r.expected_count == 2)
            self.assertEqual(
                [(m.group("version"), m.group("snapshot")) for m in aar_rule.pattern.finditer('AAR_VERSION=0.9.0" AAR_VERSION=0.9.0-SNAPSHOT"')],
                [("0.9.0", None), ("0.9.0", "-SNAPSHOT")],
            )
            bad_snap = list(aar_rule.pattern.finditer("AAR_VERSION=0.9.0-SNAPSHOT2 "))
            self.assertEqual(len(bad_snap), 1)
            self.assertEqual(bad_snap[0].group("version"), "0.9.0-SNAPSHOT2")
            self.assertIsNone(bad_snap[0].group("snapshot"))

    def test_package_and_verify_codegen_determinism_and_guards(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _copy_versioned_files(root)
            ver = release.canonical_version(root)
            bins = _create_fake_codegen_bins(root / "bins")
            out1 = root / "out1"
            out2 = root / "out2"

            for target, binary in bins.items():
                a1 = release.package_codegen(
                    target=target,
                    version=ver,
                    binary=binary,
                    out_dir=out1,
                    root=root,
                    source_date_epoch=1700000000,
                    skip_elf_check=True,
                )
                a2 = release.package_codegen(
                    target=target,
                    version=ver,
                    binary=binary,
                    out_dir=out2,
                    root=root,
                    source_date_epoch=1700000000,
                    skip_elf_check=True,
                )
                self.assertEqual(a1.read_bytes(), a2.read_bytes(), f"Non-deterministic archive for {target}")
                self.assertEqual(release.verify_codegen_archive(a1, expected_version=ver, expected_target=target), (ver, target))

            # Reject dynamic INTERP on musl binary and verify readelf runs under LC_ALL=C
            with mock.patch("release.shutil.which", return_value="/usr/bin/readelf"):
                with mock.patch(
                    "release.subprocess.run",
                    return_value=subprocess.CompletedProcess(["readelf"], 0, stdout="INTERP /lib/ld-linux-x86-64.so.2", stderr=""),
                ) as readelf_mock:
                    with self.assertRaises(release.ReleaseError):
                        release.package_codegen(
                            target="x86_64-unknown-linux-musl",
                            version=ver,
                            binary=bins["x86_64-unknown-linux-musl"],
                            out_dir=out1,
                            root=root,
                            skip_elf_check=False,
                        )
                    self.assertEqual(readelf_mock.call_args.kwargs["env"]["LC_ALL"], "C")

            # Reject symlink entry in targz and path traversal in zip
            bad_tar = out1 / f"{release.CANONICAL_BINARY}-{ver}-x86_64-unknown-linux-musl.tar.gz"
            with tarfile.open(bad_tar, "w:gz") as tf:
                sym = tarfile.TarInfo(f"{release.CANONICAL_BINARY}-{ver}-x86_64-unknown-linux-musl/{release.CANONICAL_BINARY}")
                sym.type = tarfile.SYMTYPE
                sym.linkname = "/etc/passwd"
                tf.addfile(sym)
            with self.assertRaises(release.ReleaseError):
                release.verify_codegen_archive(bad_tar)

            bad_zip = out1 / f"{release.CANONICAL_BINARY}-{ver}-x86_64-pc-windows-msvc.zip"
            with zipfile.ZipFile(bad_zip, "w") as zf:
                zf.writestr("../evil.exe", b"MZ")
            with self.assertRaises(release.ReleaseError):
                release.verify_codegen_archive(bad_zip)

    def test_verify_maven_and_python(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _copy_versioned_files(root)
            ver = release.canonical_version(root)
            maven_dir = root / "maven"
            _create_fake_maven_dist(maven_dir, ver, include_macos_module_symbol=True)
            paths = release.verify_maven(maven_dir, version=ver)
            self.assertEqual(len(paths), 16)

            # Reject macos dylib missing synurang_module_jni symbols
            bad_maven = root / "bad-maven"
            _create_fake_maven_dist(bad_maven, ver, include_macos_module_symbol=False)
            with self.assertRaises(release.ReleaseError):
                release.verify_maven(bad_maven, version=ver)

            # Reject wrong POM version
            pom = maven_dir / f"synurang-desktop-{ver}.pom"
            pom.write_text(pom.read_text(encoding="utf-8").replace(f"<version>{ver}</version>", "<version>9.9.9</version>"), encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.verify_maven(maven_dir, version=ver)

            # Python verification including prerelease PEP 440
            py_dir = root / "py"
            _create_fake_python_dist(py_dir, "0.8.1-rc.2")
            py_paths = release.verify_python(py_dir, version="0.8.1-rc.2")
            self.assertEqual(len(py_paths), 2)

    def test_stage_and_verify_ci_tamper_checks(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _copy_versioned_files(root)
            ver = release.canonical_version(root)

            bins = _create_fake_codegen_bins(root / "bins")
            cg_artifacts = root / "artifacts"
            for target, binary in bins.items():
                release.package_codegen(
                    target=target,
                    version=ver,
                    binary=binary,
                    out_dir=cg_artifacts / f"codegen-{target}",
                    root=root,
                    source_date_epoch=1700000000,
                    skip_elf_check=True,
                )

            maven_dir = root / "maven-dist"
            _create_fake_maven_dist(maven_dir, ver)
            py_dir = root / "python-dist"
            _create_fake_python_dist(py_dir, ver)

            # Reject unsafe out_dir overlapping root or input directories before any rmtree
            for bad_out in (root, maven_dir, cg_artifacts, cg_artifacts / "sub", root.parent):
                with self.assertRaises(release.ReleaseError):
                    release.stage_ci(
                        out_dir=bad_out,
                        codegen_dirs=[cg_artifacts],
                        maven_dir=maven_dir,
                        python_dir=py_dir,
                        root=root,
                    )
            self.assertTrue((maven_dir / f"synurang-desktop-{ver}.jar").is_file())

            staged = root / "release-dist"
            files = release.stage_ci(
                out_dir=staged,
                codegen_dirs=[cg_artifacts],
                maven_dir=maven_dir,
                python_dir=py_dir,
                root=root,
            )
            self.assertEqual(len(files), 5 + 16 + 2)
            verified_ver, _ = release.verify_ci(dist_dir=staged, root=root)
            self.assertEqual(verified_ver, ver)

            # Reject passing both --tag and --version simultaneously (API and CLI)
            with self.assertRaises(release.ReleaseError):
                release.verify_ci(dist_dir=staged, tag=f"v{ver}", version="9.9.9", root=root)
            with self.assertRaises(SystemExit) as parser_exit:
                release._build_parser().parse_args(["verify-ci", "--dist", str(staged), "--tag", f"v{ver}", "--version", ver])
            self.assertEqual(parser_exit.exception.code, 2)

            # Extra unexpected file must fail
            (staged / "stray.txt").write_text("oops", encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.verify_ci(dist_dir=staged, root=root)
            (staged / "stray.txt").unlink()

            # Checksum tampering must fail
            sums = staged / "SHA256SUMS"
            sums.write_text(sums.read_text(encoding="utf-8").replace("0", "1", 1), encoding="utf-8")
            with self.assertRaises(release.ReleaseError):
                release.verify_ci(dist_dir=staged, root=root)

    def _make_staged_fixture(self, root: Path, version: str | None = None) -> Path:
        _copy_versioned_files(root)
        if version is not None:
            release.set_versions(version, root=root)
        ver = release.canonical_version(root)
        bins = _create_fake_codegen_bins(root / "bins")
        cg_artifacts = root / "cg"
        for target, binary in bins.items():
            release.package_codegen(
                target=target,
                version=ver,
                binary=binary,
                out_dir=cg_artifacts / target,
                root=root,
                source_date_epoch=1700000000,
                skip_elf_check=True,
            )
        _create_fake_maven_dist(root / "maven", ver)
        _create_fake_python_dist(root / "py", ver)
        staged = root / "release-dist"
        release.stage_ci(
            out_dir=staged,
            codegen_dirs=[cg_artifacts],
            maven_dir=root / "maven",
            python_dir=root / "py",
            root=root,
        )
        return staged

    def test_release_ci_dry_run_draft_finalize_and_nightly(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staged = self._make_staged_fixture(root)
            orig_ver = release.canonical_version(root)
            orig_changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
            parsed_orig = release.parse_semver(orig_ver)
            if parsed_orig.patch > 0:
                low_ver = f"{parsed_orig.major}.{parsed_orig.minor}.{parsed_orig.patch - 1}"
            elif parsed_orig.minor > 0:
                low_ver = f"{parsed_orig.major}.{parsed_orig.minor - 1}.9"
            else:
                low_ver = f"{max(0, parsed_orig.major - 1)}.0.0"

            older_root = Path(tmp) / "older-repo"
            older_staged = self._make_staged_fixture(older_root, version=low_ver)
            (older_root / "CHANGELOG.md").write_text(
                f"## {low_ver}\n\n* Backport patch release.\n",
                encoding="utf-8",
            )

            sha = "abcdef0123456789abcdef0123456789abcdef01"
            tag = f"v{orig_ver}"

            # Dry run must execute zero commands
            with mock.patch("release.subprocess.run") as run_mock:
                release.release_ci(channel="draft-stable", dist_dir=staged, sha=sha, tag=tag, repo="ivere27/synurang", dry_run=True, root=root)
                release.release_ci(channel="nightly", dist_dir=staged, sha=sha, repo="ivere27/synurang", dry_run=True, root=root)
                run_mock.assert_not_called()

            # Expected GitHub assets metadata matching staged files
            uploaded_assets = [
                {
                    "name": p.name,
                    "size": p.stat().st_size,
                    "state": "uploaded",
                    "digest": "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest(),
                }
                for p in sorted(staged.iterdir(), key=lambda x: x.name)
            ]
            older_uploaded_assets = [
                {
                    "name": p.name,
                    "size": p.stat().st_size,
                    "state": "uploaded",
                    "digest": "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest(),
                }
                for p in sorted(older_staged.iterdir(), key=lambda x: x.name)
            ]

            state: dict[str, object] = {"releases": [], "assets": []}
            recorded: list[list[str]] = []

            def fake_run(cmd: list[str], **_kwargs) -> subprocess.CompletedProcess:
                recorded.append(cmd)
                if cmd[:2] == ["gh", "api"]:
                    path = next(c for c in cmd if c.startswith("repos/"))
                    if "releases?per_page=100" in path:
                        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps([state["releases"]]), stderr="")
                    if "/assets?per_page=100" in path:
                        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps([state.get("assets", [])]), stderr="")
                    if "matching-refs/tags/nightly" in path:
                        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps([{"ref": "refs/tags/nightly"}]), stderr="")
                    return subprocess.CompletedProcess(cmd, 0, stdout="{}", stderr="")
                if cmd[:3] == ["gh", "release", "create"]:
                    rtag = cmd[3]
                    is_draft = "--draft" in cmd
                    is_pre = "--prerelease" in cmd
                    rels = list(state["releases"])
                    rels.append({"id": 100 + len(rels), "tag_name": rtag, "draft": is_draft, "prerelease": is_pre})
                    state["releases"] = rels
                    state["assets"] = older_uploaded_assets if rtag == f"v{low_ver}" else uploaded_assets
                    return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
                if cmd[:3] == ["gh", "release", "upload"]:
                    rtag = cmd[3]
                    state["assets"] = older_uploaded_assets if rtag == f"v{low_ver}" else uploaded_assets
                    return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
                if cmd[:3] == ["gh", "release", "edit"]:
                    rtag = cmd[3]
                    for rel in state["releases"]:
                        if rel["tag_name"] == rtag:
                            if "--draft=false" in cmd:
                                rel["draft"] = False
                            if "--draft=true" in cmd:
                                rel["draft"] = True
                    return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            with mock.patch("release.subprocess.run", side_effect=fake_run):
                # 1. Draft creation verifies uploaded digests
                release.release_ci(channel="draft-stable", dist_dir=staged, sha=sha, tag=tag, repo="ivere27/synurang", root=root)
                # 2. Finalize verifies draft + promotes as latest
                release.release_ci(channel="finalize-stable", dist_dir=staged, sha=sha, tag=tag, repo="ivere27/synurang", root=root)
                self.assertTrue(any(c[:3] == ["gh", "release", "edit"] and "--draft=false" in c and "--latest" in c for c in recorded))

                # 3. Refuse republishing an already published stable release
                with self.assertRaises(release.ReleaseError):
                    release.release_ci(channel="draft-stable", dist_dir=staged, sha=sha, tag=tag, repo="ivere27/synurang", root=root)

                # 4. Refuse version downgrade vs published tag unless allow_older=True
                with self.assertRaises(release.ReleaseError):
                    release.release_ci(channel="draft-stable", dist_dir=older_staged, sha=sha, tag=f"v{low_ver}", repo="ivere27/synurang", root=older_root)

                # 5. Backport release with allow_older=True (or SYNURANG_ALLOW_OLDER_RELEASE=1 via main)
                # succeeds and promotes with --latest=false
                recorded.clear()
                with mock.patch.dict(os.environ, {"SYNURANG_ALLOW_OLDER_RELEASE": "1"}):
                    rc = release.main(
                        [
                            "--root",
                            str(older_root),
                            "release-ci",
                            "--channel",
                            "draft-stable",
                            "--dist",
                            str(older_staged),
                            "--sha",
                            sha,
                            "--tag",
                            f"v{low_ver}",
                            "--repo",
                            "ivere27/synurang",
                        ]
                    )
                self.assertEqual(rc, 0)
                release.release_ci(
                    channel="finalize-stable",
                    dist_dir=older_staged,
                    sha=sha,
                    tag=f"v{low_ver}",
                    repo="ivere27/synurang",
                    root=older_root,
                )
                self.assertTrue(
                    any(
                        c[:4] == ["gh", "release", "edit", f"v{low_ver}"]
                        and "--draft=false" in c
                        and "--latest=false" in c
                        for c in recorded
                    )
                )

            # Reset to orig_ver (no hardcoded version) and test rolling nightly
            release.set_versions(orig_ver, root=root)
            (root / "CHANGELOG.md").write_text(orig_changelog, encoding="utf-8")
            state["releases"] = [{"id": 202, "tag_name": "nightly", "draft": False, "prerelease": True}]
            state["assets"] = [*uploaded_assets, {"name": "stale-old-asset.zip", "size": 5, "state": "uploaded", "digest": "sha256:" + "0" * 64}]
            recorded.clear()

            with mock.patch("release.subprocess.run", side_effect=fake_run):
                release.release_ci(channel="nightly", dist_dir=staged, sha=sha, repo="ivere27/synurang", root=root)
                self.assertTrue(any(c[:4] == ["gh", "release", "delete-asset", "nightly"] and "stale-old-asset.zip" in c for c in recorded))
                self.assertTrue(any(c[:2] == ["gh", "api"] and "git/refs/tags/nightly" in c[4] for c in recorded))

            # Tamper GitHub reported digest and verify upload verification catches it
            bad_assets = [dict(uploaded_assets[0], digest="sha256:" + "f" * 64), *uploaded_assets[1:]]
            state["releases"] = []

            def bad_digest_run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
                res = fake_run(cmd, **kwargs)
                if cmd[:3] == ["gh", "release", "create"]:
                    state["assets"] = bad_assets
                return res

            with mock.patch("release.subprocess.run", side_effect=bad_digest_run):
                with self.assertRaises(release.ReleaseError):
                    release.release_ci(channel="nightly", dist_dir=staged, sha=sha, repo="ivere27/synurang", root=root)

            # _newer_published_stable_releases must sort by SemVer precedence (v0.10.0 > v0.9.0)
            newer = release._newer_published_stable_releases(
                [
                    {"tag_name": "v0.10.0", "draft": False, "prerelease": False},
                    {"tag_name": "v0.9.0", "draft": False, "prerelease": False},
                    {"tag_name": "v0.10.1-rc.1", "draft": False, "prerelease": True},
                    {"tag_name": "v0.11.0", "draft": True, "prerelease": False},
                ],
                target_tag="v0.8.0",
                parsed_ver=release.parse_semver("0.8.0"),
            )
            self.assertEqual(newer, ["v0.9.0", "v0.10.0"])
            state["releases"] = [
                {"id": 301, "tag_name": "v0.10.0", "draft": False, "prerelease": False},
                {"id": 302, "tag_name": "v0.9.0", "draft": False, "prerelease": False},
            ]
            with mock.patch("release.subprocess.run", side_effect=fake_run):
                with self.assertRaises(release.ReleaseError) as ctx:
                    release.release_ci(
                        channel="draft-stable",
                        dist_dir=older_staged,
                        sha=sha,
                        tag=f"v{low_ver}",
                        repo="ivere27/synurang",
                        root=older_root,
                    )
            self.assertIn("'v0.10.0'", str(ctx.exception))

    def test_publish_maven_ci_dry_run_auth_atomic_bundle_and_status_polling(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _copy_versioned_files(root)
            ver = release.canonical_version(root)
            maven_dir = root / "maven"
            _create_fake_maven_dist(maven_dir, ver)

            # Prerelease version must be rejected by default unless allow_prerelease=True
            pre_maven_dir = root / "maven-pre"
            _create_fake_maven_dist(pre_maven_dir, "0.9.0-rc.1")
            with self.assertRaises(release.ReleaseError):
                release.publish_maven_ci(dist_dir=pre_maven_dir, version="0.9.0-rc.1", dry_run=True, root=root)
            pre_res = release.publish_maven_ci(
                dist_dir=pre_maven_dir,
                version="0.9.0-rc.1",
                allow_prerelease=True,
                dry_run=True,
                root=root,
            )
            self.assertEqual(pre_res["bundle"], "synurang-0.9.0-rc.1")

            # Dry run builds one atomic bundle ZIP covering all 4 artifacts (4*4*3 = 48 entries)
            dry_res = release.publish_maven_ci(dist_dir=maven_dir, version=ver, dry_run=True, root=root)
            self.assertEqual(dry_res, {"bundle": f"synurang-{ver}", "deployment_id": "dry-run", "state": "DRY_RUN"})

            # Reject passing both --tag and --version, or invalid publishing_type
            with self.assertRaises(release.ReleaseError):
                release.publish_maven_ci(dist_dir=maven_dir, tag=f"v{ver}", version="9.9.9", dry_run=True, root=root)
            with self.assertRaises(SystemExit) as parser_exit:
                release._build_parser().parse_args(
                    ["publish-maven-ci", "--dist", str(maven_dir), "--tag", f"v{ver}", "--version", ver]
                )
            self.assertEqual(parser_exit.exception.code, 2)
            with self.assertRaises(release.ReleaseError):
                release.publish_maven_ci(dist_dir=maven_dir, version=ver, publishing_type="MANUAL", dry_run=True, root=root)

            out_bundle = Path(tmp) / "atomic-bundle.zip"
            release.build_maven_bundle_zip(dist_dir=maven_dir, version=ver, out_zip=out_bundle)
            with zipfile.ZipFile(out_bundle, "r") as zf:
                names = set(zf.namelist())
            self.assertEqual(len(names), 4 * 4 * 3)
            for artifact, ext, _ in release.MAVEN_ARTIFACTS:
                prefix = f"io/github/ivere27/{artifact}/{ver}/{artifact}-{ver}"
                self.assertIn(f"{prefix}.{ext}", names)
                self.assertIn(f"{prefix}.{ext}.md5", names)
                self.assertIn(f"{prefix}.pom.sha1", names)

            # Missing credentials must fail cleanly
            with mock.patch.dict(os.environ, {}, clear=True):
                with self.assertRaises(release.ReleaseError):
                    release.publish_maven_ci(dist_dir=maven_dir, version=ver, dry_run=False, root=root)

            # Verify Bearer auth header, query params, GPG loopback import,gpgconf cleanup,
            # and resilience to transient 502 / curl network failures during status polling
            recorded_cmds: list[tuple[list[str], str | None]] = []
            poll_steps = iter(
                [
                    (0, json.dumps({"deploymentId": "deploy-123", "deploymentState": "PENDING"}) + "\n200\n", ""),
                    (0, "Bad Gateway\n502\n", ""),
                    (28, "", "Operation timed out"),
                    (0, json.dumps({"deploymentId": "deploy-123", "deploymentState": "PUBLISHING"}) + "\n200\n", ""),
                    (0, json.dumps({"deploymentId": "deploy-123", "deploymentState": "PUBLISHED"}) + "\n200\n", ""),
                ]
            )

            def fake_pub_run(cmd: list[str], input=None, **_kwargs) -> subprocess.CompletedProcess:
                recorded_cmds.append((cmd, input))
                if cmd[0] == "gpg" and "--output" in cmd:
                    out_file = Path(cmd[cmd.index("--output") + 1])
                    out_file.write_text("-----BEGIN PGP SIGNATURE-----\n", encoding="utf-8")
                if cmd[0] == "curl":
                    if any("/publisher/upload" in c for c in cmd):
                        return subprocess.CompletedProcess(cmd, 0, stdout="deploy-123\n201\n", stderr="")
                    if any("/publisher/status" in c for c in cmd):
                        rc, out, err = next(poll_steps)
                        return subprocess.CompletedProcess(cmd, rc, stdout=out, stderr=err)
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            env_vals = {
                "SONATYPE_USERNAME": "secret-user",
                "SONATYPE_PASSWORD": "secret-password",
                "MAVEN_GPG_PRIVATE_KEY": "-----BEGIN PGP PRIVATE KEY BLOCK-----\nabc\n-----END PGP PRIVATE KEY BLOCK-----\n",
                "MAVEN_GPG_PASSPHRASE": "pass",
            }
            with mock.patch.dict(os.environ, env_vals, clear=True):
                with mock.patch("release.shutil.which", return_value="/usr/bin/tool"):
                    with mock.patch("release.subprocess.run", side_effect=fake_pub_run):
                        live_res = release.publish_maven_ci(
                            dist_dir=maven_dir,
                            version=ver,
                            poll_interval=0.0,
                            poll_timeout=5.0,
                            dry_run=False,
                            root=root,
                        )
            self.assertEqual(live_res, {"bundle": f"synurang-{ver}", "deployment_id": "deploy-123", "state": "PUBLISHED"})

            # Check GPG --import uses --batch, --yes, --pinentry-mode loopback, --passphrase-file, and kills gpg-agent
            gpg_imports = [c for c, _ in recorded_cmds if c[0] == "gpg" and "--import" in c]
            self.assertEqual(len(gpg_imports), 1)
            self.assertIn("--yes", gpg_imports[0])
            self.assertIn("--pinentry-mode", gpg_imports[0])
            self.assertEqual(gpg_imports[0][gpg_imports[0].index("--pinentry-mode") + 1], "loopback")
            self.assertIn("--passphrase-file", gpg_imports[0])
            self.assertTrue(any(c[0] == "gpgconf" and "--kill" in c for c, _ in recorded_cmds))

            # Check exactly 1 atomic upload call + 5 status poll calls (including 2 recovered transient errors)
            expected_bearer = base64.b64encode(b"secret-user:secret-password").decode("ascii")
            upload_calls = [(c, inp) for c, inp in recorded_cmds if c[0] == "curl" and any("/upload" in a for a in c)]
            status_calls = [(c, inp) for c, inp in recorded_cmds if c[0] == "curl" and any("/status" in a for a in c)]
            self.assertEqual(len(upload_calls), 1)
            self.assertEqual(len(status_calls), 5)

            up_cmd, up_inp = upload_calls[0]
            self.assertNotIn("secret-user", " ".join(up_cmd))
            self.assertNotIn("secret-password", " ".join(up_cmd))
            self.assertNotIn(expected_bearer, " ".join(up_cmd))
            self.assertIn("-K", up_cmd)
            self.assertEqual(up_inp, f'header = "Authorization: Bearer {expected_bearer}"\n')
            up_url = next(a for a in up_cmd if "/upload" in a)
            up_qs = urllib_parse.parse_qs(urllib_parse.urlsplit(up_url).query)
            self.assertEqual(up_qs.get("name"), [f"synurang-{ver}"])
            self.assertEqual(up_qs.get("publishingType"), ["AUTOMATIC"])
            form_fields = [up_cmd[i + 1] for i, tok in enumerate(up_cmd) if tok == "-F"]
            self.assertEqual(len(form_fields), 1)
            self.assertTrue(form_fields[0].startswith("bundle=@"))

            for st_cmd, st_inp in status_calls:
                self.assertEqual(st_inp, f'header = "Authorization: Bearer {expected_bearer}"\n')
                st_url = next(a for a in st_cmd if "/status" in a)
                st_qs = urllib_parse.parse_qs(urllib_parse.urlsplit(st_url).query)
                self.assertEqual(st_qs.get("id"), ["deploy-123"])

            # Verify permanent 401 on status check fails immediately without retrying
            status_401_attempts = 0

            def auth_fail_poll_run(cmd: list[str], input=None, **_kwargs) -> subprocess.CompletedProcess:
                nonlocal status_401_attempts
                if cmd[0] == "gpg" and "--output" in cmd:
                    Path(cmd[cmd.index("--output") + 1]).write_text("sig", encoding="utf-8")
                if cmd[0] == "curl" and any("/upload" in c for c in cmd):
                    return subprocess.CompletedProcess(cmd, 0, stdout="deploy-401\n201\n", stderr="")
                if cmd[0] == "curl" and any("/status" in c for c in cmd):
                    status_401_attempts += 1
                    return subprocess.CompletedProcess(cmd, 0, stdout="Unauthorized\n401\n", stderr="")
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            with mock.patch.dict(os.environ, env_vals, clear=True):
                with mock.patch("release.shutil.which", return_value="/usr/bin/tool"):
                    with mock.patch("release.subprocess.run", side_effect=auth_fail_poll_run):
                        with self.assertRaises(release.ReleaseError):
                            release.publish_maven_ci(
                                dist_dir=maven_dir,
                                version=ver,
                                poll_interval=0.0,
                                poll_timeout=5.0,
                                root=root,
                            )
            self.assertEqual(status_401_attempts, 1)

            # Verify max_transient_errors exhaustion aborts immediately without waiting for poll_timeout
            transient_502_attempts = 0

            def exhausted_502_poll_run(cmd: list[str], input=None, **_kwargs) -> subprocess.CompletedProcess:
                nonlocal transient_502_attempts
                if cmd[0] == "gpg" and "--output" in cmd:
                    Path(cmd[cmd.index("--output") + 1]).write_text("sig", encoding="utf-8")
                if cmd[0] == "curl" and any("/upload" in c for c in cmd):
                    return subprocess.CompletedProcess(cmd, 0, stdout="deploy-502\n201\n", stderr="")
                if cmd[0] == "curl" and any("/status" in c for c in cmd):
                    transient_502_attempts += 1
                    return subprocess.CompletedProcess(cmd, 0, stdout="Bad Gateway\n502\n", stderr="")
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            with mock.patch.dict(os.environ, env_vals, clear=True):
                with mock.patch("release.shutil.which", return_value="/usr/bin/tool"):
                    with mock.patch("release.subprocess.run", side_effect=exhausted_502_poll_run):
                        with self.assertRaises(release.ReleaseError) as ctx:
                            release.publish_maven_ci(
                                dist_dir=maven_dir,
                                version=ver,
                                poll_interval=0.0,
                                poll_timeout=60.0,
                                max_transient_errors=3,
                                root=root,
                            )
            self.assertEqual(transient_502_attempts, 3)
            self.assertIn("3 consecutive transient error(s)", str(ctx.exception))

            # Verify FAILED deployment aborts cleanly
            def failed_poll_run(cmd: list[str], input=None, **_kwargs) -> subprocess.CompletedProcess:
                if cmd[0] == "gpg" and "--output" in cmd:
                    Path(cmd[cmd.index("--output") + 1]).write_text("sig", encoding="utf-8")
                if cmd[0] == "curl" and any("/upload" in c for c in cmd):
                    return subprocess.CompletedProcess(cmd, 0, stdout="deploy-fail\n201\n", stderr="")
                if cmd[0] == "curl" and any("/status" in c for c in cmd):
                    return subprocess.CompletedProcess(
                        cmd,
                        0,
                        stdout=json.dumps({"deploymentState": "FAILED", "errors": {"pkg": ["bad sig"]}}) + "\n200\n",
                        stderr="",
                    )
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            with mock.patch.dict(os.environ, env_vals, clear=True):
                with mock.patch("release.shutil.which", return_value="/usr/bin/tool"):
                    with mock.patch("release.subprocess.run", side_effect=failed_poll_run):
                        with self.assertRaises(release.ReleaseError) as ctx:
                            release.publish_maven_ci(
                                dist_dir=maven_dir,
                                version=ver,
                                poll_interval=0.0,
                                poll_timeout=5.0,
                                root=root,
                            )
            self.assertIn("FAILED", str(ctx.exception))

            # Verify timeout aborts cleanly
            def timeout_poll_run(cmd: list[str], input=None, **_kwargs) -> subprocess.CompletedProcess:
                if cmd[0] == "gpg" and "--output" in cmd:
                    Path(cmd[cmd.index("--output") + 1]).write_text("sig", encoding="utf-8")
                if cmd[0] == "curl" and any("/upload" in c for c in cmd):
                    return subprocess.CompletedProcess(cmd, 0, stdout="deploy-slow\n201\n", stderr="")
                if cmd[0] == "curl" and any("/status" in c for c in cmd):
                    return subprocess.CompletedProcess(
                        cmd,
                        0,
                        stdout=json.dumps({"deploymentState": "VALIDATING"}) + "\n200\n",
                        stderr="",
                    )
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            with mock.patch.dict(os.environ, env_vals, clear=True):
                with mock.patch("release.shutil.which", return_value="/usr/bin/tool"):
                    with mock.patch("release.subprocess.run", side_effect=timeout_poll_run):
                        with self.assertRaises(release.ReleaseError) as ctx:
                            release.publish_maven_ci(
                                dist_dir=maven_dir,
                                version=ver,
                                poll_interval=0.01,
                                poll_timeout=0.02,
                                root=root,
                            )
            self.assertIn("Timed out", str(ctx.exception))

            # Verify GPG signing failure preserves stderr in ReleaseError
            def gpg_sign_fail_run(cmd: list[str], input=None, **_kwargs) -> subprocess.CompletedProcess:
                if cmd[0] == "gpg" and "--detach-sign" in cmd:
                    return subprocess.CompletedProcess(cmd, 2, stdout="", stderr="gpg: signing failed: Bad passphrase\n")
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            with mock.patch.dict(os.environ, env_vals, clear=True):
                with mock.patch("release.shutil.which", return_value="/usr/bin/tool"):
                    with mock.patch("release.subprocess.run", side_effect=gpg_sign_fail_run):
                        with self.assertRaises(release.ReleaseError) as ctx:
                            release.publish_maven_ci(dist_dir=maven_dir, version=ver, root=root)
            self.assertIn("Bad passphrase", str(ctx.exception))

            # Verify --publishing-type USER_MANAGED CLI flag forwards publishingType and completes on VALIDATED
            user_managed_cmds: list[list[str]] = []

            def user_managed_run(cmd: list[str], input=None, **_kwargs) -> subprocess.CompletedProcess:
                user_managed_cmds.append(cmd)
                if cmd[0] == "gpg" and "--output" in cmd:
                    Path(cmd[cmd.index("--output") + 1]).write_text("sig", encoding="utf-8")
                if cmd[0] == "curl" and any("/upload" in c for c in cmd):
                    return subprocess.CompletedProcess(cmd, 0, stdout="deploy-um\n201\n", stderr="")
                if cmd[0] == "curl" and any("/status" in c for c in cmd):
                    return subprocess.CompletedProcess(
                        cmd,
                        0,
                        stdout=json.dumps({"deploymentId": "deploy-um", "deploymentState": "VALIDATED"}) + "\n200\n",
                        stderr="",
                    )
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            with mock.patch.dict(os.environ, env_vals, clear=True):
                with mock.patch("release.shutil.which", return_value="/usr/bin/tool"):
                    with mock.patch("release.subprocess.run", side_effect=user_managed_run):
                        rc = release.main(
                            [
                                "--root",
                                str(root),
                                "publish-maven-ci",
                                "--dist",
                                str(maven_dir),
                                "--version",
                                ver,
                                "--publishing-type",
                                "USER_MANAGED",
                                "--poll-interval",
                                "0",
                                "--poll-timeout",
                                "5",
                            ]
                        )
            self.assertEqual(rc, 0)
            um_upload = next(c for c in user_managed_cmds if c[0] == "curl" and any("/upload" in a for a in c))
            um_url = next(a for a in um_upload if "/upload" in a)
            self.assertEqual(urllib_parse.parse_qs(urllib_parse.urlsplit(um_url).query).get("publishingType"), ["USER_MANAGED"])

    def test_publish_maven_ci_real_curl_and_gpg_loopback(self) -> None:
        if not shutil.which("gpg") or not shutil.which("curl"):
            self.skipTest("gpg or curl not installed")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _copy_versioned_files(root)
            ver = release.canonical_version(root)
            maven_dir = root / "maven"
            _create_fake_maven_dist(maven_dir, ver)

            # Generate a passphrase-protected test key
            gen_home = root / "gpg-gen"
            gen_home.mkdir(mode=0o700)
            pw_file = root / "gen-pw"
            pw_file.write_text("test-passphrase-!@#", encoding="utf-8")
            os.chmod(pw_file, 0o600)
            gen_env = {**os.environ, "GNUPGHOME": str(gen_home)}
            try:
                subprocess.run(
                    [
                        "gpg", "--homedir", str(gen_home), "--batch", "--yes",
                        "--pinentry-mode", "loopback", "--passphrase-file", str(pw_file),
                        "--quick-generate-key", "Synurang Test <ci@example.com>", "ed25519", "sign", "1y",
                    ],
                    env=gen_env,
                    check=True,
                    capture_output=True,
                )
                secret_armored = subprocess.run(
                    [
                        "gpg", "--homedir", str(gen_home), "--batch", "--yes",
                        "--pinentry-mode", "loopback", "--passphrase-file", str(pw_file),
                        "--armor", "--export-secret-keys",
                    ],
                    env=gen_env,
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout
            finally:
                release._kill_gpg_agent(gen_home)

            expected_bearer = "Bearer " + base64.b64encode(b"portal-user:portal-token").decode("ascii")
            captured: dict[str, object] = {"status_polls": 0, "upload_entries": []}

            class MockCentralHandler(BaseHTTPRequestHandler):
                def log_message(self, format: str, *args: object) -> None:
                    return

                def do_POST(self) -> None:
                    auth = self.headers.get("Authorization")
                    if auth != expected_bearer:
                        self.send_response(401)
                        self.end_headers()
                        self.wfile.write(b"Unauthorized")
                        return
                    parsed = urllib_parse.urlsplit(self.path)
                    qs = urllib_parse.parse_qs(parsed.query)
                    length = int(self.headers.get("Content-Length", "0"))
                    body = self.rfile.read(length)
                    if parsed.path == "/api/v1/publisher/upload":
                        captured["upload_query"] = qs
                        captured["upload_ctype"] = self.headers.get("Content-Type", "")
                        # Extract the single uploaded ZIP starting at PK\x03\x04 up to the multipart boundary
                        boundary = captured["upload_ctype"].split("boundary=")[-1].encode("ascii")
                        pk_idx = body.find(b"PK\x03\x04")
                        end_idx = body.find(b"\r\n--" + boundary, pk_idx)
                        zip_bytes = body[pk_idx:end_idx]
                        with zipfile.ZipFile(io.BytesIO(zip_bytes), "r") as zf:
                            captured["upload_entries"] = zf.namelist()
                        # Verify multipart contains bundle only (no extra name/publishingType fields)
                        captured["multipart_has_name"] = b'name="name"' in body
                        captured["multipart_has_pubtype"] = b'name="publishingType"' in body
                        self.send_response(201)
                        self.end_headers()
                        self.wfile.write(b"real-deploy-42")
                    elif parsed.path == "/api/v1/publisher/status":
                        captured["status_query"] = qs
                        captured["status_polls"] = int(captured["status_polls"]) + 1
                        state_val = "VALIDATING" if captured["status_polls"] == 1 else "PUBLISHED"
                        payload = json.dumps({"deploymentId": "real-deploy-42", "deploymentState": state_val}).encode("utf-8")
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.end_headers()
                        self.wfile.write(payload)
                    else:
                        self.send_response(404)
                        self.end_headers()

            server = HTTPServer(("127.0.0.1", 0), MockCentralHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                port = server.server_address[1]
                env_vals = {
                    "SONATYPE_USERNAME": "portal-user",
                    "SONATYPE_PASSWORD": "portal-token",
                    "MAVEN_GPG_PRIVATE_KEY": secret_armored,
                    "MAVEN_GPG_PASSPHRASE": "test-passphrase-!@#",
                }
                with mock.patch.dict(os.environ, env_vals, clear=True):
                    res = release.publish_maven_ci(
                        dist_dir=maven_dir,
                        version=ver,
                        upload_url=f"http://127.0.0.1:{port}/api/v1/publisher/upload",
                        poll_interval=0.0,
                        poll_timeout=5.0,
                        root=root,
                    )
            finally:
                server.shutdown()
                server.server_close()

            self.assertEqual(res, {"bundle": f"synurang-{ver}", "deployment_id": "real-deploy-42", "state": "PUBLISHED"})
            self.assertEqual(captured["upload_query"], {"name": [f"synurang-{ver}"], "publishingType": ["AUTOMATIC"]})
            self.assertEqual(captured["status_query"], {"id": ["real-deploy-42"]})
            self.assertEqual(captured["status_polls"], 2)
            self.assertFalse(captured["multipart_has_name"])
            self.assertFalse(captured["multipart_has_pubtype"])
            # All 4 artifacts * 4 files * 4 (.file + .md5 + .sha1 + .asc) = 64 entries in 1 ZIP
            entries = captured["upload_entries"]
            self.assertEqual(len(entries), 64)
            self.assertEqual(sum(1 for e in entries if e.endswith(".asc")), 16)

    def test_publish_maven_local_credentials_and_cli_validation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _copy_versioned_files(root)
            ver = release.canonical_version(root)
            maven_dir = root / "maven"
            _create_fake_maven_dist(maven_dir, ver)

            settings_path = root / ".maven-settings.xml"
            settings_path.write_text(
                '<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">\n'
                "  <servers>\n"
                "    <server><id>ossrh</id><username>alt-user</username><password>alt-pass</password></server>\n"
                "    <server><id>central</id><username>local-user</username><password>local-pass</password></server>\n"
                "  </servers>\n"
                "</settings>\n",
                encoding="utf-8",
            )
            self.assertEqual(release._parse_maven_settings_credentials(settings_path), ("local-user", "local-pass"))
            self.assertEqual(
                release._parse_maven_settings_credentials(settings_path, server_id="ossrh"),
                ("alt-user", "alt-pass"),
            )
            self.assertEqual(
                release._parse_maven_settings_credentials(settings_path, server_id="  ossrh  "),
                ("alt-user", "alt-pass"),
            )
            with self.assertRaisesRegex(release.ReleaseError, "server_id must not be empty"):
                release._parse_maven_settings_credentials(settings_path, server_id="   ")

            # Symlinked settings files should be accepted
            symlink_settings = root / "symlink-settings.xml"
            symlink_settings.symlink_to(settings_path)
            self.assertEqual(release._parse_maven_settings_credentials(symlink_settings), ("local-user", "local-pass"))

            bad_settings = root / "bad-settings.xml"
            bad_settings.write_text("<settings><servers><server><id>other</id></server></servers></settings>", encoding="utf-8")
            with self.assertRaisesRegex(release.ReleaseError, "Server 'central' not found"):
                release._parse_maven_settings_credentials(bad_settings)

            # Env overrides, partial env vars, and newlines in credentials
            with mock.patch.dict(
                os.environ,
                {"SONATYPE_USERNAME": "env-user", "SONATYPE_PASSWORD": "env-pass"},
                clear=True,
            ):
                self.assertEqual(
                    release._resolve_local_maven_credentials(settings_path=root / "missing.xml"),
                    ("env-user", "env-pass"),
                )
            with mock.patch.dict(os.environ, {"SONATYPE_USERNAME": "only-user"}, clear=True):
                with self.assertRaises(release.ReleaseError):
                    release._resolve_local_maven_credentials(settings_path=settings_path)
            with mock.patch.dict(
                os.environ,
                {"SONATYPE_USERNAME": "bad\nuser", "SONATYPE_PASSWORD": "ok"},
                clear=True,
            ):
                with self.assertRaisesRegex(release.ReleaseError, "must not contain newlines"):
                    release._resolve_local_maven_credentials(settings_path=settings_path)

            # CLI rejects specifying both --tag and --dist, or passing neither
            with self.assertRaises(SystemExit) as both_exit:
                release._build_parser().parse_args(["publish-maven-local", "--tag", f"v{ver}", "--dist", str(maven_dir)])
            self.assertEqual(both_exit.exception.code, 2)
            with self.assertRaises(SystemExit) as neither_exit:
                release._build_parser().parse_args(["publish-maven-local"])
            self.assertEqual(neither_exit.exception.code, 2)

            # Rolling 'nightly' tag, --version with --tag, and --repo/--allow-draft with --dist must be rejected
            with self.assertRaisesRegex(release.ReleaseError, "must start with 'v'"):
                release.publish_maven_local(tag="nightly", allow_prerelease=True, dry_run=True, root=root)
            with self.assertRaisesRegex(release.ReleaseError, "Do not pass --version together with --tag"):
                release.publish_maven_local(tag=f"v{ver}", version=ver, dry_run=True, root=root)
            with self.assertRaisesRegex(release.ReleaseError, "Do not pass --repo together with --dist"):
                release.publish_maven_local(dist_dir=maven_dir, repo="ivere27/synurang", dry_run=True, root=root)
            with self.assertRaisesRegex(release.ReleaseError, "Do not pass --allow-draft together with --dist"):
                release.publish_maven_local(dist_dir=maven_dir, allow_draft=True, dry_run=True, root=root)

            # Fail-fast: prerelease tag rejects before reading credentials/settings or calling gh
            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch("release.subprocess.run") as run_mock:
                    with self.assertRaisesRegex(release.ReleaseError, "Refusing to publish prerelease version"):
                        release.publish_maven_local(
                            tag=f"v{ver}-rc.1",
                            settings_path=root / "nonexistent-settings.xml",
                            dry_run=False,
                            root=root,
                        )
                    run_mock.assert_not_called()

            # Fail-fast: missing credentials/settings must abort before touching GitHub CLI on --tag runs
            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch("release.subprocess.run") as run_mock:
                    with self.assertRaisesRegex(release.ReleaseError, "Maven settings not found"):
                        release.publish_maven_local(
                            tag=f"v{ver}",
                            settings_path=root / "nonexistent-settings.xml",
                            dry_run=False,
                            root=root,
                        )
                    run_mock.assert_not_called()

            # Fail-fast: invalid upload_url / un-derivable status_url must abort before reading settings or calling gh/gpg
            for bad_url in ("", "not-a-url", "ftp://example.com/upload", "https://example.com/custom-endpoint"):
                with mock.patch.dict(os.environ, {}, clear=True):
                    with mock.patch("release.subprocess.run") as run_mock:
                        with self.assertRaises(release.ReleaseError):
                            release.publish_maven_local(
                                tag=f"v{ver}",
                                settings_path=root / "nonexistent-settings.xml",
                                upload_url=bad_url,
                                dry_run=False,
                                root=root,
                            )
                        run_mock.assert_not_called()
            self.assertEqual(
                release._derive_maven_status_url(
                    "https://example.com/custom-upload",
                    "https://example.com/custom-status",
                ),
                "https://example.com/custom-status",
            )

            # Fail-fast: missing curl must abort before downloading from GitHub or GPG-signing
            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch(
                    "release.shutil.which",
                    side_effect=lambda tool: None if tool == "curl" else f"/usr/bin/{tool}",
                ):
                    with mock.patch("release.subprocess.run") as run_mock:
                        with self.assertRaisesRegex(release.ReleaseError, "curl is required"):
                            release.publish_maven_local(
                                tag=f"v{ver}",
                                settings_path=settings_path,
                                dry_run=False,
                                root=root,
                            )
                        run_mock.assert_not_called()

            # _gpg_sign_file_local: GPG_TTY="" fallback to ttyname when stdin is a tty, and '--' option delimiter
            sample_artifact = root / "-leading-dash-artifact.pom"
            sample_artifact.write_text("<project/>", encoding="utf-8")

            def fake_tty_sign(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
                self.assertEqual(cmd[-2:], ["--", str(sample_artifact)])
                self.assertEqual(kwargs["env"].get("GPG_TTY"), "/dev/pts/9")
                Path(cmd[cmd.index("--output") + 1]).write_text("-----BEGIN PGP SIGNATURE-----\n", encoding="utf-8")
                return subprocess.CompletedProcess(cmd, 0)

            with mock.patch.dict(os.environ, {"GPG_TTY": ""}, clear=True):
                with mock.patch("release.sys.stdin.isatty", return_value=True):
                    with mock.patch("release.sys.stdin.fileno", return_value=0):
                        with mock.patch("release.os.ttyname", return_value="/dev/pts/9", create=True):
                            with mock.patch("release.subprocess.run", side_effect=fake_tty_sign):
                                asc = release._gpg_sign_file_local(sample_artifact)
                                self.assertTrue(asc.is_file())

            # _gpg_sign_file_local must not raise AttributeError on platforms without os.ttyname (Windows)
            def fake_no_ttyname_sign(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
                self.assertEqual(kwargs["env"].get("GPG_TTY"), "")
                Path(cmd[cmd.index("--output") + 1]).write_text("-----BEGIN PGP SIGNATURE-----\n", encoding="utf-8")
                return subprocess.CompletedProcess(cmd, 0)

            with mock.patch.dict(os.environ, {"GPG_TTY": ""}, clear=True):
                with mock.patch("release.sys.stdin.isatty", return_value=True):
                    with mock.patch("release.os", SimpleNamespace(environ=os.environ)):
                        with mock.patch("release.subprocess.run", side_effect=fake_no_ttyname_sign):
                            asc = release._gpg_sign_file_local(sample_artifact)
                            self.assertTrue(asc.is_file())

            # _write_secret_file creates files atomically with 0600 permissions
            secret_path = root / "secret-passphrase"
            release._write_secret_file(secret_path, "secret-value")
            self.assertEqual(secret_path.read_text(encoding="utf-8"), "secret-value")
            self.assertEqual(stat.S_IMODE(secret_path.stat().st_mode), 0o600)

            # Dry run on local --dist succeeds without credentials or GPG
            with mock.patch.dict(os.environ, {}, clear=True):
                dry_dist = release.publish_maven_local(dist_dir=maven_dir, version=ver, dry_run=True, root=root)
            self.assertEqual(dry_dist, {"bundle": f"synurang-{ver}", "deployment_id": "dry-run", "state": "DRY_RUN"})

    def test_publish_maven_local_github_release_download_and_verification(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _copy_versioned_files(root)
            ver = release.canonical_version(root)
            maven_dir = root / "maven"
            _create_fake_maven_dist(maven_dir, ver)

            rel_assets_dir = root / "gh-assets"
            rel_assets_dir.mkdir()
            for p in maven_dir.iterdir():
                shutil.copy2(p, rel_assets_dir / p.name)
            (rel_assets_dir / "extra-codegen.tar.gz").write_bytes(b"codegen")
            all_paths = sorted(rel_assets_dir.iterdir(), key=lambda p: p.name)
            (rel_assets_dir / "SHA256SUMS").write_text(release.checksum_text(all_paths), encoding="utf-8")

            gh_meta = [
                {
                    "id": 1000 + idx,
                    "name": p.name,
                    "size": p.stat().st_size,
                    "state": "uploaded",
                    "digest": "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest(),
                }
                for idx, p in enumerate(sorted(rel_assets_dir.iterdir(), key=lambda p: p.name))
            ]
            rel_state = {"tag_name": f"v{ver}", "draft": False, "prerelease": False, "assets": list(gh_meta)}
            gh_calls: list[list[str]] = []

            def fake_gh_run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
                gh_calls.append(cmd)
                if cmd[:2] == ["gh", "api"]:
                    path = next(c for c in cmd if c.startswith("repos/"))
                    if "releases?per_page=100" in path:
                        return subprocess.CompletedProcess(
                            cmd,
                            0,
                            stdout=json.dumps(
                                [[{
                                    "id": 77,
                                    "tag_name": rel_state["tag_name"],
                                    "draft": rel_state["draft"],
                                    "prerelease": rel_state["prerelease"],
                                }]]
                            ),
                            stderr="",
                        )
                    if "/assets?per_page=100" in path:
                        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps([rel_state["assets"]]), stderr="")
                    if "/releases/assets/" in path:
                        asset_id = int(path.rsplit("/", 1)[-1])
                        meta = next(item for item in rel_state["assets"] if item["id"] == asset_id)
                        data = (rel_assets_dir / meta["name"]).read_bytes()
                        stdout_fh = kwargs.get("stdout")
                        if stdout_fh is not None:
                            stdout_fh.write(data)
                            return subprocess.CompletedProcess(cmd, 0, stdout=b"", stderr=b"")
                        return subprocess.CompletedProcess(cmd, 0, stdout=data, stderr=b"")
                if cmd[:3] == ["gh", "release", "download"]:
                    dst_dir = Path(cmd[cmd.index("--dir") + 1])
                    patterns = [cmd[i + 1] for i, tok in enumerate(cmd) if tok == "-p"]
                    for name in patterns:
                        shutil.copy2(rel_assets_dir / name, dst_dir / name)
                    return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
                raise AssertionError(f"Unexpected subprocess command: {cmd}")

            with mock.patch("release.shutil.which", return_value="/usr/bin/gh"):
                with mock.patch("release.subprocess.run", side_effect=fake_gh_run):
                    # Published release uses `gh release download`
                    dry_tag = release.publish_maven_local(
                        tag=f"v{ver}",
                        repo="ivere27/synurang",
                        dry_run=True,
                        root=root,
                    )
                    self.assertEqual(dry_tag["state"], "DRY_RUN")
                    self.assertTrue(any(c[:3] == ["gh", "release", "download"] for c in gh_calls))

                    # Draft release is rejected unless allow_draft=True; when allowed, downloads via asset ID API
                    rel_state["draft"] = True
                    with self.assertRaisesRegex(release.ReleaseError, "is a draft"):
                        release.publish_maven_local(tag=f"v{ver}", repo="ivere27/synurang", dry_run=True, root=root)

                    # Draft asset lacking valid integer id must fail fast before any asset download
                    gh_calls.clear()
                    sums_meta_entry = next(item for item in gh_meta if item["name"] == "SHA256SUMS")
                    saved_id = sums_meta_entry.pop("id")
                    try:
                        with self.assertRaisesRegex(release.ReleaseError, "lacks a valid asset id"):
                            release.publish_maven_local(
                                tag=f"v{ver}",
                                repo="ivere27/synurang",
                                allow_draft=True,
                                dry_run=True,
                                root=root,
                            )
                        self.assertFalse(
                            any(c[:2] == ["gh", "api"] and any("/releases/assets/" in a for a in c) for c in gh_calls)
                        )
                    finally:
                        sums_meta_entry["id"] = saved_id

                    gh_calls.clear()
                    dry_draft = release.publish_maven_local(
                        tag=f"v{ver}",
                        repo="ivere27/synurang",
                        allow_draft=True,
                        dry_run=True,
                        root=root,
                    )
                    self.assertEqual(dry_draft["state"], "DRY_RUN")
                    self.assertFalse(any(c[:3] == ["gh", "release", "download"] for c in gh_calls))
                    expected_asset_ids = {
                        item["id"]
                        for item in gh_meta
                        if item["name"] in (release.expected_maven_filenames(ver) | {"SHA256SUMS"})
                    }
                    fetched_asset_ids = {
                        int(next(c for c in cmd if "/releases/assets/" in c).rsplit("/", 1)[-1])
                        for cmd in gh_calls
                        if cmd[:2] == ["gh", "api"] and any("/releases/assets/" in c for c in cmd)
                    }
                    self.assertEqual(fetched_asset_ids, expected_asset_ids)

                    # Failed gh api draft download must unlink partial file before raising ReleaseError
                    partial_dl_dir = root / "partial-dl"
                    failing_asset_id = sums_meta_entry["id"]
                    failing_asset_name = sums_meta_entry["name"]

                    def failing_draft_dl_run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
                        if cmd[:2] == ["gh", "api"] and any(f"/releases/assets/{failing_asset_id}" in c for c in cmd):
                            stdout_fh = kwargs.get("stdout")
                            if stdout_fh is not None:
                                stdout_fh.write(b"partial-corrupt-bytes")
                            return subprocess.CompletedProcess(cmd, 1, stdout=b"", stderr=b"HTTP 502 Bad Gateway")
                        return fake_gh_run(cmd, **kwargs)

                    with mock.patch("release.subprocess.run", side_effect=failing_draft_dl_run):
                        with self.assertRaisesRegex(release.ReleaseError, "gh api failed downloading draft asset"):
                            release._download_maven_from_github_release(
                                tag=f"v{ver}",
                                version=ver,
                                repo="ivere27/synurang",
                                download_dir=partial_dl_dir,
                                allow_draft=True,
                                root=root,
                            )
                    self.assertFalse((partial_dl_dir / failing_asset_name).exists())
                    rel_state["draft"] = False

                    # Failed non-draft `gh release download` must raise ReleaseError (not CalledProcessError)
                    def failing_release_dl_run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
                        if cmd[:3] == ["gh", "release", "download"]:
                            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="release asset timeout")
                        return fake_gh_run(cmd, **kwargs)

                    with mock.patch("release.subprocess.run", side_effect=failing_release_dl_run):
                        with self.assertRaisesRegex(release.ReleaseError, "gh release download failed"):
                            release._download_maven_from_github_release(
                                tag=f"v{ver}",
                                version=ver,
                                repo="ivere27/synurang",
                                download_dir=root / "failed-pub-dl",
                                root=root,
                            )

                    # Non-positive or bool release id must fall back safely without calling /assets
                    def invalid_release_id_run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
                        if cmd[:2] == ["gh", "api"] and any("releases?per_page=100" in c for c in cmd):
                            return subprocess.CompletedProcess(
                                cmd,
                                0,
                                stdout=json.dumps(
                                    [[{
                                        "id": True,
                                        "tag_name": rel_state["tag_name"],
                                        "draft": False,
                                        "prerelease": False,
                                        "assets": rel_state["assets"],
                                    }]]
                                ),
                                stderr="",
                            )
                        if cmd[:2] == ["gh", "api"] and any("/assets?per_page=100" in c for c in cmd):
                            raise AssertionError("Should not query /assets for invalid bool release id")
                        return fake_gh_run(cmd, **kwargs)

                    with mock.patch("release.subprocess.run", side_effect=invalid_release_id_run):
                        release._download_maven_from_github_release(
                            tag=f"v{ver}",
                            version=ver,
                            repo="ivere27/synurang",
                            download_dir=root / "bool-id-dl",
                            root=root,
                        )

                    # Prerelease GitHub release is rejected unless allow_prerelease=True
                    rel_state["prerelease"] = True
                    with self.assertRaisesRegex(release.ReleaseError, "is a prerelease"):
                        release.publish_maven_local(tag=f"v{ver}", repo="ivere27/synurang", dry_run=True, root=root)
                    dry_pre_gh = release.publish_maven_local(
                        tag=f"v{ver}",
                        repo="ivere27/synurang",
                        allow_prerelease=True,
                        dry_run=True,
                        root=root,
                    )
                    self.assertEqual(dry_pre_gh["state"], "DRY_RUN")
                    rel_state["prerelease"] = False

                    # Tampered GitHub asset digest must fail at API digest check
                    aar_name = f"synurang-android-{ver}.aar"
                    aar_meta = next(item for item in gh_meta if item["name"] == aar_name)
                    orig_aar_digest = aar_meta["digest"]
                    aar_meta["digest"] = "sha256:" + ("0" * 64 if not orig_aar_digest.endswith("0" * 64) else "1" * 64)
                    with self.assertRaisesRegex(release.ReleaseError, rf"Downloaded asset '{re.escape(aar_name)}' digest mismatch"):
                        release.publish_maven_local(tag=f"v{ver}", repo="ivere27/synurang", dry_run=True, root=root)
                    aar_meta["digest"] = orig_aar_digest

                    # Tampered SHA256SUMS for a Maven artifact (with matching GitHub digest on SHA256SUMS)
                    # must reach and fail at SHA256SUMS manifest verification
                    sums_path = rel_assets_dir / "SHA256SUMS"
                    sums_meta = next(item for item in gh_meta if item["name"] == "SHA256SUMS")
                    orig_sums = sums_path.read_text(encoding="utf-8")
                    mutated_lines = []
                    for line in orig_sums.splitlines():
                        if line.endswith(f"  {aar_name}"):
                            flipped = ("1" if line[0] == "0" else "0") + line[1:]
                            mutated_lines.append(flipped)
                        else:
                            mutated_lines.append(line)
                    sums_path.write_text("\n".join(mutated_lines) + "\n", encoding="utf-8")
                    sums_bytes = sums_path.read_bytes()
                    sums_meta["size"] = len(sums_bytes)
                    sums_meta["digest"] = "sha256:" + hashlib.sha256(sums_bytes).hexdigest()
                    with self.assertRaisesRegex(release.ReleaseError, rf"SHA256SUMS mismatch for {re.escape(aar_name)}"):
                        release.publish_maven_local(tag=f"v{ver}", repo="ivere27/synurang", dry_run=True, root=root)
                    sums_path.write_text(orig_sums, encoding="utf-8")
                    orig_sums_bytes = sums_path.read_bytes()
                    sums_meta["size"] = len(orig_sums_bytes)
                    sums_meta["digest"] = "sha256:" + hashlib.sha256(orig_sums_bytes).hexdigest()

    def test_publish_maven_local_real_gpg_signing_and_upload(self) -> None:
        if not shutil.which("gpg") or not shutil.which("curl"):
            self.skipTest("gpg or curl not installed")

        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, True)
        root = Path(tmp)
        _copy_versioned_files(root)
        ver = release.canonical_version(root)
        maven_dir = root / "maven"
        _create_fake_maven_dist(maven_dir, ver)

        settings_path = root / ".maven-settings.xml"
        settings_path.write_text(
            '<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">\n'
            "  <servers>\n"
            "    <server><id>ossrh</id><username>alt-user</username><password>alt-pass</password></server>\n"
            "    <server><id>central</id><username>local-user</username><password>local-pass</password></server>\n"
            "  </servers>\n"
            "</settings>\n",
            encoding="utf-8",
        )
        symlink_settings = root / "symlink-settings.xml"
        symlink_settings.symlink_to(settings_path)

        local_gnupg = root / "local-gnupg"
        local_gnupg.mkdir(mode=0o700)
        self.addCleanup(release._kill_gpg_agent, local_gnupg)
        gpg_env = {**os.environ, "GNUPGHOME": str(local_gnupg)}
        try:
            subprocess.run(
                [
                    "gpg", "--homedir", str(local_gnupg), "--batch", "--yes",
                    "--pinentry-mode", "loopback", "--passphrase", "",
                    "--quick-generate-key", "Synurang Local <local@example.com>", "ed25519", "sign", "1y",
                ],
                env=gpg_env,
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as err:
            self.skipTest(f"Local gpg key generation unsupported: {err}")

        pass_gnupg = root / "pass-gnupg"
        pass_gnupg.mkdir(mode=0o700)
        self.addCleanup(release._kill_gpg_agent, pass_gnupg)
        pass_pw = root / "pass-pw"
        pass_pw.write_text("local-passphrase-!@#", encoding="utf-8")
        os.chmod(pass_pw, 0o600)
        pass_gpg_env = {**os.environ, "GNUPGHOME": str(pass_gnupg)}
        try:
            subprocess.run(
                [
                    "gpg", "--homedir", str(pass_gnupg), "--batch", "--yes",
                    "--pinentry-mode", "loopback", "--passphrase-file", str(pass_pw),
                    "--quick-generate-key", "Synurang Protected <protected@example.com>", "ed25519", "sign", "1y",
                ],
                env=pass_gpg_env,
                check=True,
                capture_output=True,
            )
            pass_fpr = subprocess.run(
                [
                    "gpg", "--homedir", str(pass_gnupg), "--batch", "--with-colons", "--list-secret-keys",
                ],
                env=pass_gpg_env,
                check=True,
                capture_output=True,
                text=True,
            )
            fpr_line = next(line for line in pass_fpr.stdout.splitlines() if line.startswith("fpr:"))
            pass_key_fpr = fpr_line.split(":")[9]
        except subprocess.CalledProcessError as err:
            self.skipTest(f"Local passphrase gpg key generation unsupported: {err}")

        expected_bearer = "Bearer " + base64.b64encode(b"local-user:local-pass").decode("ascii")
        expected_alt_bearer = "Bearer " + base64.b64encode(b"alt-user:alt-pass").decode("ascii")
        captured: dict[str, object] = {"entries": [], "auth": ""}

        class LocalMockCentralHandler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                return

            def do_POST(self) -> None:
                auth = self.headers.get("Authorization")
                if auth not in (expected_bearer, expected_alt_bearer):
                    self.send_response(401)
                    self.end_headers()
                    return
                captured["auth"] = auth
                parsed = urllib_parse.urlsplit(self.path)
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                if parsed.path == "/api/v1/publisher/upload":
                    ctype = self.headers.get("Content-Type", "")
                    boundary = ctype.split("boundary=")[-1].encode("ascii")
                    pk_idx = body.find(b"PK\x03\x04")
                    end_idx = body.find(b"\r\n--" + boundary, pk_idx)
                    with zipfile.ZipFile(io.BytesIO(body[pk_idx:end_idx]), "r") as zf:
                        captured["entries"] = zf.namelist()
                    self.send_response(201)
                    self.end_headers()
                    self.wfile.write(b"local-deploy-99")
                elif parsed.path == "/api/v1/publisher/status":
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(json.dumps({"deploymentId": "local-deploy-99", "deploymentState": "PUBLISHED"}).encode("utf-8"))
                else:
                    self.send_response(404)
                    self.end_headers()

        server = HTTPServer(("127.0.0.1", 0), LocalMockCentralHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            # 1) Standard local GPG keyring path without MAVEN_GPG_PASSPHRASE (via symlinked settings)
            with mock.patch.dict(os.environ, {"GNUPGHOME": str(local_gnupg), "PATH": os.environ.get("PATH", "")}, clear=True):
                res = release.publish_maven_local(
                    dist_dir=maven_dir,
                    version=ver,
                    settings_path=symlink_settings,
                    upload_url=f"http://127.0.0.1:{port}/api/v1/publisher/upload",
                    poll_interval=0.0,
                    poll_timeout=5.0,
                    root=root,
                )
            self.assertEqual(res, {"bundle": f"synurang-{ver}", "deployment_id": "local-deploy-99", "state": "PUBLISHED"})
            self.assertEqual(captured["auth"], expected_bearer)
            self.assertEqual(len(captured["entries"]), 64)
            self.assertEqual(sum(1 for e in captured["entries"] if e.endswith(".asc")), 16)

            # 2) Loopback passphrase path (MAVEN_GPG_PASSPHRASE) + explicit --gpg-key + custom --server-id via CLI main()
            captured["entries"] = []
            cli_stdout = io.StringIO()
            with mock.patch.dict(
                os.environ,
                {
                    "GNUPGHOME": str(pass_gnupg),
                    "MAVEN_GPG_PASSPHRASE": "local-passphrase-!@#",
                    "PATH": os.environ.get("PATH", ""),
                },
                clear=True,
            ):
                with redirect_stdout(cli_stdout):
                    rc = release.main(
                        [
                            "--root",
                            str(root),
                            "publish-maven-local",
                            "--dist",
                            str(maven_dir),
                            "--version",
                            ver,
                            "--settings",
                            str(settings_path),
                            "--server-id",
                            "ossrh",
                            "--gpg-key",
                            pass_key_fpr,
                            "--upload-url",
                            f"http://127.0.0.1:{port}/api/v1/publisher/upload",
                            "--poll-interval",
                            "0",
                            "--poll-timeout",
                            "5",
                        ]
                    )
            self.assertEqual(rc, 0)
            self.assertIn(
                f"Completed Maven Central deployment for synurang-{ver} (deploymentId=local-deploy-99, state=PUBLISHED)",
                cli_stdout.getvalue(),
            )
            self.assertEqual(captured["auth"], expected_alt_bearer)
            self.assertEqual(len(captured["entries"]), 64)
            self.assertEqual(sum(1 for e in captured["entries"] if e.endswith(".asc")), 16)
        finally:
            server.shutdown()
            server.server_close()

    def test_makefile_publish_maven_bool_validation(self) -> None:
        if not shutil.which("make"):
            self.skipTest("make not installed")

        for truthy in ("1", "true", "yes", "TRUE", "True", "Yes"):
            res = subprocess.run(
                ["make", "-n", "publish_maven", f"DRY_RUN={truthy}", f"ALLOW_PRERELEASE={truthy}"],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("--dry-run", res.stdout)
            self.assertIn("--allow-prerelease", res.stdout)

        for falsy in ("", "0", "false", "no", "FALSE", "False", "No"):
            res = subprocess.run(
                [
                    "make", "-n", "publish_maven_release",
                    "TAG=v0.8.0",
                    f"DRY_RUN={falsy}",
                    f"ALLOW_PRERELEASE={falsy}",
                    f"ALLOW_DRAFT={falsy}",
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertNotIn("--dry-run", res.stdout)
            self.assertNotIn("--allow-prerelease", res.stdout)
            self.assertNotIn("--allow-draft", res.stdout)

        for bad in ("ture", "on", "y", "1 0"):
            res_local = subprocess.run(
                ["make", "-n", "publish_maven", f"DRY_RUN={bad}"],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(res_local.returncode, 0)
            self.assertIn("Invalid DRY_RUN", res_local.stderr)

            for var_name in ("DRY_RUN", "ALLOW_PRERELEASE", "ALLOW_DRAFT"):
                res_rel = subprocess.run(
                    ["make", "-n", "publish_maven_release", "TAG=v0.8.0", f"{var_name}={bad}"],
                    cwd=REPO_ROOT,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(res_rel.returncode, 0)
                self.assertIn(f"Invalid {var_name}", res_rel.stderr)

    def test_bool_flag_parsing_and_maven_settings_edge_cases(self) -> None:
        self.assertFalse(release.parse_bool_flag("", name="FLAG"))
        for truthy in ("1", "true", "True", "TRUE", "yes", " YES "):
            self.assertTrue(release.parse_bool_flag(truthy, name="FLAG"))
        for falsy in ("0", "false", "False", "FALSE", "no", " NO "):
            self.assertFalse(release.parse_bool_flag(falsy, name="FLAG"))
        for invalid in ("ture", "on", "y", "1 0"):
            with self.assertRaisesRegex(release.ReleaseError, "Invalid boolean value for FLAG"):
                release.parse_bool_flag(invalid, name="FLAG")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            staged = self._make_staged_fixture(root)
            ver = release.canonical_version(root)

            # Invalid SYNURANG_ALLOW_OLDER_RELEASE fails fast even if --allow-older is passed
            with mock.patch.dict(os.environ, {"SYNURANG_ALLOW_OLDER_RELEASE": "ture"}):
                rc = release.main(
                    [
                        "--root", str(root),
                        "release-ci",
                        "--channel", "draft-stable",
                        "--dist", str(staged),
                        "--sha", "abcdef0123456789abcdef0123456789abcdef01",
                        "--tag", f"v{ver}",
                        "--allow-older",
                        "--dry-run",
                    ]
                )
            self.assertEqual(rc, 1)

            # Duplicate <server><id> must raise ReleaseError
            dup_settings = root / "dup-settings.xml"
            dup_settings.write_text(
                "<settings><servers>"
                "<server><id>central</id><username>u1</username><password>p1</password></server>"
                "<server><id>central</id><username>u2</username><password>p2</password></server>"
                "</servers></settings>",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(release.ReleaseError, "Duplicate <server><id>central</id>"):
                release._parse_maven_settings_credentials(dup_settings)

            # Encrypted Maven password ({...}) must raise clear ReleaseError
            enc_settings = root / "enc-settings.xml"
            enc_settings.write_text(
                "<settings><servers>"
                "<server><id>central</id><username>u1</username><password>{COQLCE6DU6GtcS5P=}</password></server>"
                "</servers></settings>",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(release.ReleaseError, "Encrypted Maven <password>"):
                release._parse_maven_settings_credentials(enc_settings)

            # Missing <username>, missing <password>, whitespace-only <password>, and newlines
            no_user = root / "no-user.xml"
            no_user.write_text(
                "<settings><servers><server><id>central</id><password>p1</password></server></servers></settings>",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(release.ReleaseError, "Missing <username>"):
                release._parse_maven_settings_credentials(no_user)

            no_pass = root / "no-pass.xml"
            no_pass.write_text(
                "<settings><servers><server><id>central</id><username>u1</username></server></servers></settings>",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(release.ReleaseError, "Missing <password>"):
                release._parse_maven_settings_credentials(no_pass)

            ws_pass = root / "ws-pass.xml"
            ws_pass.write_text(
                "<settings><servers><server><id>central</id><username>u1</username><password>   </password></server></servers></settings>",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(release.ReleaseError, "Missing <password>"):
                release._parse_maven_settings_credentials(ws_pass)

            nl_pass = root / "nl-pass.xml"
            nl_pass.write_text(
                "<settings><servers><server><id>central</id><username>u1</username><password>p1\n</password></server></servers></settings>",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(release.ReleaseError, "Invalid newline in <password>"):
                release._parse_maven_settings_credentials(nl_pass)

            # Leading/trailing spaces in <password> and SONATYPE_PASSWORD are preserved verbatim (not stripped)
            spaced_settings = root / "spaced-settings.xml"
            spaced_settings.write_text(
                "<settings><servers><server><id>central</id><username> u1 </username><password> p1 </password></server></servers></settings>",
                encoding="utf-8",
            )
            self.assertEqual(release._parse_maven_settings_credentials(spaced_settings), ("u1", " p1 "))
            with mock.patch.dict(os.environ, {"SONATYPE_USERNAME": " env-u ", "SONATYPE_PASSWORD": " env-p "}, clear=True):
                self.assertEqual(release._resolve_local_maven_credentials(settings_path=spaced_settings), ("env-u", " env-p "))
            with mock.patch.dict(os.environ, {"SONATYPE_USERNAME": "env-u", "SONATYPE_PASSWORD": "env-p\n"}, clear=True):
                with self.assertRaisesRegex(release.ReleaseError, "SONATYPE_PASSWORD must not contain newlines"):
                    release._resolve_local_maven_credentials(settings_path=spaced_settings)

            # Malformed XML wraps ET.ParseError as ReleaseError and fails CLI cleanly
            bad_xml = root / "malformed.xml"
            bad_xml.write_text("<settings><servers><server></settings>", encoding="utf-8")
            with self.assertRaisesRegex(release.ReleaseError, "Malformed Maven settings XML"):
                release._parse_maven_settings_credentials(bad_xml)
            maven_dir = root / "maven"
            _create_fake_maven_dist(maven_dir, ver)
            with mock.patch.dict(os.environ, {}, clear=True):
                rc_xml = release.main(
                    [
                        "--root", str(root),
                        "publish-maven-local",
                        "--dist", str(maven_dir),
                        "--version", ver,
                        "--settings", str(bad_xml),
                    ]
                )
            self.assertEqual(rc_xml, 1)

    def test_maven_ci_local_symmetry_gh_host_passphrase_and_hints(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _copy_versioned_files(root)
            ver = release.canonical_version(root)
            maven_dir = root / "maven"
            _create_fake_maven_dist(maven_dir, ver)

            # 1) publish_maven_ci rejects newlines in SONATYPE_USERNAME/PASSWORD fail-fast before invoking GPG
            with mock.patch.dict(
                os.environ,
                {
                    "SONATYPE_USERNAME": "ci-user",
                    "SONATYPE_PASSWORD": "ci-pass\n",
                    "MAVEN_GPG_PRIVATE_KEY": "-----BEGIN PGP PRIVATE KEY BLOCK-----\nabc\n-----END PGP PRIVATE KEY BLOCK-----\n",
                },
                clear=True,
            ):
                with mock.patch("release.shutil.which", return_value="/usr/bin/tool"):
                    with mock.patch("release.subprocess.run") as run_mock:
                        with self.assertRaisesRegex(release.ReleaseError, "SONATYPE_PASSWORD must not contain newlines"):
                            release.publish_maven_ci(dist_dir=maven_dir, version=ver, root=root)
                        run_mock.assert_not_called()

            # 2) publish_maven_ci unlinks passphrase file immediately after gpg --import and prints completion log in main()
            seen_passphrase_during_sign_or_curl: list[bool] = []
            sign_inputs: list[str | None] = []

            def fake_ci_run(cmd: list[str], input=None, **_kwargs) -> subprocess.CompletedProcess:
                if cmd[0] == "gpg" and "--detach-sign" in cmd:
                    gnupg_dir = Path(cmd[cmd.index("--homedir") + 1]).parent
                    seen_passphrase_during_sign_or_curl.append((gnupg_dir / "passphrase").exists())
                    sign_inputs.append(input)
                    Path(cmd[cmd.index("--output") + 1]).write_text("sig", encoding="utf-8")
                if cmd[0] == "curl":
                    if any("/upload" in c for c in cmd):
                        return subprocess.CompletedProcess(cmd, 0, stdout="deploy-ci-1\n201\n", stderr="")
                    if any("/status" in c for c in cmd):
                        return subprocess.CompletedProcess(
                            cmd,
                            0,
                            stdout=json.dumps({"deploymentId": "deploy-ci-1", "deploymentState": "PUBLISHED"}) + "\n200\n",
                            stderr="",
                        )
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            ci_stdout = io.StringIO()
            with mock.patch.dict(
                os.environ,
                {
                    "SONATYPE_USERNAME": "ci-user",
                    "SONATYPE_PASSWORD": "ci-pass",
                    "MAVEN_GPG_PRIVATE_KEY": "-----BEGIN PGP PRIVATE KEY BLOCK-----\nabc\n-----END PGP PRIVATE KEY BLOCK-----\n",
                    "MAVEN_GPG_PASSPHRASE": "ci-gpg-secret",
                },
                clear=True,
            ):
                with mock.patch("release.shutil.which", return_value="/usr/bin/tool"):
                    with mock.patch("release.subprocess.run", side_effect=fake_ci_run):
                        with redirect_stdout(ci_stdout):
                            rc = release.main(
                                [
                                    "--root", str(root),
                                    "publish-maven-ci",
                                    "--dist", str(maven_dir),
                                    "--version", ver,
                                    "--poll-interval", "0",
                                    "--poll-timeout", "5",
                                ]
                            )
            self.assertEqual(rc, 0)
            self.assertEqual(len(seen_passphrase_during_sign_or_curl), 16)
            self.assertFalse(any(seen_passphrase_during_sign_or_curl))
            self.assertTrue(all(inp == "ci-gpg-secret" for inp in sign_inputs))
            self.assertIn(
                f"Completed Maven Central deployment for synurang-{ver} (deploymentId=deploy-ci-1, state=PUBLISHED)",
                ci_stdout.getvalue(),
            )

            # 3) publish_maven_local never writes a passphrase file to disk when MAVEN_GPG_PASSPHRASE is set
            settings_path = root / ".maven-settings.xml"
            settings_path.write_text(
                "<settings><servers><server><id>central</id><username>lu</username><password>lp</password></server></servers></settings>",
                encoding="utf-8",
            )
            local_sign_cmds: list[tuple[list[str], str | None]] = []

            def fake_local_run(cmd: list[str], input=None, **_kwargs) -> subprocess.CompletedProcess:
                if cmd[0] == "gpg" and "--detach-sign" in cmd:
                    local_sign_cmds.append((cmd, input))
                    Path(cmd[cmd.index("--output") + 1]).write_text("sig", encoding="utf-8")
                if cmd[0] == "curl" and any("/upload" in c for c in cmd):
                    return subprocess.CompletedProcess(cmd, 0, stdout="deploy-loc-1\n201\n", stderr="")
                if cmd[0] == "curl" and any("/status" in c for c in cmd):
                    return subprocess.CompletedProcess(
                        cmd,
                        0,
                        stdout=json.dumps({"deploymentId": "deploy-loc-1", "deploymentState": "PUBLISHED"}) + "\n200\n",
                        stderr="",
                    )
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            with mock.patch.dict(os.environ, {"MAVEN_GPG_PASSPHRASE": "local-secret"}, clear=True):
                with mock.patch("release.shutil.which", return_value="/usr/bin/tool"):
                    with mock.patch("release._write_secret_file", side_effect=AssertionError("passphrase file must not be written")):
                        with mock.patch("release.subprocess.run", side_effect=fake_local_run):
                            release.publish_maven_local(
                                dist_dir=maven_dir,
                                version=ver,
                                settings_path=settings_path,
                                poll_interval=0.0,
                                poll_timeout=5.0,
                                root=root,
                            )
            self.assertEqual(len(local_sign_cmds), 16)
            self.assertTrue(all("--passphrase-fd" in c and "--passphrase-file" not in c and inp == "local-secret" for c, inp in local_sign_cmds))

            # 4) publish_maven_local --dist without --version validates full repo parity via check_versions(root)
            readme = root / "README.md"
            orig_readme = readme.read_text(encoding="utf-8")
            readme.write_text(orig_readme.replace(f"synurang-desktop:{ver}", "synurang-desktop:0.0.1"), encoding="utf-8")
            with self.assertRaisesRegex(release.ReleaseError, "Version mismatch"):
                release.publish_maven_local(dist_dir=maven_dir, dry_run=True, root=root)
            readme.write_text(orig_readme, encoding="utf-8")

            # 5) Non-interactive GPG failure includes GPG_TTY and MAVEN_GPG_PASSPHRASE hints
            sample_pom = root / "sample.pom"
            sample_pom.write_text("<project/>", encoding="utf-8")
            with mock.patch("release.subprocess.run", return_value=subprocess.CompletedProcess(["gpg"], 2)):
                with self.assertRaisesRegex(release.ReleaseError, r"GPG_TTY=\$\(tty\).*MAVEN_GPG_PASSPHRASE"):
                    release._gpg_sign_file_local(sample_pom)

            # 6) _download_maven_from_github_release uses GH_HOST consistently and passes --clobber
            rel_assets = root / "gh-assets"
            rel_assets.mkdir()
            for p in maven_dir.iterdir():
                shutil.copy2(p, rel_assets / p.name)
            (rel_assets / "SHA256SUMS").write_text(
                release.checksum_text(sorted(rel_assets.iterdir(), key=lambda p: p.name)),
                encoding="utf-8",
            )
            gh_meta = [
                {
                    "id": 2000 + i,
                    "name": p.name,
                    "size": p.stat().st_size,
                    "state": "uploaded",
                    "digest": "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest(),
                }
                for i, p in enumerate(sorted(rel_assets.iterdir(), key=lambda p: p.name))
            ]
            gh_cmds: list[list[str]] = []

            def fake_host_gh(cmd: list[str], **_kwargs) -> subprocess.CompletedProcess:
                gh_cmds.append(cmd)
                if cmd[:2] == ["gh", "api"]:
                    path = next(c for c in cmd if c.startswith("repos/"))
                    if "releases?per_page=100" in path:
                        return subprocess.CompletedProcess(
                            cmd, 0, stdout=json.dumps([[{"id": 88, "tag_name": f"v{ver}", "draft": False, "prerelease": False}]]), stderr=""
                        )
                    if "/assets?per_page=100" in path:
                        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps([gh_meta]), stderr="")
                if cmd[:3] == ["gh", "release", "download"]:
                    dst = Path(cmd[cmd.index("--dir") + 1])
                    for i, tok in enumerate(cmd):
                        if tok == "-p":
                            name = cmd[i + 1]
                            shutil.copy2(rel_assets / name, dst / name)
                    return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
                raise AssertionError(f"Unexpected cmd: {cmd}")

            with mock.patch.dict(os.environ, {"GH_HOST": "ghe.example.com"}, clear=True):
                with mock.patch("release.shutil.which", return_value="/usr/bin/gh"):
                    with mock.patch("release.subprocess.run", side_effect=fake_host_gh):
                        release._download_maven_from_github_release(
                            tag=f"v{ver}",
                            version=ver,
                            repo="ivere27/synurang",
                            download_dir=root / "host-dl",
                            root=root,
                        )
            api_cmds = [c for c in gh_cmds if c[:2] == ["gh", "api"]]
            dl_cmd = next(c for c in gh_cmds if c[:3] == ["gh", "release", "download"])
            self.assertTrue(all(c[c.index("--hostname") + 1] == "ghe.example.com" for c in api_cmds))
            self.assertEqual(dl_cmd[dl_cmd.index("--repo") + 1], "ghe.example.com/ivere27/synurang")
            self.assertIn("--clobber", dl_cmd)

    def test_publish_maven_local_tag_e2e_env_override_and_gpg_key_fallback(self) -> None:
        if not shutil.which("gpg") or not shutil.which("curl"):
            self.skipTest("gpg or curl not installed")

        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, True)
        root = Path(tmp)
        _copy_versioned_files(root)
        ver = release.canonical_version(root)
        maven_dir = root / "maven"
        _create_fake_maven_dist(maven_dir, ver)

        rel_assets_dir = root / "gh-assets"
        rel_assets_dir.mkdir()
        for p in maven_dir.iterdir():
            shutil.copy2(p, rel_assets_dir / p.name)
        (rel_assets_dir / "SHA256SUMS").write_text(
            release.checksum_text(sorted(rel_assets_dir.iterdir(), key=lambda p: p.name)),
            encoding="utf-8",
        )
        gh_meta = [
            {
                "id": 3000 + idx,
                "name": p.name,
                "size": p.stat().st_size,
                "state": "uploaded",
                "digest": "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest(),
            }
            for idx, p in enumerate(sorted(rel_assets_dir.iterdir(), key=lambda p: p.name))
        ]

        # Present .maven-settings.xml should be overridden by SONATYPE_USERNAME/SONATYPE_PASSWORD
        settings_path = root / ".maven-settings.xml"
        settings_path.write_text(
            "<settings><servers><server><id>central</id><username>xml-user</username><password>xml-pass</password></server></servers></settings>",
            encoding="utf-8",
        )

        # Generate two keys so MAVEN_GPG_KEY selects the passphrase-protected key specifically
        gnupghome = root / "e2e-gnupg"
        gnupghome.mkdir(mode=0o700)
        self.addCleanup(release._kill_gpg_agent, gnupghome)
        pw_file = root / "e2e-pw"
        pw_file.write_text("e2e-pass-!@#", encoding="utf-8")
        os.chmod(pw_file, 0o600)
        gpg_env = {**os.environ, "GNUPGHOME": str(gnupghome)}
        try:
            subprocess.run(
                [
                    "gpg", "--homedir", str(gnupghome), "--batch", "--yes",
                    "--pinentry-mode", "loopback", "--passphrase", "",
                    "--quick-generate-key", "Other Key <other@example.com>", "ed25519", "sign", "1y",
                ],
                env=gpg_env,
                check=True,
                capture_output=True,
            )
            subprocess.run(
                [
                    "gpg", "--homedir", str(gnupghome), "--batch", "--yes",
                    "--pinentry-mode", "loopback", "--passphrase-file", str(pw_file),
                    "--quick-generate-key", "Selected Key <selected@example.com>", "ed25519", "sign", "1y",
                ],
                env=gpg_env,
                check=True,
                capture_output=True,
            )
            listed = subprocess.run(
                ["gpg", "--homedir", str(gnupghome), "--batch", "--with-colons", "--list-secret-keys", "selected@example.com"],
                env=gpg_env,
                check=True,
                capture_output=True,
                text=True,
            )
            selected_fpr = next(line.split(":")[9] for line in listed.stdout.splitlines() if line.startswith("fpr:"))
        except subprocess.CalledProcessError as err:
            self.skipTest(f"Local gpg key generation unsupported: {err}")

        expected_env_bearer = "Bearer " + base64.b64encode(b"env-override-user:env-override-token").decode("ascii")
        captured: dict[str, object] = {"auth": "", "entries": [], "sig_sample": b"", "pom_sample": b""}

        class TagE2EHandler(BaseHTTPRequestHandler):
            def log_message(self, format: str, *args: object) -> None:
                return

            def do_POST(self) -> None:
                auth = self.headers.get("Authorization")
                if auth != expected_env_bearer:
                    self.send_response(401)
                    self.end_headers()
                    return
                captured["auth"] = auth
                parsed = urllib_parse.urlsplit(self.path)
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                if parsed.path == "/api/v1/publisher/upload":
                    boundary = self.headers.get("Content-Type", "").split("boundary=")[-1].encode("ascii")
                    pk_idx = body.find(b"PK\x03\x04")
                    end_idx = body.find(b"\r\n--" + boundary, pk_idx)
                    with zipfile.ZipFile(io.BytesIO(body[pk_idx:end_idx]), "r") as zf:
                        captured["entries"] = zf.namelist()
                        pom_name = f"io/github/ivere27/synurang-desktop/{ver}/synurang-desktop-{ver}.pom"
                        captured["pom_sample"] = zf.read(pom_name)
                        captured["sig_sample"] = zf.read(f"{pom_name}.asc")
                    self.send_response(201)
                    self.end_headers()
                    self.wfile.write(b"tag-e2e-deploy-77")
                elif parsed.path == "/api/v1/publisher/status":
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(json.dumps({"deploymentId": "tag-e2e-deploy-77", "deploymentState": "PUBLISHED"}).encode("utf-8"))
                else:
                    self.send_response(404)
                    self.end_headers()

        server = HTTPServer(("127.0.0.1", 0), TagE2EHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        real_subprocess_run = subprocess.run
        real_shutil_which = shutil.which

        def gh_mock_real_others_run(cmd: list[str], *args, **kwargs):
            if cmd and cmd[0] == "gh":
                if cmd[:2] == ["gh", "api"]:
                    path = next(c for c in cmd if c.startswith("repos/"))
                    if "releases?per_page=100" in path:
                        return subprocess.CompletedProcess(
                            cmd, 0, stdout=json.dumps([[{"id": 99, "tag_name": f"v{ver}", "draft": False, "prerelease": False}]]), stderr=""
                        )
                    if "/assets?per_page=100" in path:
                        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps([gh_meta]), stderr="")
                if cmd[:3] == ["gh", "release", "download"]:
                    dst_dir = Path(cmd[cmd.index("--dir") + 1])
                    for i, tok in enumerate(cmd):
                        if tok == "-p":
                            name = cmd[i + 1]
                            shutil.copy2(rel_assets_dir / name, dst_dir / name)
                    return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
                raise AssertionError(f"Unexpected gh command: {cmd}")
            return real_subprocess_run(cmd, *args, **kwargs)

        try:
            port = server.server_address[1]
            env_vals = {
                "GNUPGHOME": str(gnupghome),
                "MAVEN_GPG_KEY": selected_fpr,
                "MAVEN_GPG_PASSPHRASE": "e2e-pass-!@#",
                "SONATYPE_USERNAME": "env-override-user",
                "SONATYPE_PASSWORD": "env-override-token",
                "PATH": os.environ.get("PATH", ""),
            }
            with mock.patch.dict(os.environ, env_vals, clear=True):
                with mock.patch("release.shutil.which", side_effect=lambda t: "/usr/bin/gh" if t == "gh" else real_shutil_which(t)):
                    with mock.patch("release.subprocess.run", side_effect=gh_mock_real_others_run):
                        res = release.publish_maven_local(
                            tag=f"v{ver}",
                            repo="ivere27/synurang",
                            upload_url=f"http://127.0.0.1:{port}/api/v1/publisher/upload",
                            poll_interval=0.0,
                            poll_timeout=5.0,
                            root=root,
                        )
            self.assertEqual(res, {"bundle": f"synurang-{ver}", "deployment_id": "tag-e2e-deploy-77", "state": "PUBLISHED"})
            self.assertEqual(captured["auth"], expected_env_bearer)
            self.assertEqual(len(captured["entries"]), 64)
            self.assertEqual(sum(1 for e in captured["entries"] if e.endswith(".asc")), 16)

            # Verify uploaded signature validates against the selected key
            verify_pom = root / "verify.pom"
            verify_asc = root / "verify.pom.asc"
            verify_pom.write_bytes(captured["pom_sample"])
            verify_asc.write_bytes(captured["sig_sample"])
            verify_proc = real_subprocess_run(
                ["gpg", "--homedir", str(gnupghome), "--status-fd", "1", "--verify", str(verify_asc), str(verify_pom)],
                env=gpg_env,
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertIn(f"VALIDSIG {selected_fpr}", verify_proc.stdout)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
