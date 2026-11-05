from datetime import datetime, timezone
import hashlib
import json
import os
from paths import ROOT
import shlex
import subprocess
import uuid

BUNDLE = ROOT / "tablet"
TARGET = "/sdcard/Books/Philosophy of Love"
STAGE = "/sdcard/Books/.philosophy-of-love-upload-" + uuid.uuid4().hex[:10]
SSH_HOST = os.environ.get("XIAOMI_SSH_HOST", "xiaomi-tail")
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", SSH_HOST]
files = sorted(path for path in BUNDLE.rglob("*") if path.is_file())
assert len(files) == 11
manifest_hash = hashlib.sha256((BUNDLE / "SHA256SUMS").read_bytes()).hexdigest()


def sftp_quote(value):
    assert "\n" not in value and "\r" not in value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


journal = {
    "target": TARGET,
    "stage": STAGE,
    "files": len(files),
    "sha256sums_sha256": manifest_hash,
    "status": "prepared",
}
(ROOT / "transfer.json").write_text(json.dumps(journal, indent=2) + "\n")
subprocess.run(
    [*SSH, f"test ! -e {shlex.quote(TARGET)} && test ! -e {shlex.quote(STAGE)}"],
    check=True,
    timeout=20,
)
batch = [f"mkdir {sftp_quote(STAGE)}", f"mkdir {sftp_quote(STAGE + '/ebooks')}"]
for path in files:
    remote = STAGE + "/" + path.relative_to(BUNDLE).as_posix()
    batch.append(f"put {sftp_quote(str(path))} {sftp_quote(remote)}")
(ROOT / "sftp.batch").write_text("\n".join(batch) + "\n")
subprocess.run(
    [
        "sftp",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        "-b",
        str(ROOT / "sftp.batch"),
        SSH_HOST,
    ],
    check=True,
    timeout=120,
)
journal["status"] = "uploaded"
(ROOT / "transfer.json").write_text(json.dumps(journal, indent=2) + "\n")
remote = f"""set -eu
cd {shlex.quote(STAGE)}
printf '%s\n' '{manifest_hash}  SHA256SUMS' | sha256sum -c -
sha256sum -c SHA256SUMS
sync
cd /sdcard/Books
test ! -e {shlex.quote(TARGET)}
mv -T -n {shlex.quote(STAGE)} {shlex.quote(TARGET)}
test ! -e {shlex.quote(STAGE)}
sync
cd {shlex.quote(TARGET)}
sha256sum -c SHA256SUMS
printf 'COLLECTION_INSTALLED_AND_VERIFIED\n'
"""
result = subprocess.run(
    [*SSH, remote],
    check=True,
    timeout=60,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
)
print(result.stdout, flush=True)
assert "COLLECTION_INSTALLED_AND_VERIFIED" in result.stdout
journal.update(
    status="verified",
    completed_at=datetime.now(timezone.utc).isoformat(),
    remote_verification=result.stdout,
)
(ROOT / "transfer.json").write_text(json.dumps(journal, indent=2) + "\n")
