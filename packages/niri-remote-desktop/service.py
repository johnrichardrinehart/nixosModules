#!@python@
"""Expose Niri pointer motion through GNOME's private RemoteDesktop API."""

# dbus-next requires D-Bus signatures as string annotations.
# ruff: noqa: F722, F821

from __future__ import annotations

import asyncio
import json
import math
import subprocess
import uuid
from dataclasses import dataclass

from dbus_next import Message, MessageType, PropertyAccess, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, dbus_property, method, signal

BUS_NAME = "org.gnome.Mutter.RemoteDesktop"
ROOT_PATH = "/org/gnome/Mutter/RemoteDesktop"
SCREENCAST_NAME = "org.gnome.Mutter.ScreenCast"
PROPERTIES = "org.freedesktop.DBus.Properties"
SCREENCAST_STREAM = "org.gnome.Mutter.ScreenCast.Stream"
POINTER = 2


@dataclass(frozen=True)
class Bounds:
    x: int
    y: int
    width: int
    height: int


def desktop_bounds() -> Bounds:
    completed = subprocess.run(
        ["@niri@", "msg", "--json", "outputs"],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )
    outputs = json.loads(completed.stdout)
    logical = [item.get("logical") for item in outputs.values()]
    active = [item for item in logical if item is not None]
    if not active:
        raise RuntimeError("Niri returned no active logical outputs")
    left = min(int(item["x"]) for item in active)
    top = min(int(item["y"]) for item in active)
    right = max(int(item["x"]) + int(item["width"]) for item in active)
    bottom = max(int(item["y"]) + int(item["height"]) for item in active)
    if right <= left or bottom <= top:
        raise RuntimeError("Niri returned invalid logical output geometry")
    return Bounds(left, top, right - left, bottom - top)


class RemoteSession(ServiceInterface):
    def __init__(self, bus: MessageBus, path: str) -> None:
        super().__init__("org.gnome.Mutter.RemoteDesktop.Session")
        self.bus = bus
        self.path = path
        self.identifier = uuid.uuid4().hex
        self.helper: asyncio.subprocess.Process | None = None
        self.bounds: Bounds | None = None
        self.streams: dict[str, Bounds] = {}
        self.stopped = False

    @dbus_property(access=PropertyAccess.READ, name="SessionId")
    def session_id(self) -> "s":
        return self.identifier

    @method(name="Start")
    async def start(self):
        if self.stopped or self.helper is not None:
            return
        self.bounds = await asyncio.to_thread(desktop_bounds)
        self.helper = await asyncio.create_subprocess_exec(
            "@helper@",
            stdin=asyncio.subprocess.PIPE,
        )

    @method(name="Stop")
    async def stop(self):
        await self.close()

    @method(name="NotifyPointerMotionAbsolute")
    async def notify_pointer_motion_absolute(self, stream: "s", x: "d", y: "d"):
        if self.stopped or self.helper is None or self.helper.stdin is None:
            return
        if not math.isfinite(x) or not math.isfinite(y):
            return
        geometry = self.streams.get(stream)
        if geometry is None:
            geometry = await self._stream_geometry(stream)
            self.streams[stream] = geometry
        bounds = self.bounds
        if (
            bounds is None
            or not 0 <= x < geometry.width
            or not 0 <= y < geometry.height
        ):
            return
        global_x = geometry.x + x
        global_y = geometry.y + y
        normalized_x = int(max(0, min(bounds.width - 1, global_x - bounds.x)))
        normalized_y = int(max(0, min(bounds.height - 1, global_y - bounds.y)))
        self.helper.stdin.write(
            f"A {normalized_x} {normalized_y} {bounds.width} {bounds.height}\n".encode()
        )
        await self.helper.stdin.drain()

    async def _stream_geometry(self, path: str) -> Bounds:
        reply = await self.bus.call(
            Message(
                destination=SCREENCAST_NAME,
                path=path,
                interface=PROPERTIES,
                member="Get",
                signature="ss",
                body=[SCREENCAST_STREAM, "Parameters"],
            )
        )
        if reply is None or reply.message_type is MessageType.ERROR or not reply.body:
            raise RuntimeError("cannot read authorized screencast stream geometry")
        parameters = reply.body[0]
        if isinstance(parameters, Variant):
            parameters = parameters.value
        position = parameters["position"]
        size = parameters["size"]
        if isinstance(position, Variant):
            position = position.value
        if isinstance(size, Variant):
            size = size.value
        geometry = Bounds(
            int(position[0]), int(position[1]), int(size[0]), int(size[1])
        )
        if geometry.width <= 0 or geometry.height <= 0:
            raise RuntimeError("authorized stream has invalid geometry")
        return geometry

    @signal(name="Closed")
    def closed(self) -> "":
        return None

    async def close(self) -> None:
        if self.stopped:
            return
        self.stopped = True
        helper = self.helper
        self.helper = None
        if helper is not None:
            if helper.stdin is not None:
                helper.stdin.close()
            try:
                await asyncio.wait_for(helper.wait(), timeout=2)
            except TimeoutError:
                helper.terminate()
                await helper.wait()
        self.closed()
        self.bus.unexport(self.path)


class RemoteDesktop(ServiceInterface):
    def __init__(self, bus: MessageBus) -> None:
        super().__init__("org.gnome.Mutter.RemoteDesktop")
        self.bus = bus
        self.sequence = 0
        self.sessions: dict[str, RemoteSession] = {}

    @dbus_property(access=PropertyAccess.READ, name="SupportedDeviceTypes")
    def supported_device_types(self) -> "u":
        return POINTER

    @dbus_property(access=PropertyAccess.READ, name="Version")
    def version(self) -> "i":
        return 1

    @method(name="CreateSession")
    async def create_session(self) -> "o":
        self.sequence += 1
        path = f"{ROOT_PATH}/Session/u{self.sequence}"
        session = RemoteSession(self.bus, path)
        self.sessions[path] = session
        self.bus.export(path, session)
        return path


async def run() -> None:
    bus = await MessageBus().connect()
    root = RemoteDesktop(bus)
    bus.export(ROOT_PATH, root)
    await bus.request_name(BUS_NAME)
    await bus.wait_for_disconnect()


if __name__ == "__main__":
    asyncio.run(run())
