import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "zipkesh"))
import engine

SEVENZIP = os.environ.get("ZIPKESH_7ZZ") or shutil.which("7zz") or shutil.which("7z")


class PasswordTests(unittest.TestCase):
    def test_styles(self):
        for style, size in [("strong", 24), ("easy", 19), ("long", 48)]:
            values = {engine.generate_password(style) for _ in range(100)}
            self.assertEqual(len(values), 100)
            self.assertTrue(all(len(value) == size for value in values))
            self.assertTrue(all("\n" not in value for value in values))
        for style in ("strong", "long"):
            value = engine.generate_password(style)
            self.assertTrue(any(c.islower() for c in value))
            self.assertTrue(any(c.isupper() for c in value))
            self.assertTrue(any(c.isdigit() for c in value))

    def test_unknown_style(self):
        with self.assertRaises(engine.ArchiveError):
            engine.generate_password("unknown")


class PathTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "x").write_text("secret")

    def tearDown(self):
        self.temporary.cleanup()

    def test_nested_sources_and_duplicates_are_collapsed(self):
        files, root, _ = engine.prepare_paths([str(self.source / "x"), str(self.source), str(self.source)],
                                              str(self.root / "out.zip"), "zip-aes")
        self.assertEqual(files, ["./source"])
        self.assertEqual(root, str(self.root))

    def test_cannot_archive_into_selected_folder(self):
        with self.assertRaisesRegex(engine.ArchiveError, "outside"):
            engine.prepare_paths([str(self.source)], str(self.source / "out.zip"), "zip-aes")

    def test_existing_file_or_symlink_is_never_overwritten(self):
        output = self.root / "out.zip"
        output.write_text("keep")
        for _ in range(2):
            with self.assertRaisesRegex(engine.ArchiveError, "exists"):
                engine.prepare_paths([str(self.source)], str(output), "zip-aes")
            self.assertEqual((self.root / "original").read_text() if output.is_symlink() else output.read_text(), "keep")
            if not output.is_symlink():
                output.rename(self.root / "original")
                output.symlink_to(self.root / "original")

    def test_reject_bad_inputs(self):
        cases = [([], "out.zip", "zip-aes"), ([str(self.root / "missing")], "out.zip", "zip-aes"),
                 ([str(self.source)], "out.7z", "zip-aes"), ([str(self.source)], "out.zip", "rar")]
        for paths, output, mode in cases:
            with self.subTest(mode=mode, paths=paths), self.assertRaises(engine.ArchiveError):
                engine.prepare_paths(paths, str(self.root / output), mode)

    def test_reject_bad_passwords_before_launching_anything(self):
        for password in ["", "short", "long-enough\n", "x" * 257, 123]:
            with self.subTest(password=password), self.assertRaises(engine.ArchiveError):
                engine.create_archive({"paths": [str(self.source)], "output": str(self.root / "out.zip"),
                                       "password": password}, "/does/not/exist")

    def test_commit_race_preserves_new_file(self):
        output = self.root / "out.zip"
        def fake_run(binary, args, *other, **kwargs):
            if args[0] == "a":
                Path(args[args.index("--") - 1]).write_bytes(b"archive")
            else:
                output.write_bytes(b"someone else's file")
        with mock.patch.object(engine, "_run_7zip", fake_run), self.assertRaisesRegex(engine.ArchiveError, "now exists"):
            engine.create_archive({"paths": [str(self.source)], "output": str(output),
                                   "password": "TestPassword123!"}, sys.executable)
        self.assertEqual(output.read_bytes(), b"someone else's file")
        self.assertFalse(list(self.root.glob(".zipkesh-*")))

    def test_failure_removes_partial_archive(self):
        def fake_run(binary, args, *other, **kwargs):
            Path(args[args.index("--") - 1]).write_bytes(b"partial")
            raise engine.ArchiveError("simulated read failure")
        with mock.patch.object(engine, "_run_7zip", fake_run), self.assertRaises(engine.ArchiveError):
            engine.create_archive({"paths": [str(self.source)], "output": str(self.root / "out.zip"),
                                   "password": "TestPassword123!"}, sys.executable)
        self.assertFalse((self.root / "out.zip").exists())
        self.assertFalse(list(self.root.glob(".zipkesh-*")))


@unittest.skipUnless(SEVENZIP, "Set ZIPKESH_7ZZ to the 7zz executable for integration tests")
class ArchiveIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.password = "Test!Correct-Horse-42"
        self.names = ["normal.txt", "فارسی.txt", "quote ' and spaces.txt", "-switch.txt", "@list.txt", "line\nbreak.txt"]
        if sys.platform != "darwin":
            # Finder does not allow these names, but 7-Zip wildcard parsing still matters.
            self.names.extend(["literal*.txt", "literal?.txt", "literal[1].txt"])
        for name in self.names:
            (self.source / name).write_text("private content: " + name)
        (self.source / ".hidden").write_text("hidden")
        (self.source / "empty").mkdir()
        (self.source / "link").symlink_to("normal.txt")

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, mode="zip-aes", paths=None, password=None):
        output = self.root / (mode + engine.FORMATS[mode][0])
        engine.create_archive({"paths": paths or [str(self.source)], "output": str(output), "format": mode,
                               "password": password or self.password}, SEVENZIP)
        return output

    def test_roundtrip_all_formats_and_wrong_password(self):
        for mode in engine.FORMATS:
            with self.subTest(mode=mode):
                archive = self.archive(mode)
                self.assertEqual(stat.S_IMODE(archive.stat().st_mode), 0o600)
                engine._run_7zip(SEVENZIP, ["t", str(archive)], self.password, str(self.root))
                with self.assertRaises(engine.ArchiveError):
                    engine._run_7zip(SEVENZIP, ["t", str(archive)], "wrong-password", str(self.root))
                extracted = self.root / ("extracted-" + mode)
                extracted.mkdir()
                engine._run_7zip(SEVENZIP, ["x", "-y", str(archive)], self.password, str(extracted))
                for name in self.names + [".hidden"]:
                    self.assertEqual((extracted / "source" / name).read_bytes(), (self.source / name).read_bytes())
                self.assertTrue((extracted / "source" / "empty").is_dir())
                self.assertTrue((extracted / "source" / "link").is_symlink())
                if mode.startswith("zip"):
                    with zipfile.ZipFile(archive) as data:
                        regular = data.getinfo("./source/normal.txt")
                        self.assertTrue(regular.flag_bits & 1)
                        self.assertEqual(regular.compress_type, 99 if mode == "zip-aes" else 0)
        self.assertFalse(list(self.root.glob(".zipkesh-*")))

    def test_individual_special_names_and_siblings(self):
        names = self.names + [".hidden"]
        paths = [str(self.source / name) for name in names]
        archive = self.archive(paths=paths)
        with zipfile.ZipFile(archive) as data:
            self.assertEqual({name.removeprefix("./") for name in data.namelist()}, set(names))

    def test_multiple_parent_directories(self):
        sibling = self.root / "sibling"
        sibling.mkdir()
        (sibling / "normal.txt").write_text("different")
        archive = self.archive(paths=[str(self.source / "normal.txt"), str(sibling / "normal.txt")])
        with zipfile.ZipFile(archive) as data:
            self.assertEqual({name.removeprefix("./") for name in data.namelist()}, {"source/normal.txt", "sibling/normal.txt"})

    def test_empty_folder_and_empty_file(self):
        empty = self.root / "empty-folder"
        empty.mkdir()
        (empty / "zero.txt").touch()
        for mode in engine.FORMATS:
            with self.subTest(mode=mode):
                self.archive(mode, [str(empty)])

    def test_completely_empty_folder(self):
        empty = self.root / "only-a-folder"
        empty.mkdir()
        for mode in engine.FORMATS:
            with self.subTest(mode=mode):
                self.archive(mode, [str(empty)])

    def test_7z_hides_filenames(self):
        archive = self.archive("7z")
        listing = subprocess.run([SEVENZIP, "l", str(archive)], input=b"", capture_output=True, timeout=10)
        self.assertNotEqual(listing.returncode, 0)
        self.assertNotIn(b"normal.txt", listing.stdout)

    def test_7z_unicode_password(self):
        archive = self.archive("7z", password="تست!Correct-Horse-42")
        engine._run_7zip(SEVENZIP, ["t", str(archive)], "تست!Correct-Horse-42", str(self.root))

    def test_zip_rejects_unicode_password_with_useful_message(self):
        with self.assertRaisesRegex(engine.ArchiveError, "ASCII"):
            self.archive(password="تست!Correct-Horse-42")

    def test_json_protocol_preserves_literal_password(self):
        secret = "  literal!$()`'\";@&<>:42  "
        output = self.root / "literal.zip"
        request = {"paths": [str(self.source)], "output": str(output), "password": secret}
        result = subprocess.run([sys.executable, str(ROOT / "zipkesh/engine.py"), "--sevenzip", SEVENZIP],
                                input=json.dumps(request).encode(), capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout.decode())
        self.assertEqual(json.loads(result.stdout), {"ok": True, "output": str(output)})
        self.assertEqual(result.stderr, b"")
        self.assertNotIn(secret.encode(), result.stdout)
        engine._run_7zip(SEVENZIP, ["t", str(output)], secret, str(self.root))


class WorkerProtocolTests(unittest.TestCase):
    def test_launcher_detaches_and_preserves_exact_arguments(self):
        import launch
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / "args.json"
            code = "import json,sys;json.dump(sys.argv[2:],open(sys.argv[1],'w'))"
            arguments = ["space ' $()", "فارسی", "line\nbreak", "-switch", "@list"]
            child = launch.launch([sys.executable, "-c", code, str(record), *arguments])
            try:
                self.assertEqual(os.getsid(child.pid), child.pid)
                self.assertEqual(child.wait(timeout=10), 0)
                self.assertEqual(json.loads(record.read_text()), arguments)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()

    def test_terminal_handoff_has_no_echo_or_secret_in_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / "fake7zz"
            record = root / "record.json"
            secret = "dummy-TestSecret-42!"
            fake.write_text("#!" + sys.executable + "\n"
                            "import os,sys,json,termios,time\n"
                            "echo=bool(termios.tcgetattr(0)[3]&termios.ECHO)\n"
                            "print('Enter pass',end='',flush=True)\ntime.sleep(.02)\n"
                            "print('word:',end='',flush=True)\npassword=input()\n"
                            "json.dump({'echo':echo,'argv':sys.argv,'env':dict(os.environ),'password':password},"
                            "open(" + repr(str(record)) + ",'w'))\n")
            fake.chmod(0o700)
            engine._run_7zip(str(fake), ["a", "-p", "out.zip"], secret, directory)
            data = json.loads(record.read_text())
            self.assertFalse(data["echo"])
            self.assertEqual(data["password"], secret)
            self.assertNotIn(secret, json.dumps(data["argv"]))
            self.assertNotIn(secret, json.dumps(data["env"]))

    def test_missing_password_prompt_refuses_output(self):
        with self.assertRaisesRegex(engine.ArchiveError, "without requesting"):
            engine._run_7zip("/usr/bin/true", [], "TestPassword123!", tempfile.gettempdir())

    def test_bad_json_returns_safe_json_error(self):
        result = subprocess.run([sys.executable, str(ROOT / "zipkesh/engine.py")], input=b"not json",
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertEqual(result.stderr, b"")

    def test_cancel_kills_child_and_removes_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "x"
            source.write_text("private")
            fake = root / "fake7zz"
            marker = root / "pid"
            fake.write_text("#!" + sys.executable + "\nimport os,time\n"
                            "open(" + repr(str(marker)) + ",'w').write(str(os.getpid()))\n"
                            "print('Enter password:',flush=True)\ninput()\ntime.sleep(60)\n")
            fake.chmod(0o700)
            task = subprocess.Popen([sys.executable, str(ROOT / "zipkesh/engine.py"), "--sevenzip", str(fake)],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            request = {"paths": [str(source)], "output": str(root / "out.zip"), "password": "TestPassword123!"}
            task.stdin.write(json.dumps(request).encode())
            task.stdin.close()
            try:
                deadline = time.monotonic() + 10
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(marker.exists())
                task.terminate()
                task.wait(timeout=10)
                self.assertEqual(task.returncode, 130)
                self.assertFalse(json.loads(task.stdout.read())["ok"])
                self.assertEqual(task.stderr.read(), b"")
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(marker.read_text()), 0)
                self.assertFalse(list(root.glob(".zipkesh-*")))
                self.assertFalse((root / "out.zip").exists())
            finally:
                if task.poll() is None:
                    task.kill()
                    task.wait()
                task.stdout.close()
                task.stderr.close()


class WorkflowTests(unittest.TestCase):
    def test_bundle_and_safe_shell_quoting(self):
        import plistlib
        import shlex
        spec = importlib.util.spec_from_file_location("workflow", ROOT / "scripts/make_workflow.py")
        workflow = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(workflow)
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "Zipkesh.workflow"
            launcher = Path(directory) / "space ' $(unsafe)" / "launch"
            workflow.build_workflow(bundle, launcher)
            with (bundle / "Contents/Info.plist").open("rb") as f:
                info = plistlib.load(f)
            self.assertEqual(info["NSServices"][0]["NSSendFileTypes"], ["public.item"])
            with (bundle / "Contents/document.wflow").open("rb") as f:
                document = plistlib.load(f)
            parameters = document["actions"][0]["action"]["ActionParameters"]
            self.assertEqual(shlex.split(parameters["COMMAND_STRING"]), ["exec", str(launcher), "$@"])
            self.assertEqual(parameters["inputMethod"], 1)


if __name__ == "__main__":
    unittest.main()
