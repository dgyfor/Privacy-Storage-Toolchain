#!/usr/bin/env python3
"""同步 GLOBAL_INDEX 的云盘信息到 index.jsonl 的 clouds 数组。
用法: sync_clouds.py <index.jsonl> <encrypted_name> <cloud_name> <cloud_path>
"""
import sys, json, os

def main():
    if len(sys.argv) != 5:
        print("usage: sync_clouds.py <index.jsonl> <enc> <name> <path>", file=sys.stderr)
        return 1
    idx, enc, cname, cpath = sys.argv[1:5]
    if not os.path.isfile(idx):
        print("index not found: " + idx, file=sys.stderr)
        return 1

    tmp = idx + ".tmp"
    updated = 0
    with open(idx, "r", encoding="utf-8") as fin, open(tmp, "w", encoding="utf-8") as fout:
        for line in fin:
            s = line.strip()
            if not s:
                continue
            try:
                obj = json.loads(s)
            except json.JSONDecodeError:
                fout.write(line)
                continue
            if obj.get("encrypted_name") == enc:
                clouds = obj.get("clouds")
                if not isinstance(clouds, list):
                    clouds = []
                if not any(c.get("name") == cname and c.get("path") == cpath for c in clouds):
                    clouds.append({"name": cname, "path": cpath})
                    updated += 1
                obj["clouds"] = clouds
                fout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
            else:
                fout.write(line)
    os.replace(tmp, idx)
    print("sync_clouds: updated " + str(updated))
    return 0

if __name__ == "__main__":
    sys.exit(main())