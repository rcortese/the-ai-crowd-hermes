#!/usr/bin/env python3
"""Stdlib Hermes-base v3 source and OCI normalization contract."""
from __future__ import annotations
import argparse, copy, hashlib, io, json, re, tarfile

LOCK_SCHEMA = "the-ai-crowd.hermes-base-v3-lock.v1"
RECEIPT_SCHEMA = "the-ai-crowd.hermes-base-v3-receipt.v1"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
IMAGE_ID = re.compile(r"^sha256:[0-9a-f]{64}$")

def _obj(value, name):
    if not isinstance(value, dict): raise ValueError(f"{name} must be an object")
    return value

def _keys(value, expected, name):
    extra, missing = set(value)-set(expected), set(expected)-set(value)
    if extra: raise ValueError(f"{name} has unexpected fields: {sorted(extra)}")
    if missing: raise ValueError(f"{name} is missing fields: {sorted(missing)}")

def _text(value, name, pattern=None):
    if not isinstance(value, str) or not value: raise ValueError(f"{name} must be a non-empty string")
    if pattern and not pattern.fullmatch(value): raise ValueError(f"{name} has invalid format")

def validate_lock(lock):
    lock = _obj(lock, "lock"); _keys(lock, {"schema","source","image","receipt"}, "lock")
    if lock["schema"] != LOCK_SCHEMA: raise ValueError("invalid lock schema")
    source = _obj(lock["source"], "source"); _keys(source, {"git_dir","work_tree","commit","tree","archive"}, "source")
    for key in ("git_dir","work_tree"): _text(source[key], f"source.{key}")
    for key in ("commit","tree"): _text(source[key], f"source.{key}", HEX40)
    archive = _obj(source["archive"], "source.archive"); _keys(archive, {"format","prefix","sha256","bytes"}, "source.archive")
    if archive["format"] != "tar" or archive["prefix"] != "hermes-agent/": raise ValueError("archive must be tar with hermes-agent/ prefix")
    _text(archive["sha256"], "source.archive.sha256", HEX64)
    if not isinstance(archive["bytes"], int) or isinstance(archive["bytes"], bool) or archive["bytes"] <= 0: raise ValueError("source.archive.bytes must be a positive integer")
    image = _obj(lock["image"], "image"); _keys(image, {"repository","pre_normalization_tag","final_tag","final_image_id"}, "image")
    for key in ("repository","pre_normalization_tag"): _text(image[key], f"image.{key}")
    if image["final_tag"] is not None or image["final_image_id"] is not None or lock["receipt"] is not None: raise ValueError("source-only lock final image and receipt fields must be null")
    return lock

def load_lock(path):
    with open(path, encoding="utf-8") as f: return validate_lock(json.load(f))

def verify_archive_stream(lock, stream):
    wanted = validate_lock(lock)["source"]["archive"]; digest=hashlib.sha256(); size=0
    while chunk := stream.read(1024*1024): digest.update(chunk); size += len(chunk)
    if size != wanted["bytes"]: raise ValueError(f"archive bytes mismatch: expected {wanted['bytes']}, got {size}")
    if digest.hexdigest() != wanted["sha256"]: raise ValueError("archive sha256 mismatch")

def normalize_oci_config(config):
    """Copy config and remove exactly Config.Volumes['/opt/data'], if present."""
    result = copy.deepcopy(_obj(config, "OCI config")); cfg=result.get("Config")
    if isinstance(cfg, dict) and isinstance(cfg.get("Volumes"), dict): cfg["Volumes"].pop("/opt/data", None)
    return result

def normalize_image_tar(input_path, output_path, final_tag):
    with tarfile.open(input_path, "r") as src:
        members=src.getmembers(); manifest=json.load(src.extractfile("manifest.json"))
        if not isinstance(manifest,list) or len(manifest)!=1 or not isinstance(manifest[0],dict): raise ValueError("image tar must contain one manifest entry")
        config_name=manifest[0].get("Config")
        if not isinstance(config_name,str): raise ValueError("image tar manifest lacks Config")
        config=json.load(src.extractfile(config_name)); cfg=config.get("config")
        if not isinstance(cfg,dict) or not isinstance(cfg.get("Volumes"),dict): raise ValueError("image config lacks config.Volumes")
        cfg["Volumes"].pop("/opt/data",None); manifest[0]["RepoTags"]=[final_tag]
        bodies={m.name: src.extractfile(m).read() if m.isfile() else None for m in members}
        bodies["manifest.json"]=json.dumps(manifest,sort_keys=True,separators=(",",":")).encode()
        bodies[config_name]=json.dumps(config,sort_keys=True,separators=(",",":")).encode()
        with tarfile.open(output_path,"w") as dst:
            for member in members: dst.addfile(member, io.BytesIO(bodies[member.name]) if bodies[member.name] is not None else None)

def verify_receipt(receipt, lock):
    lock=validate_lock(lock); receipt=_obj(receipt,"receipt")
    fields={"schema","source_commit","source_tree","archive_sha256","archive_bytes","pre_normalization_tag","pre_normalization_image_id","final_tag","final_image_id","normalized_config_sha256"}; _keys(receipt,fields,"receipt")
    if receipt["schema"] != RECEIPT_SCHEMA: raise ValueError("invalid receipt schema")
    source,archive=lock["source"],lock["source"]["archive"]
    for key,wanted in (("source_commit",source["commit"]),("source_tree",source["tree"]),("archive_sha256",archive["sha256"]),("archive_bytes",archive["bytes"])):
        if receipt[key] != wanted: raise ValueError(f"receipt.{key} does not bind lock")
    for key in ("pre_normalization_tag","final_tag"):_text(receipt[key],f"receipt.{key}")
    for key in ("pre_normalization_image_id","final_image_id"):_text(receipt[key],f"receipt.{key}",IMAGE_ID)
    _text(receipt["normalized_config_sha256"],"receipt.normalized_config_sha256",HEX64)
    if receipt["pre_normalization_tag"] == receipt["final_tag"]: raise ValueError("receipt final tag must differ from pre-normalization tag")
    return receipt

def main():
    parser=argparse.ArgumentParser(); sub=parser.add_subparsers(dest="cmd",required=True)
    p=sub.add_parser("validate-lock"); p.add_argument("lock")
    p=sub.add_parser("normalize-image-tar"); p.add_argument("input"); p.add_argument("output"); p.add_argument("--final-tag",required=True)
    p=sub.add_parser("verify-receipt"); p.add_argument("lock"); p.add_argument("receipt")
    a=parser.parse_args()
    if a.cmd=="validate-lock": print(json.dumps(load_lock(a.lock),sort_keys=True))
    elif a.cmd=="normalize-image-tar": normalize_image_tar(a.input,a.output,a.final_tag)
    else:
        with open(a.receipt,encoding="utf-8") as f: verify_receipt(json.load(f),load_lock(a.lock))
if __name__ == "__main__": main()
