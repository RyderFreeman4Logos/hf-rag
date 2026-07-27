from __future__ import annotations

import os
import subprocess
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "install-with-mise.sh"


def _executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def test_mise_installer_uses_local_checkout_and_persists_a_shim(tmp_path: Path) -> None:
    home = tmp_path / "home"
    fake_bin = tmp_path / "bin"
    tool_bin = home / ".local" / "bin"
    data_home = tmp_path / "data"
    fake_bin.mkdir()

    _executable(
        fake_bin / "mise",
        "#!/bin/sh\n"
        "set -eu\n"
        "[ \"$1\" = reshim ]\n",
    )
    _executable(
        fake_bin / "uv",
        "#!/bin/sh\n"
        "set -eu\n"
        "printf '%s\\n' \"$*\" > \"$UV_CAPTURE\"\n"
        "mkdir -p \"$UV_TOOL_BIN_DIR\"\n"
        "printf '%s\\n' '#!/bin/sh' 'printf %s\\\\n ragctl-smoke' > \"$UV_TOOL_BIN_DIR/ragctl\"\n"
        "chmod 755 \"$UV_TOOL_BIN_DIR/ragctl\"\n",
    )
    capture = tmp_path / "uv-args"
    environment = {
        **os.environ,
        "HOME": str(home),
        "XDG_DATA_HOME": str(data_home),
        "UV_TOOL_BIN_DIR": str(tool_bin),
        "UV_CAPTURE": str(capture),
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
    }
    environment.pop("MISE_DATA_DIR", None)

    result = subprocess.run(
        ["sh", str(SCRIPT)], text=True, capture_output=True, env=environment, check=False
    )

    assert result.returncode == 0, result.stderr
    assert capture.read_text(encoding="utf-8").strip() == f"tool install --from {REPO} --force ragctl"
    shim = data_home / "mise" / "shims" / "ragctl"
    assert shim.is_file()
    assert subprocess.run([str(shim)], text=True, capture_output=True, check=True).stdout == "ragctl-smoke\n"
