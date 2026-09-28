"""Exercise packaging with a fixture app and stubbed build/signing tools."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().with_name("package-release.sh")
TOOL = r'''
import json
import os
from pathlib import Path
import plistlib
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps([name] + args) + "\n")
if os.environ.get("MOCK_FAIL_TOOL") == name:
    sys.exit(1)
if os.environ.get("MOCK_FAIL_OPERATION") == " ".join([name] + args[:1]):
    sys.exit(1)
if name == "xcodebuild":
    derived = Path(args[args.index("-derivedDataPath") + 1])
    app = derived / "Build/Products/Release/CannyGit.app/Contents"
    (app / "MacOS").mkdir(parents=True, exist_ok=True)
    settings = dict(arg.split("=", 1) for arg in args if "=" in arg)
    version = os.environ.get("MOCK_APP_VERSION", settings.get("MARKETING_VERSION", "0.2.0"))
    build = os.environ.get("MOCK_BUILD_NUMBER", settings.get("CURRENT_PROJECT_VERSION", "2"))
    with (app / "Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleShortVersionString": version, "CFBundleVersion": build}, output)
    (app / "MacOS/CannyGit").write_bytes(b"fixture executable")
elif name == "xcrun" and args[:2] == ["stapler", "staple"]:
    target = Path(args[-1])
    if target.is_dir():
        (target / "Contents/staple.ticket").write_text("fixture ticket")
    else:
        target.write_bytes(target.read_bytes() + b"\nfixture ticket")
elif name == "vtool":
    arch = args[args.index("-arch") + 1] if "-arch" in args else "arm64"
    minos = os.environ.get(f"MOCK_MINOS_{arch.upper()}", os.environ.get("MOCK_MINOS", "14.0"))
    print(f" platform MACOS\n    minos {minos}\n   ntools 1")
elif name == "hdiutil":
    if args[0] == "create":
        staging = Path(args[args.index("-srcfolder") + 1])
        app = staging / "CannyGit.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        Path(os.environ["MOCK_DMG_MANIFEST"]).write_text(json.dumps({
            "files": sorted(item.name for item in staging.iterdir()),
            "applications": os.readlink(staging / "Applications"),
            "info": info,
            "app_stapled": (app / "Contents/staple.ticket").exists(),
        }))
        Path(args[-1]).write_bytes(b"fixture disk image")
    elif args[0] == "verify":
        assert Path(args[-1]).is_file()
'''


class PackageReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cannygit-package-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ["xcodebuild", "codesign", "lipo", "vtool", "xcrun", "hdiutil"]:
            tool = self.bin / name
            tool.write_text(f"#!{sys.executable}\n" + TOOL)
            tool.chmod(0o700)
        self.output = self.root / "Release Files"
        self.log = self.root / "commands.jsonl"
        self.environment = os.environ.copy()
        for key in ["RELEASE_VERSION", "BUILD_NUMBER", "DEVELOPER_ID_APPLICATION", "NOTARY_PROFILE"]:
            self.environment.pop(key, None)
        self.environment.update({
            "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "DERIVED_DATA_PATH": str(self.root / "Derived Data"),
            "OUTPUT_DIR": str(self.output),
            "MOCK_LOG": str(self.log),
            "MOCK_DMG_MANIFEST": str(self.root / "dmg-contents.json"),
        })

    def run_package(self, **environment):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT)], env=self.environment | environment,
            capture_output=True, text=True, timeout=30,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def check_archive(self, version, build):
        archive = self.output / f"CannyGit-{version}-macOS.zip"
        with zipfile.ZipFile(archive) as package:
            self.assertIsNone(package.testzip())
            info = plistlib.loads(package.read("CannyGit.app/Contents/Info.plist"))
            self.assertEqual(info["CFBundleShortVersionString"], version)
            self.assertEqual(info["CFBundleVersion"], build)
        digest, name = Path(str(archive) + ".sha256").read_text().split()
        self.assertEqual(name, archive.name)
        self.assertEqual(digest, hashlib.sha256(archive.read_bytes()).hexdigest())
        image = self.output / f"CannyGit-{version}-macOS.dmg"
        digest, name = Path(str(image) + ".sha256").read_text().split()
        self.assertEqual(name, image.name)
        self.assertEqual(digest, hashlib.sha256(image.read_bytes()).hexdigest())
        contents = json.loads((self.root / "dmg-contents.json").read_text())
        self.assertEqual(contents["files"], ["Applications", "CannyGit.app"])
        self.assertEqual(contents["applications"], "/Applications")
        self.assertEqual(contents["info"], info)
        creation = next(call for call in self.calls() if call[:2] == ["hdiutil", "create"])
        self.assertFalse(Path(creation[creation.index("-srcfolder") + 1]).exists())
        return archive

    def test_tag_version_and_build_number_reach_the_app_and_archive(self):
        result = self.run_package(RELEASE_VERSION="1.2.3", BUILD_NUMBER="42")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.check_archive("1.2.3", "42")
        build = self.calls()[0]
        self.assertIn("ARCHS=arm64 x86_64", build)
        self.assertIn("ONLY_ACTIVE_ARCH=NO", build)
        self.assertIn("MARKETING_VERSION=1.2.3", build)
        for architecture in ["arm64", "x86_64"]:
            self.assertTrue(any(call[0] == "lipo" and call[-2:] == ["-verify_arch", architecture] for call in self.calls()))
            self.assertTrue(any(call[0] == "vtool" and call[1:3] == ["-arch", architecture] for call in self.calls()))

    def test_non_macos14_deployment_target_does_not_produce_an_archive(self):
        for architecture in ["arm64", "x86_64"]:
            with self.subTest(architecture=architecture):
                result = self.run_package(**{f"MOCK_MINOS_{architecture.upper()}": "13.0"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("expected 14.0", result.stderr)
                self.assertFalse(self.output.exists())

    def test_local_packaging_keeps_the_project_version(self):
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.check_archive("0.2.0", "2")
        self.assertTrue(any(call[:4] == ["codesign", "--force", "--sign", "-"] for call in self.calls()))

    def test_invalid_versions_are_rejected_before_building(self):
        for version in ["v1.2.3", "1.2", "01.2.3", "1.2.3-rc.1", "../1.2.3", "$(touch unexpected)"]:
            with self.subTest(version=version):
                result = self.run_package(RELEASE_VERSION=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("RELEASE_VERSION", result.stderr)
                self.assertFalse(self.log.exists())

    def test_invalid_build_numbers_are_rejected_before_building(self):
        for build in ["0", "-1", "1.2", "01", "42; exit 0"]:
            with self.subTest(build=build):
                result = self.run_package(BUILD_NUMBER=build)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.log.exists())

    def test_version_mismatch_does_not_produce_an_archive(self):
        result = self.run_package(RELEASE_VERSION="1.2.3", MOCK_APP_VERSION="0.2.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match RELEASE_VERSION", result.stderr)
        self.assertFalse(self.output.exists())

    def test_build_number_mismatch_does_not_produce_an_archive(self):
        result = self.run_package(BUILD_NUMBER="42", MOCK_BUILD_NUMBER="2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match BUILD_NUMBER", result.stderr)
        self.assertFalse(self.output.exists())

    def test_build_failure_does_not_produce_an_archive(self):
        result = self.run_package(MOCK_FAIL_TOOL="xcodebuild")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_signature_failure_does_not_produce_an_archive(self):
        result = self.run_package(MOCK_FAIL_TOOL="codesign")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_missing_architecture_does_not_produce_an_archive(self):
        result = self.run_package(MOCK_FAIL_TOOL="lipo")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_image_creation_failure_prevents_checksums(self):
        result = self.run_package(MOCK_FAIL_OPERATION="hdiutil create")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.output.glob("*.sha256")), [])
        creation = next(call for call in self.calls() if call[:2] == ["hdiutil", "create"])
        self.assertFalse(Path(creation[creation.index("-srcfolder") + 1]).exists())

    def test_image_verification_failure_prevents_checksums(self):
        result = self.run_package(MOCK_FAIL_OPERATION="hdiutil verify")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.output.glob("*.sha256")), [])

    def test_dmg_tool_rejects_a_missing_app(self):
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT.with_name("create-dmg.sh")), str(self.root / "missing.app"), str(self.root / "output.dmg")],
            env=self.environment, capture_output=True, text=True, timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_notarization_requires_a_signing_identity(self):
        result = self.run_package(NOTARY_PROFILE="fixture-profile")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_notarized_archive_is_rebuilt_after_stapling(self):
        result = self.run_package(DEVELOPER_ID_APPLICATION="fixture identity", NOTARY_PROFILE="fixture-profile")
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.check_archive("0.2.0", "2")
        with zipfile.ZipFile(archive) as package:
            self.assertIn("CannyGit.app/Contents/staple.ticket", package.namelist())
        calls = self.calls()
        self.assertTrue(any("--timestamp" in call for call in calls))
        self.assertTrue(any(call[:3] == ["xcrun", "notarytool", "submit"] for call in calls))
        self.assertTrue(any(call[:3] == ["xcrun", "stapler", "validate"] for call in calls))
        contents = json.loads((self.root / "dmg-contents.json").read_text())
        self.assertTrue(contents["app_stapled"])
        image = str(self.output / "CannyGit-0.2.0-macOS.dmg")
        self.assertTrue(any(call[0] == "codesign" and "--sign" in call and call[-1] == image for call in calls))
        self.assertTrue(any(call[:4] == ["xcrun", "notarytool", "submit", image] for call in calls))
        self.assertTrue(any(call == ["xcrun", "stapler", "validate", image] for call in calls))


if __name__ == "__main__":
    unittest.main()
