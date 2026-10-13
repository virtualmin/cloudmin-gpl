#!/usr/bin/python3
"""Read and write Cloudmin full backups inside the isolated archive worker."""

import hashlib
import json
import os
import re
import sys
import tarfile

RESERVE = 256 * 1024**2
SMALL = 1024**2
NAME = re.compile(r"(?:disk[0-9]{1,2}|nvram|ssh-key|domain.xml)\Z")


def space():
    """space() returns bytes available in this worker's filesystem."""
    st = os.statvfs(".")
    return st.f_bavail * st.f_frsize


def digest(path):
    """digest(path) hashes a file without loading its disk contents into memory."""
    h = hashlib.sha256()
    with open(path, "rb") as src:
        for data in iter(lambda: src.read(SMALL), b""):
            h.update(data)
    return h.hexdigest()


def validate(manifest, limit):
    """validate(manifest, limit) bounds members before reading or extracting them."""
    # Reject unknown formats before interpreting any member metadata.
    if not isinstance(manifest, dict) or manifest.get("format") != "cloudmin-full-1":
        raise ValueError("This is not a supported Cloudmin full backup")
    files = manifest.get("files")
    # Allow up to 64 disks plus XML, firmware and a managed SSH key.
    if not isinstance(files, dict) or not 2 <= len(files) <= 67 or "domain.xml" not in files:
        raise ValueError("Invalid backup file list")
    total = 0
    for name, entry in files.items():
        # Fixed basenames prevent archive paths from reaching the filesystem.
        if not NAME.fullmatch(name) or not isinstance(entry, dict):
            raise ValueError("Invalid file entry in the backup manifest")
        size = entry.get("size")
        # Reject booleans and nonpositive sizes as well as over-budget members.
        if type(size) is not int or size <= 0 or size > limit:
            raise ValueError("Backup file size is invalid or exceeds the limit")
        # Small metadata must not consume the disk-sized extraction allowance.
        if name in ("domain.xml", "ssh-key") and size > SMALL:
            raise ValueError("Backup metadata is too large")
        # Firmware has a separate, bounded allowance even for large VM backups.
        if name == "nvram" and size > 64 * SMALL:
            raise ValueError("Backup firmware variables are too large")
        # Every declared file needs a SHA-256 checksum before its bytes are
        # read.
        if not re.fullmatch(r"[a-f0-9]{64}", entry.get("sha256", "")):
            raise ValueError("Invalid backup checksum")
        total += size
    # Individually valid disks must also fit the combined staging budget.
    if total > limit:
        raise ValueError("Not enough staging space for this backup")
    return files


def pack(request):
    """pack(request) creates one archive from controller-selected regular files."""
    manifest = request["manifest"]
    manifest["files"] = {}
    # Hash only the controller-selected regular files copied into this worker.
    for name in request["members"]:
        if not NAME.fullmatch(name) or not os.path.isfile(name) or os.path.islink(name):
            raise ValueError("Invalid backup input")
        manifest["files"][name] = {"size": os.path.getsize(name), "sha256": digest(name)}
    files = validate(manifest, request["limit"])
    # Check room for an uncompressed archive plus the host's free-space margin.
    if space() < sum(f["size"] for f in files.values()) + RESERVE:
        raise ValueError("Not enough space to write the backup archive")
    with open("manifest.json", "x", encoding="utf-8") as out:
        json.dump(manifest, out, sort_keys=True)
    # Use fast compression to limit CPU time on large disk files.
    compression = {"compresslevel": 1} if request.get("compression") else {}
    # GNU headers support disk files larger than USTAR's 8 GiB limit.
    with tarfile.open("output", "w:gz" if request.get("compression") else "w",
                      format=tarfile.GNU_FORMAT, **compression) as archive:
        for name in ["manifest.json", *files]:
            info = archive.gettarinfo(name, arcname=name)
            # Archive permissions must not inherit worker IDs or loose input
            # modes.
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mode = 0o600
            with open(name, "rb") as src:
                archive.addfile(info, src)
    return {"manifest": manifest, "size": os.path.getsize("output"), "sha256": digest("output")}


def unpack(request):
    """unpack(request) verifies every member; extraction uses only fixed filenames."""
    limit = request["limit"]
    # Stream the manifest first so all later members have declared size limits.
    with tarfile.open("archive", "r|*") as archive:
        members = iter(archive)
        first = next(members, None)
        # A bounded regular manifest is mandatory before any disk data.
        if not first or first.name != "manifest.json" or not first.isfile() or not 0 < first.size <= SMALL:
            raise ValueError("The backup manifest is missing or invalid")
        manifest = json.load(archive.extractfile(first))
        files = validate(manifest, limit)
        # Inspection hashes in place; extraction additionally needs output
        # space.
        if request.get("extract") and space() < sum(f["size"] for f in files.values()) + RESERVE:
            raise ValueError("Not enough space to extract this backup")
        seen = set()
        for member in members:
            name = member.name
            # Refuse links, sparse entries, duplicates and undeclared files.
            if name not in files or name in seen or not member.isfile() or member.sparse:
                raise ValueError("Unexpected, linked, sparse or duplicate file in the backup")
            entry = files[name]
            # Tar headers must agree with the size checked in the manifest.
            if member.size != entry["size"]:
                raise ValueError("Backup file size does not match the manifest")
            seen.add(name)
            h = hashlib.sha256()
            # Exclusive creation prevents overwriting any existing worker file.
            out = open(name, "xb") if request.get("extract") else None
            try:
                with archive.extractfile(member) as src:
                    for data in iter(lambda: src.read(SMALL), b""):
                        h.update(data)
                        # Write only during extraction; inspection just hashes
                        # bytes.
                        if out:
                            # Other jobs can consume space after the initial
                            # check.
                            if space() < RESERVE:
                                raise ValueError("Backup extraction is running out of space")
                            out.write(data)
            finally:
                # Close partial output even after a read or write error.
                if out:
                    out.close()
            # A valid tar header cannot make altered payload bytes acceptable.
            if h.hexdigest() != entry["sha256"]:
                raise ValueError("Backup checksum failed for " + name)
        # Reaching EOF is not success if the manifest promised more files.
        if seen != set(files):
            raise ValueError("The backup is incomplete")
    return {"manifest": manifest, "sha256": digest("archive")}


def main():
    """main() executes one bounded request supplied by the archive worker."""
    with open("request.json", encoding="utf-8") as src:
        request = json.load(src)
    result = pack(request) if request.get("mode") == "pack" else unpack(request)
    print(json.dumps(result))


# Report expected archive failures as worker errors without a Python traceback.
if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, tarfile.TarError, KeyError, TypeError) as error:
        sys.exit(str(error))
