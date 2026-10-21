# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

import argparse
import hashlib
import json
import os
import shutil
import stat
import struct
import subprocess
from pathlib import Path

IMAGE_SHA256 = "800d77f0672b5d1906523bd3fb905aed6b5f2161b9c5f7d1955c5805bb4b8dad"
IMAGE_BYTES = 13_987_753_984
DISK_BYTES = 500_107_862_016
NVME_SERIAL = "S4EVNM0TA19050K"
ESP_START = 16_384
ESP_SECTORS = 524_288
ROOT_START = 540_672
ROOT_SECTORS = 26_779_160
SECTOR = 512
CHUNK = 4 * 1024 * 1024


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def verify_image(image: Path) -> None:
    if not image.is_file() or image.stat().st_size != IMAGE_BYTES:
        raise ValueError("approved raw image size does not match")
    digest = hashlib.sha256()
    with image.open("rb") as stream:
        while chunk := stream.read(CHUNK):
            digest.update(chunk)
    if digest.hexdigest() != IMAGE_SHA256:
        raise ValueError("approved raw image SHA-256 does not match")
    with image.open("rb") as stream:
        mbr = stream.read(SECTOR)
    if mbr[510:512] != b"\x55\xaa":
        raise ValueError("image has no MBR signature")
    for number, expected in enumerate(
        ((0x0B, ESP_START, ESP_SECTORS), (0x83, ROOT_START, ROOT_SECTORS))
    ):
        entry = mbr[446 + number * 16 : 462 + number * 16]
        actual = (entry[4], *struct.unpack_from("<II", entry, 8))
        if actual != expected:
            raise ValueError(f"approved image partition {number + 1} does not match")


def verify_device(device: Path) -> Path:
    target = device.resolve(strict=True)
    if (
        not stat.S_ISBLK(target.stat().st_mode)
        or run("lsblk", "-dn", "-o", "TYPE", str(target)) != "disk"
    ):
        raise ValueError("target is not a whole block device")
    properties = dict(
        line.split("=", 1)
        for line in run(
            "udevadm", "info", "--query=property", f"--name={target}"
        ).splitlines()
        if "=" in line
    )
    expected = {
        "ID_BUS": "usb",
        "ID_VENDOR_ID": "1d6b",
        "ID_MODEL_ID": "0105",
        "ID_SERIAL_SHORT": NVME_SERIAL,
    }
    if any(properties.get(key) != value for key, value in expected.items()):
        raise ValueError("USB recovery gadget identity does not match")
    if int(run("blockdev", "--getsize64", str(target))) != DISK_BYTES:
        raise ValueError("exported NVMe capacity does not match")
    mounts = json.loads(run("lsblk", "-J", "-o", "MOUNTPOINTS", str(target)))
    if any(
        mount
        for block in mounts["blockdevices"]
        for node in (block, *block.get("children", []))
        for mount in node.get("mountpoints", [])
    ):
        raise ValueError("target disk or partition is mounted")
    return target


def copy_and_verify(image: Path, partition: Path, offset: int, length: int) -> None:
    digest = hashlib.sha256()
    source_fd = os.open(image, os.O_RDONLY)
    target_fd = os.open(partition, os.O_WRONLY | os.O_SYNC)
    try:
        written = 0
        while written < length:
            data = os.pread(source_fd, min(CHUNK, length - written), offset + written)
            if not data:
                raise OSError("image ended during partition copy")
            digest.update(data)
            if os.pwrite(target_fd, data, written) != len(data):
                raise OSError("short partition write")
            written += len(data)
        os.fsync(target_fd)
    finally:
        os.close(target_fd)
        os.close(source_fd)
    run("blockdev", "--flushbufs", str(partition))
    observed = hashlib.sha256()
    target_fd = os.open(partition, os.O_RDONLY)
    try:
        read = 0
        while read < length:
            data = os.pread(target_fd, min(CHUNK, length - read), read)
            if not data:
                raise OSError("partition ended during readback")
            observed.update(data)
            read += len(data)
    finally:
        os.close(target_fd)
    if observed.digest() != digest.digest():
        raise OSError(f"readback SHA-256 differs for {partition}")
    print(f"{partition}: {length} bytes, SHA-256 {observed.hexdigest()}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="nx-rcm-nvme-write",
        description="Write the approved de0878e NX image through its recovery USB gadget",
    )
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--device", required=True, type=Path)
    parser.add_argument(
        "--write",
        action="store_true",
        help="perform the destructive GPT and partition writes",
    )
    args = parser.parse_args()
    required = ("sgdisk", "partprobe", "udevadm", "lsblk", "blockdev", "sync")
    missing = [command for command in required if shutil.which(command) is None]
    if missing:
        raise RuntimeError(f"required command missing from PATH: {', '.join(missing)}")
    image = args.image.resolve(strict=True)
    verify_image(image)
    device = verify_device(args.device)
    print(f"Approved image: {image} ({IMAGE_SHA256})")
    print(f"Recovery USB device: {device} ({NVME_SERIAL}, {DISK_BYTES} bytes)")
    print("GPT layout: esp 256 MiB at LBA 40; APP 32 GiB at LBA 524352")
    if not args.write:
        print("Inspection complete; pass --write to flash after review.")
        return
    if os.geteuid() != 0:
        raise PermissionError("root privileges are required for --write")
    subprocess.run(
        [
            "sgdisk",
            "--clear",
            "--set-alignment=8",
            "--new=1:40:524327",
            "--typecode=1:ef00",
            "--change-name=1:esp",
            "--new=2:524352:67633215",
            "--typecode=2:0700",
            "--change-name=2:APP",
            str(device),
        ],
        check=True,
    )
    subprocess.run(["partprobe", str(device)], check=True)
    subprocess.run(["udevadm", "settle"], check=True)
    verify_device(device)
    suffix = "p" if device.name[-1].isdigit() else ""
    esp = Path(f"{device}{suffix}1")
    root = Path(f"{device}{suffix}2")
    if int(run("blockdev", "--getsize64", str(esp))) != ESP_SECTORS * SECTOR:
        raise ValueError("created ESP size does not match")
    if int(run("blockdev", "--getsize64", str(root))) != 32 * 1024**3:
        raise ValueError("created APP size does not match")
    copy_and_verify(image, esp, ESP_START * SECTOR, ESP_SECTORS * SECTOR)
    copy_and_verify(image, root, ROOT_START * SECTOR, ROOT_SECTORS * SECTOR)
    subprocess.run(["sync"], check=True)


if __name__ == "__main__":
    main()
