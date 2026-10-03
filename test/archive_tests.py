"""Portable archives contain load sources, without local credentials/build output."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("plainwire_archive", Path(__file__).resolve().parents[1] / "scripts/archive.py")
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


class SourceArchiveTests(unittest.TestCase):
    def test_required_tools_without_local_credentials_or_builds(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            files = ["tools/load/pw_load_sim.erl", "tools/load/gleam/src/main.gleam",
                     "tools/load/gleam/manifest.toml", "tools/load/live.sessions.jsonl",
                     "tools/load/local-load-result.json", "tools/load/gleam/build/generated.erl",
                     "sdk/rust/target/generated.json", "sdk/rust/Cargo.lock", ".env", "deploy/vm.args"]
            for name in files:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture")
            with patch.object(archive, "ROOT", root):
                included = {path.relative_to(root).as_posix() for path in archive.source_files() if path.is_file()}
            self.assertEqual(included, {"tools/load/pw_load_sim.erl", "tools/load/gleam/src/main.gleam",
                                       "tools/load/gleam/manifest.toml", "sdk/rust/Cargo.lock", "deploy/vm.args"})


if __name__ == "__main__":
    unittest.main()
