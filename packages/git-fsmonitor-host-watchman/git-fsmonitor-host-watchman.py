"""git core.fsmonitor hook answered by a watchman running on this guest's host.

The worktrees under a 9p share are stat-bound: with cache=none every path
component is a round trip, so `git status` on a few thousand files is seconds.
Git's fsmonitor protocol lets a hook name the paths that changed since a token
and git then stats only those. inotify in the guest never sees the host's
writes, but a watchman on the host sees both sides - the guest's writes reach
the host filesystem as ordinary syscalls made by QEMU's 9p server - so the
hook asks that watchman, over a TCP bridge the launcher exposes on the slirp
gateway, after translating the worktree path through the shares manifest.

The same hook runs on the host itself, where there is no manifest: it then
asks the local watchman over its unix socket about the worktree as it is. The
two sides must share a worktree's index, and the token git stores in it is a
watchman clock; with both sides watching the same root of the same watchman,
whichever side wrote the index last leaves a token the other can resume
from. Any other fsmonitor on either side (git's builtin daemon, or none)
leaves a token the other side has to answer with "everything changed".

Protocol (git fsmonitor hook version 2): argv is `2 <token>`; stdout is the
new token, then each changed path relative to the worktree root, each
NUL-terminated; a single path of `/` means "everything may have changed".
Any failure exits non-zero, which git treats as a full rescan: the hook can
be slow or absent, never wrong.
"""

import json
import os
import socket
import subprocess
import sys

MANIFEST = os.environ.get("VM_SHARES_MANIFEST", "/run/vm-shares/manifest.json")
# host:port override for testing against an ad-hoc bridge.
ADDRESS = os.environ.get("VM_HOST_WATCHMAN")
# The watchman whose per-user service the launcher bridges to the guest. On
# the host the hook has to ask that same instance, or its clocks mean nothing
# to the guest; the package pins the launcher's build here.
WATCHMAN = os.environ.get("GIT_FSMONITOR_WATCHMAN", "@watchman@")
CONNECT_TIMEOUT = 1.0
# get-sockname may have to start the watchman service first.
GET_SOCKNAME_TIMEOUT = 5.0
# How long watchman may take to settle pending events before answering. Past
# this the query errors and git falls back to a full scan.
SYNC_TIMEOUT_MS = 2000
# Per-reply ceiling. A bridge that accepts and then says nothing - socat up,
# watchman wedged - has to cost less than the scan git does instead.
REPLY_TIMEOUT = 1.0 + SYNC_TIMEOUT_MS / 1000


def fail(message):
    sys.stderr.write(f"git-fsmonitor-host-watchman: {message}\n")
    sys.exit(1)


def load_manifest():
    try:
        with open(MANIFEST, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        fail(f"cannot read {MANIFEST}: {error}")


def bridge_address(manifest):
    if ADDRESS:
        host, _, port = ADDRESS.rpartition(":")
    else:
        bridge = manifest.get("watchman") or {}
        host, port = bridge.get("host"), bridge.get("port")
    if not host or not port:
        fail("no watchman bridge in manifest and VM_HOST_WATCHMAN unset")
    try:
        return host, int(port)
    except ValueError:
        fail(f"bad watchman port {port!r}")


def host_path(manifest, guest_dir):
    """Translate a guest path to the host path the same directory has there."""
    best = None
    for share in manifest.get("shares", []):
        guest_root = share.get("guest", "").rstrip("/")
        if not guest_root:
            continue
        if guest_dir == guest_root or guest_dir.startswith(guest_root + "/"):
            if best is None or len(guest_root) > len(best[0]):
                best = (guest_root, share["host"].rstrip("/"))
    if best is None:
        fail(f"{guest_dir} is not under an exported share")
    guest_root, host_root = best
    return host_root + guest_dir[len(guest_root) :]


def local_socket():
    """The unix socket of the watchman service running on this machine."""
    sock = os.environ.get("WATCHMAN_SOCK")
    if sock:
        return sock
    # get-sockname starts the per-user service when it is not running, in the
    # place that service's other clients - the launcher's bridge - expect it.
    try:
        result = subprocess.run(
            [WATCHMAN, "--output-encoding=json", "--no-pretty", "get-sockname"],
            capture_output=True,
            check=True,
            timeout=GET_SOCKNAME_TIMEOUT,
        )
        sock = json.loads(result.stdout).get("sockname")
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        fail(f"cannot locate the local watchman through {WATCHMAN}: {error}")
    if not sock:
        fail(f"{WATCHMAN} get-sockname named no socket")
    return sock


class Watchman:
    def __init__(self, address):
        # A (host, port) pair is the launcher's bridge; a string is the local
        # service's unix socket. Both speak the same JSON-per-line protocol.
        if isinstance(address, str):
            self.address = address
            family, target = socket.AF_UNIX, address
        else:
            self.address = f"{address[0]}:{address[1]}"
            family, target = None, address
        try:
            if family is None:
                self.sock = socket.create_connection(target, timeout=CONNECT_TIMEOUT)
            else:
                self.sock = socket.socket(family, socket.SOCK_STREAM)
                self.sock.settimeout(CONNECT_TIMEOUT)
                self.sock.connect(target)
        except OSError as error:
            fail(f"cannot reach watchman at {self.address}: {error}")
        self.sock.settimeout(REPLY_TIMEOUT)
        self.reader = self.sock.makefile("rb")

    def call(self, request):
        # Watchman takes one JSON PDU per line on its socket and answers in the
        # encoding it was asked in; the CLI's BSER default is not required.
        try:
            self.sock.sendall(json.dumps(request).encode() + b"\n")
            line = self.reader.readline()
        except TimeoutError:
            fail(
                f"watchman at {self.address} did not answer {request[0]} within {REPLY_TIMEOUT:g}s"
            )
        except OSError as error:
            fail(f"watchman at {self.address}: {error}")
        if not line:
            fail("watchman closed the connection")
        try:
            response = json.loads(line)
        except ValueError:
            fail("watchman sent something other than JSON")
        if "error" in response:
            fail(f"watchman: {response['error']}")
        return response


def emit(token, paths):
    out = sys.stdout.buffer
    out.write(token.encode() + b"\0")
    for path in paths:
        out.write(path.encode("utf-8", "surrogateescape") + b"\0")
    out.flush()


def main(argv):
    if len(argv) != 3 or argv[1] != "2":
        fail("expected fsmonitor hook protocol version 2")
    token = argv[2]

    # Git runs the hook from the worktree root.
    cwd = os.getcwd().rstrip("/")
    if os.path.exists(MANIFEST):
        # In the guest: the worktree is a share, and watchman is the host's,
        # reached through the launcher's bridge.
        manifest = load_manifest()
        worktree = host_path(manifest, cwd)
        watchman = Watchman(bridge_address(manifest))
    else:
        # On the host: the worktree is where git says it is.
        worktree = cwd
        watchman = Watchman(local_socket())
    # watch-project reuses an enclosing watch when one exists and otherwise
    # creates one at the nearest project root, which for a worktree is the
    # directory holding its .git file: one small watch per worktree, crawled
    # once on first use.
    project = watchman.call(["watch-project", worktree])
    root = project["watch"]
    relative_root = project.get("relative_path")

    if not token.startswith("c:"):
        # First query for this index, or a token from another fsmonitor: git
        # has no baseline, so everything may have changed. Hand back a clock to
        # anchor the next query.
        emit(watchman.call(["clock", root])["clock"], ["/"])
        return

    query = {
        "since": token,
        "fields": ["name"],
        "dedup_results": True,
        "sync_timeout": SYNC_TIMEOUT_MS,
        "expression": [
            "allof",
            # Files and symlinks only. Watchman also reports a directory
            # whenever an entry is added or removed inside it, and git reads a
            # reported path that is not an index entry as a directory event,
            # invalidating every entry beneath it: one new file in src/ would
            # cost a re-stat of all of src/. Git needs none of that from here.
            # A moved or removed directory arrives as each of its former
            # children, still typed as they were, and the untracked cache for
            # a reported path's parent is dropped by git on its own.
            ["anyof", ["type", "f"], ["type", "l"]],
            # A path created after the token and gone again before now never
            # existed as far as this index is concerned.
            ["not", ["allof", ["since", token, "cclock"], ["not", "exists"]]],
        ],
    }
    if relative_root:
        query["relative_root"] = relative_root
    result = watchman.call(["query", root, query])
    clock = result["clock"]
    if result.get("is_fresh_instance"):
        # The watch was (re)created since the token was issued; its history
        # does not reach back that far.
        emit(clock, ["/"])
        return
    paths = [
        name
        for name in result.get("files", [])
        if name != ".git" and not name.startswith(".git/")
    ]
    emit(clock, paths)


if __name__ == "__main__":
    main(sys.argv)
