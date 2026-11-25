#!/usr/bin/env python3
"""
Planning half of migrate-from-huly.sh: works out what to carry over from an upstream
Huly self-host checkout. Standard library only (Python 3.8+); YAML is read as the JSON
that `docker compose config` produces, so no YAML parser is needed.

Everything is written into a staging directory that mirrors this repository; the shell
script copies it in place only after the user has seen the report. Nothing outside the
staging directory is modified.

Three-way merges use the pristine upstream files in migration/huly-v0.7.426 as the base:
a change the user made relative to upstream is applied on top of our version, unless we
changed the same thing too - that is a conflict, reported rather than guessed.

Exit codes: 0 = plan ready, 3 = conflicts (see report), 2 = cannot migrate (see report).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from typing import Any, Dict, List, Optional, Tuple

ABSENT = object()


class Report:
    def __init__(self) -> None:
        self.sections: Dict[str, List[str]] = {}
        self.conflicts: List[str] = []
        self.errors: List[str] = []

    def add(self, section: str, line: str) -> None:
        self.sections.setdefault(section, []).append(line)

    def conflict(self, line: str) -> None:
        self.conflicts.append(line)

    def error(self, line: str) -> None:
        self.errors.append(line)

    def render(self) -> str:
        out = ["# Migration from Huly: plan", ""]
        if self.errors:
            out += ["## Cannot migrate", ""] + [f"- {e}" for e in self.errors] + [""]
        if self.conflicts:
            out += [
                "## Conflicts",
                "",
                "Both you and this repository changed the same setting. Nothing is applied until",
                "these are resolved: rerun with `--on-conflict=ours` (keep this repository's value)",
                "or `--on-conflict=theirs` (keep your value), or edit the files after migration.",
                "",
            ] + [f"- {c}" for c in self.conflicts] + [""]
        for title, lines in self.sections.items():
            out += [f"## {title}", ""] + [f"- {line}" for line in lines] + [""]
        return "\n".join(out)


# --------------------------------------------------------------------------- config


def parse_dotenv(path: str) -> Dict[str, str]:
    """Parse KEY=VALUE lines the way docker compose reads .env (not the way bash sources it:
    upstream writes values such as `TITLE=Huly Self Host` unquoted)."""
    values: Dict[str, str] = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].lstrip()
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            else:
                value = re.sub(r"\s+#.*$", "", value)
            values[key] = value
    return values


def template_keys(path: str) -> List[str]:
    keys = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^([A-Z0-9_]+)=", line)
            if m:
                keys.append(m.group(1))
    return keys


def shell_quote(value: str) -> str:
    if re.match(r"^[A-Za-z0-9_./:@,+-]*$", value):
        return value
    return "'" + value.replace("'", "'\\''") + "'"


# Keys this repository's setup.sh regenerates itself (versions, derived URLs, secrets that
# come from the .secret files). Secrets are reconciled separately below.
REGENERATED = {
    "HULY_VERSION", "DESKTOP_CHANNEL", "DB_TYPE", "CR_DB_URL", "PG_DB_URL", "COMPOSE_FILE",
    "SECRET", "CR_USER_PASSWORD", "REDPANDA_ADMIN_PWD",
}
# Upstream setup.sh defaults: a value equal to these was not chosen by the user.
UPSTREAM_DEFAULTS = {"TITLE": "Huly"}
# Upstream-only knobs that have no meaning here.
DROPPED = {
    "HULY_PULSE_VERSION": "hulypulse is released together with the platform here, its tag follows HULY_VERSION",
}
SECRETS = [  # (conf key, secret file)
    ("SECRET", ".huly.secret"),
    ("CR_USER_PASSWORD", ".cr.secret"),
    ("REDPANDA_ADMIN_PWD", ".rp.secret"),
]
VOLUME_KEYS = [
    "VOLUME_ELASTIC_PATH", "VOLUME_FILES_PATH", "VOLUME_CR_DATA_PATH",
    "VOLUME_CR_CERTS_PATH", "VOLUME_REDPANDA_PATH",
]


def plan_config(args: argparse.Namespace, rep: Report) -> Dict[str, str]:
    conf = parse_dotenv(args.huly_conf)
    known = set(template_keys(os.path.join(args.repo, ".template.huly.conf")))
    known |= set(template_keys(os.path.join(args.repo, ".template.db-cockroach.conf")))

    if conf.get("DB_URL", "").startswith("mongodb") or "MONGO_URL" in conf:
        rep.error("This is a MongoDB (v0.6) install. Follow the v0.7.204 section of MIGRATION.md "
                  "(backup on v6, restore into a fresh install) instead.")

    carried: Dict[str, str] = {"DB_TYPE": "cockroach"}
    custom: Dict[str, str] = {}
    for key, value in conf.items():
        if key in REGENERATED:
            continue
        if key in DROPPED:
            rep.add("Configuration", f"`{key}` dropped: {DROPPED[key]}")
            continue
        if UPSTREAM_DEFAULTS.get(key) == value:
            rep.add("Configuration", f"`{key}={value}` is the upstream default, using this repository's default instead")
            continue
        if key in VOLUME_KEYS and value and not os.path.isabs(value) and not value.startswith("~"):
            absolute = os.path.normpath(os.path.join(args.huly_dir, value))
            rep.add("Data volumes", f"`{key}` was relative to the Huly folder: `{value}` -> `{absolute}`")
            value = absolute
        if key in known:
            carried[key] = value
        else:
            custom[key] = value

    carried.setdefault("DOCKER_NAME", "huly")  # upstream compose default when unset
    rep.add("Data volumes", f"`DOCKER_NAME={carried['DOCKER_NAME']}` is kept: the Docker project and its "
            f"named volumes (`{carried['DOCKER_NAME']}_cr_data`, `{carried['DOCKER_NAME']}_files`, ...) are reused in place")
    for key in sorted(carried):
        if key not in ("DB_TYPE", "DOCKER_NAME") and not key.startswith("VOLUME_"):
            rep.add("Configuration", f"`{key}` carried over")
    for key in sorted(custom):
        rep.add("Configuration", f"`{key}` is not part of this repository's template: kept in `custom.conf`")

    stage = args.stage
    with open(os.path.join(stage, "huly_v7.conf"), "w", encoding="utf-8") as f:
        f.write("# Seed written by migrate-from-huly.sh; setup.sh regenerates this file from it.\n")
        for key in sorted(carried):
            f.write(f"{key}={shell_quote(carried[key])}\n")
    if custom:
        with open(os.path.join(stage, "custom.conf"), "w", encoding="utf-8") as f:
            f.write("# Variables carried over from the Huly config that are not in this repository's\n"
                    "# template. setup.sh appends this file to huly_v7.conf on every run.\n")
            for key in sorted(custom):
                f.write(f"{key}={custom[key]}\n")

    # Secrets: the value the running stack was started with (from the config) wins over the
    # .secret file; they differ only if someone edited the config by hand.
    for key, fname in SECRETS:
        src = os.path.join(args.huly_dir, fname)
        file_value = open(src, encoding="utf-8").read().strip() if os.path.isfile(src) else ""
        value = conf.get(key) or file_value
        if not value:
            rep.error(f"No value for `{key}` and no `{fname}` in the Huly folder")
            continue
        if file_value and conf.get(key) and conf[key] != file_value:
            rep.add("Secrets", f"`{fname}` differs from `{key}` in the config; using the config value (the one the stack runs with)")
        with open(os.path.join(stage, fname), "w", encoding="utf-8") as f:
            f.write(value + "\n")
        os.chmod(os.path.join(stage, fname), 0o600)
        rep.add("Secrets", f"`{fname}` copied")
    return carried


# --------------------------------------------------------------------------- images


def load_image_map(path: str) -> Dict[str, str]:
    mapping = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                src, dst = line.split()
                mapping[src] = dst
    return mapping


def split_image(image: str) -> Tuple[str, str]:
    # registry[:port]/repo:tag - the tag starts at the first ':' after the last '/'
    # (the tag itself may be a ${VAR:-default} expression)
    name_start = image.rfind("/", 0, image.find("$") if "$" in image else len(image)) + 1
    colon = image.find(":", name_start)
    if colon >= 0:
        return image[:colon], image[colon + 1:]
    return image, ""


def map_image(image: str, mapping: Dict[str, str], where: str, rep: Optional[Report]) -> str:
    repo, tag = split_image(image)
    bare = re.sub(r"^(docker\.io/|index\.docker\.io/)", "", repo)
    if bare in mapping:
        if rep is not None and tag != "${HULY_VERSION}":
            rep.add("Images", f"{where}: `{image}` was pinned to `{tag or 'latest'}`; it now follows `HULY_VERSION`")
        return f"{mapping[bare]}:${{HULY_VERSION}}"
    if bare.startswith("hardcoreeng/"):
        if rep is not None:
            rep.error(f"{where}: no Platform Collective image for `{image}` (add it to migration/image-map.txt)")
        return image
    return image


# --------------------------------------------------------------------------- compose


def env_to_dict(env: Any) -> Dict[str, Optional[str]]:
    if env is None or env is ABSENT:
        return {}
    if isinstance(env, dict):
        return {k: (None if v is None else str(v)) for k, v in env.items()}
    out: Dict[str, Optional[str]] = {}
    for item in env:
        if "=" in item:
            k, v = item.split("=", 1)
            out[k] = v
        else:
            out[item] = None
    return out


def env_list(env: Dict[str, Optional[str]]) -> List[str]:
    return [k if v is None else f"{k}={v}" for k, v in env.items()]


def strip_names(section: Dict[str, Any], project: str) -> Dict[str, Any]:
    """`docker compose config` adds name: <project>_<key> to every network/volume."""
    out = {}
    for key, value in (section or {}).items():
        if isinstance(value, dict) and value.get("name") == f"{project}_{key}":
            value = {k: v for k, v in value.items() if k != "name"}
        out[key] = value
    return out


class Override:
    """A value emitted with the !override tag (replace instead of merge)."""

    def __init__(self, value: Any) -> None:
        self.value = value


def three_way(b: Any, u: Any, o: Any) -> Tuple[str, Any]:
    if u == b:
        return "ours", o
    if o == b or o == u:
        return "theirs", u
    return "conflict", u


def plan_compose(args: argparse.Namespace, rep: Report) -> None:
    mapping = load_image_map(args.image_map)
    project = args.project
    base = json.load(open(args.base_compose))
    user = json.load(open(args.user_compose))
    ours = json.load(open(args.ours_compose))

    def services(doc: Dict[str, Any], label: Optional[str]) -> Dict[str, Any]:
        out = {}
        for name, svc in (doc.get("services") or {}).items():
            svc = dict(svc)
            if "image" in svc:
                svc["image"] = map_image(svc["image"], mapping, f"service `{name}`", rep if label else None)
            out[name] = svc
        return out

    b_svc, u_svc, o_svc = services(base, None), services(user, "user"), services(ours, None)
    override_services: Dict[str, Any] = {}
    copies: List[Tuple[str, str]] = []

    for name, u in u_svc.items():
        b, o = b_svc.get(name), o_svc.get(name)
        if b is None and o is None:
            override_services[name] = rewrite_binds(dict(u), args, rep, copies, name)
            rep.add("Services", f"`{name}`: added by you, carried over" + (f" (image `{u['image']}`)" if "image" in u else ""))
            continue
        if b is None:
            # Added by both sides (e.g. print, which this repository enables by default):
            # this repository's definition wins; settings only you have are added to it.
            delta = added_by_both(name, u, o, args, rep, copies)
        else:
            delta = service_delta(name, b, u, o, args, rep, copies)
        if delta:
            override_services[name] = delta

    for name in b_svc:
        if name not in u_svc and name in o_svc:
            override_services[name] = {"profiles": ["disabled"]}
            rep.add("Services", f"`{name}`: you removed it, so it stays off (`profiles: [disabled]` in compose.override.yml)")

    doc: Dict[str, Any] = {}
    if override_services:
        doc["services"] = override_services
    for section in ("volumes", "networks", "secrets", "configs"):
        b_sec = strip_names(base.get(section) or {}, project)
        u_sec = strip_names(user.get(section) or {}, project)
        o_sec = strip_names(ours.get(section) or {}, project)
        extra = {}
        for key, value in u_sec.items():
            if key not in b_sec and key not in o_sec:
                extra[key] = value
                rep.add("Services", f"top-level {section[:-1]} `{key}`: added by you, carried over")
            elif key in b_sec and value != b_sec[key]:
                state, val = three_way(b_sec[key], value, o_sec.get(key))
                if state == "theirs":
                    extra[key] = val
                elif state == "conflict":
                    resolve_conflict(rep, f"top-level {section[:-1]} `{key}`", lambda: extra.__setitem__(key, val), args)
        if extra:
            doc[section] = extra
    for key, value in user.items():
        if key.startswith("x-") and value != base.get(key):
            doc[key] = value

    if doc:
        with open(os.path.join(args.stage, "compose.override.yml"), "w", encoding="utf-8") as f:
            f.write("# Your changes to the upstream Huly compose.yml, carried over by migrate-from-huly.sh.\n"
                    "# Docker Compose merges this file over compose.yml automatically; keep your own\n"
                    "# changes here so that `git pull` never conflicts with them.\n")
            f.write(to_yaml(doc))
    for src, dst in copies:
        target = os.path.join(args.stage, dst)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(src, target)


def resolve_conflict(rep: Report, what: str, take_theirs, args: argparse.Namespace, detail: str = "") -> None:
    if args.on_conflict == "theirs":
        take_theirs()
        rep.add("Resolved conflicts", f"{what}: kept your value{detail}")
    elif args.on_conflict == "ours":
        rep.add("Resolved conflicts", f"{what}: kept this repository's value{detail}")
    else:
        rep.conflict(f"{what}{detail}")


def service_delta(name: str, b: Dict[str, Any], u: Dict[str, Any], o: Dict[str, Any],
                  args: argparse.Namespace, rep: Report, copies: List[Tuple[str, str]]) -> Dict[str, Any]:
    delta: Dict[str, Any] = {}
    for key in sorted(set(b) | set(u) | set(o)):
        bv, uv, ov = b.get(key, ABSENT), u.get(key, ABSENT), o.get(key, ABSENT)
        if key == "environment":
            env = env_delta(name, env_to_dict(bv), env_to_dict(uv), env_to_dict(ov), args, rep)
            if env is not None:
                delta["environment"] = env
            continue
        state, value = three_way(bv, uv, ov)
        if state == "ours":
            continue
        if value is ABSENT:
            if ov is not ABSENT:
                rep.add("Services", f"`{name}`: you removed `{key}`; cleared with `!reset`")
                delta[key] = Override(None)
            continue

        def take() -> None:
            v = value
            if key == "volumes":
                v = rewrite_volume_list(v, args, rep, copies, name)
            delta[key] = v if not isinstance(v, (list, dict)) else Override(v)

        if state == "theirs":
            take()
            rep.add("Services", f"`{name}`: your `{key}` carried over")
        else:
            resolve_conflict(rep, f"`{name}.{key}`", take, args,
                             f" (upstream: `{short(bv)}`, yours: `{short(uv)}`, this repository: `{short(ov)}`)")
    return delta


def added_by_both(name: str, u: Dict[str, Any], o: Dict[str, Any], args: argparse.Namespace,
                  rep: Report, copies: List[Tuple[str, str]]) -> Dict[str, Any]:
    delta: Dict[str, Any] = {}
    u_env, o_env = env_to_dict(u.get("environment")), env_to_dict(o.get("environment"))
    extra = {k: v for k, v in u_env.items() if k not in o_env}
    if extra:
        delta["environment"] = env_list(extra)
        rep.add("Services", f"`{name}`: you added it too; this repository's definition is used, "
                f"plus your environment {', '.join('`%s`' % k for k in extra)}")
    for key, value in u.items():
        if key not in o and key != "environment":
            delta[key] = rewrite_volume_list(value, args, rep, copies, name) if key == "volumes" else value
            rep.add("Services", f"`{name}`: your `{key}` added")
    differing = [k for k in o_env if k in u_env and u_env[k] != o_env[k]]
    if differing:
        rep.add("Services", f"`{name}`: kept this repository's value for {', '.join('`%s`' % k for k in differing)} "
                "(yours differed; check if you relied on it)")
    return delta


def env_delta(name: str, b: Dict[str, Optional[str]], u: Dict[str, Optional[str]], o: Dict[str, Optional[str]],
              args: argparse.Namespace, rep: Report) -> Optional[Any]:
    result = dict(o)
    changed = removed = False
    for key in list(b) + [k for k in u if k not in b]:
        bv, uv, ov = b.get(key, ABSENT), u.get(key, ABSENT), o.get(key, ABSENT)
        state, value = three_way(bv, uv, ov)
        if state == "ours":
            continue

        def take() -> None:
            nonlocal changed, removed
            if value is ABSENT:
                result.pop(key, None)
                removed = True
            else:
                result[key] = value
            changed = True

        if state == "theirs":
            if value == ov:
                continue
            take()
            verb = "removed" if value is ABSENT else ("added" if bv is ABSENT else "changed")
            rep.add("Services", f"`{name}`: environment `{key}` {verb} by you, carried over")
        else:
            resolve_conflict(rep, f"`{name}` environment `{key}`", take, args,
                             f" (upstream: `{short(bv)}`, yours: `{short(uv)}`, this repository: `{short(ov)}`)")
    if not changed:
        return None
    if removed:
        return Override(env_list(result))
    return env_list({k: v for k, v in result.items() if o.get(k, ABSENT) != v})


def short(value: Any) -> str:
    if value is ABSENT:
        return "<not set>"
    text = value if isinstance(value, str) else json.dumps(value)
    return text if len(text) <= 80 else text[:77] + "..."


def rewrite_binds(svc: Dict[str, Any], args: argparse.Namespace, rep: Report,
                  copies: List[Tuple[str, str]], name: str) -> Dict[str, Any]:
    if "volumes" in svc:
        svc["volumes"] = rewrite_volume_list(svc["volumes"], args, rep, copies, name)
    return svc


def rewrite_volume_list(volumes: List[Any], args: argparse.Namespace, rep: Report,
                        copies: List[Tuple[str, str]], name: str) -> List[Any]:
    """Relative bind mounts point into the Huly folder. Small files (configs) are copied
    next to compose.yml here; directories (data) are referenced at their old location."""
    out = []
    for vol in volumes:
        if isinstance(vol, dict) and vol.get("type") == "bind":
            src = vol.get("source", "")
            if src and not os.path.isabs(src) and "$" not in src and not src.startswith("~"):
                vol = dict(vol)
                abs_src = os.path.normpath(os.path.join(args.huly_dir, src))
                rel = os.path.relpath(abs_src, args.huly_dir)
                if os.path.isfile(abs_src) and not rel.startswith(".."):
                    if not os.path.exists(os.path.join(args.repo, rel)):
                        copies.append((abs_src, rel))
                        rep.add("Files", f"`{name}`: `{rel}` copied from the Huly folder")
                    else:
                        rep.add("Files", f"`{name}`: `{rel}` already exists here and is used as is; compare it with the Huly copy")
                else:
                    vol["source"] = abs_src
                    rep.add("Files", f"`{name}`: bind mount `{src}` now points at `{abs_src}` (still inside the Huly folder - move it if you delete that folder)")
        out.append(vol)
    return out


# --------------------------------------------------------------------------- YAML out

PLAIN = re.compile(r"^[A-Za-z0-9_./-]+$")
YAML_WORDS = {"true", "false", "yes", "no", "on", "off", "null", "y", "n", "~"}


def scalar(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    if PLAIN.match(text) and text.lower() not in YAML_WORDS and not re.match(r"^[0-9.+-]", text):
        return text
    return json.dumps(text)  # a JSON string is a valid double-quoted YAML scalar


def to_yaml(value: Any, indent: int = 0) -> str:
    pad = "  " * indent
    lines: List[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            lines.append(emit(f"{pad}{scalar(key)}:", item, indent))
    elif isinstance(value, list):
        for item in value:
            lines.append(emit(f"{pad}-", item, indent, in_list=True))
    return "\n".join(lines) + ("\n" if indent == 0 else "")


def emit(prefix: str, item: Any, indent: int, in_list: bool = False) -> str:
    tag = ""
    if isinstance(item, Override):
        tag, item = (" !reset", None) if item.value is None else (" !override", item.value)
        if item is None:
            return f"{prefix}{tag} null"
    if isinstance(item, (dict, list)) and item:
        body = to_yaml(item, indent + 1)
        if in_list and isinstance(item, dict):
            first, _, rest = body.lstrip(" ").partition("\n")
            return f"{prefix} {first}" + ("\n" + rest if rest else "")
        return f"{prefix}{tag}\n{body}"
    if isinstance(item, dict):
        return f"{prefix}{tag} {{}}"
    if isinstance(item, list):
        return f"{prefix}{tag} []"
    return f"{prefix}{tag} {scalar(item)}"


# --------------------------------------------------------------------------- nginx

REPEATABLE = {
    "proxy_set_header", "add_header", "set", "rewrite", "location", "if", "include", "listen",
    "error_page", "allow", "deny", "map", "server", "upstream", "sub_filter", "more_set_headers",
    "limit_req", "set_real_ip_from",
}
BLANK, DISABLED, HEADER = "\x02", "\x00", "\x01"


class Entry:
    """One statement of an nginx block: a directive, a nested block or a comment."""

    def __init__(self, key: str, value: Any, disabled: bool = False, blank_before: bool = False) -> None:
        self.key = key            # directive text, block header, or '#...' for comments
        self.value = value        # str, or Block
        self.disabled = disabled  # commented out (only set on the outermost commented statement)
        self.blank_before = blank_before


class Block:
    def __init__(self, header: str) -> None:
        self.header = header
        self.entries: List[Entry] = []

    def keyed(self) -> Dict[str, Entry]:
        return {e.key: e for e in self.entries if not e.key.startswith("#")}


def tokenize(text: str) -> List[str]:
    tokens: List[str] = []
    buf, quote, i, newlines = "", "", 0, 0

    def flush() -> None:
        nonlocal buf
        if buf.strip():
            tokens.append(" ".join(buf.split()))
        buf = ""

    while i < len(text):
        c = text[i]
        if quote:
            buf += c
            if c == "\\" and i + 1 < len(text):
                buf += text[i + 1]
                i += 1
            elif c == quote:
                quote = ""
        elif c == "\n":
            if not buf.strip():
                newlines += 1
                if newlines == 2 and tokens and tokens[-1] != BLANK:
                    tokens.append(BLANK)
            buf += " "
        elif c in "'\"":
            quote, buf, newlines = c, buf + c, 0
        elif c in "{};":
            flush()
            tokens.append(c)
            newlines = 0
        elif c == "#":
            flush()
            end = text.find("\n", i)
            end = len(text) if end < 0 else end
            tokens.append("#" + text[i + 1:end].rstrip())
            i, newlines = end, 0
            continue
        else:
            if not c.isspace():
                newlines = 0
            buf += c
        i += 1
    flush()
    return tokens


def uncomment_code(text: str) -> str:
    """Commented-out nginx blocks (`#location /_love {` ... `#}`) become real code whose
    statements are marked disabled, so uncommenting a block is a change that can be merged."""
    lines = text.split("\n")
    out: List[str] = []
    i = 0
    while i < len(lines):
        if re.match(r"^\s*#\s*[a-z_~]+[^#]*\{\s*$", lines[i]):
            depth, j, run = 0, i, []
            while j < len(lines) and (re.match(r"^\s*#", lines[j]) or not lines[j].strip()):
                code = re.sub(r"^(\s*)#", r"\1", lines[j], count=1)
                stripped = code.strip()
                if stripped and not stripped.startswith("}") and not stripped.startswith("#"):
                    code = code.replace(stripped, DISABLED + stripped, 1)
                run.append(code)
                depth += code.count("{") - code.count("}")
                j += 1
                if depth == 0:
                    break
            if depth == 0 and run:
                out.extend(run)
                i = j
                continue
        out.append(lines[i])
        i += 1
    return re.sub(r"([^\s{};#][^{};#\n]*?)\s*\{", lambda m: m.group(1) + HEADER + " {", "\n".join(out))


def parse_nginx(text: str) -> Block:
    root = Block("")
    stack: List[Tuple[Block, bool]] = [(root, False)]  # (block, inside a disabled block)
    blank = False
    for tok in tokenize(uncomment_code(text)):
        cur, in_disabled = stack[-1]
        if tok == BLANK:
            blank = True
            continue
        if tok in ("{", ";"):
            continue
        if tok == "}":
            if len(stack) > 1:
                stack.pop()
            continue
        disabled = tok.startswith(DISABLED)
        tok = tok.lstrip(DISABLED)
        if tok.startswith("#"):
            cur.entries.append(Entry(tok, tok, False, blank))
        elif tok.endswith(HEADER):
            blk = Block(tok[:-1])
            cur.entries.append(Entry(blk.header, blk, disabled and not in_disabled, blank))
            stack.append((blk, in_disabled or disabled))
        else:
            cur.entries.append(Entry(tok, tok, disabled and not in_disabled, blank))
        blank = False
    return root


def nginx_merge(b: Block, u: Block, o: Block, path: str, rep: Report, args: argparse.Namespace) -> Block:
    """Three-way merge of one block. Directives are keyed by their full text, so a changed
    directive is a removal plus an addition; a non-repeatable directive that ends up twice
    means both sides changed it."""
    bk, uk, ok = b.keyed(), u.keyed(), o.keyed()
    result = Block(o.header)
    for e in o.entries:
        if e.key.startswith("#"):
            result.entries.append(e)
            continue
        be, ue = bk.get(e.key), uk.get(e.key)
        if be is not None and ue is None:
            rep.add("nginx (.huly.nginx)", f"`{join_path(path, e.key)}` removed, as in your config")
            continue
        disabled = e.disabled
        if be is not None and ue is not None and ue.disabled != be.disabled:
            if e.disabled == be.disabled:
                disabled = ue.disabled
                what = "commented out" if disabled else "enabled (uncommented)"
                rep.add("nginx (.huly.nginx)", f"`{join_path(path, e.key)}` {what}, as in your config")
        value = e.value
        if isinstance(e.value, Block) and ue is not None and isinstance(ue.value, Block):
            base_block = be.value if be is not None and isinstance(be.value, Block) else e.value
            value = nginx_merge(base_block, ue.value, e.value, join_path(path, e.key), rep, args)
        result.entries.append(Entry(e.key, value, disabled, e.blank_before))
    for e in u.entries:
        if e.key.startswith("#") or e.key in ok or e.key in bk:
            continue
        result.entries.append(Entry(e.key, e.value, e.disabled, isinstance(e.value, Block)))
        rep.add("nginx (.huly.nginx)", f"`{e.key}`" + (" (commented out)" if e.disabled else "")
                + f" added by you in `{path or 'top level'}`, carried over")

    counts: Dict[str, int] = {}
    for e in result.entries:
        if not e.disabled and not isinstance(e.value, Block) and not e.key.startswith("#"):
            name = e.key.split(" ", 1)[0]
            counts[name] = counts.get(name, 0) + 1
    dup = {n for n, c in counts.items() if c > 1 and n not in REPEATABLE}
    if dup:
        keep = uk if args.on_conflict == "theirs" else ok
        result.entries = [e for e in result.entries
                          if isinstance(e.value, Block) or e.disabled or e.key.startswith("#")
                          or e.key.split(" ", 1)[0] not in dup or e.key in keep]
        resolve_conflict(rep, f".huly.nginx `{path or 'top level'}`", lambda: None, args,
                         f": `{', '.join(sorted(dup))}` changed by both you and this repository")
    return result


def join_path(path: str, key: str) -> str:
    return f"{path} > {key}" if path else key


def render_nginx(block: Block, indent: int = 0, prefix: Optional[str] = None) -> List[str]:
    """prefix: inside a commented-out block, every line starts with the block's indentation
    and '#', followed by the relative indentation (the style used in .huly.nginx)."""
    lines: List[str] = []
    for e in block.entries:
        pad = "    " * indent
        if prefix is not None:
            lead = prefix + "    " * indent
        elif e.disabled:
            lead = pad + "#"
        else:
            lead = pad
        if e.blank_before and lines:
            lines.append(prefix.rstrip() if prefix is not None else "")
        if e.key.startswith("#"):
            lines.append((prefix + "    " * indent if prefix is not None else pad) + e.value)
        elif isinstance(e.value, Block):
            lines.append(f"{lead}{e.value.header} {{")
            if prefix is None and e.disabled:
                lines += render_nginx(e.value, 1, pad + "#")
            else:
                lines += render_nginx(e.value, indent + 1, prefix)
            lines.append(f"{lead}}}")
        else:
            lines.append(f"{lead}{e.value};")
    return lines


def plan_nginx(args: argparse.Namespace, rep: Report) -> None:
    user_path = os.path.join(args.huly_dir, ".huly.nginx")
    if not os.path.isfile(user_path):
        return
    base_text = open(args.base_nginx, encoding="utf-8").read()
    user_text = open(user_path, encoding="utf-8").read()
    ours_text = open(os.path.join(args.repo, ".huly.nginx"), encoding="utf-8").read()
    norm = lambda t: [l.rstrip() for l in t.strip().splitlines()]  # noqa: E731
    if norm(base_text) == norm(user_text):
        rep.add("nginx (.huly.nginx)", "not customized, this repository's version is used")
        return
    merged = nginx_merge(parse_nginx(base_text), parse_nginx(user_text), parse_nginx(ours_text), "", rep, args)
    with open(os.path.join(args.stage, ".huly.nginx"), "w", encoding="utf-8") as f:
        f.write("# Merged by migrate-from-huly.sh: this repository's .huly.nginx plus your changes.\n")
        f.write("\n".join(render_nginx(merged)) + "\n")
    with open(os.path.join(args.stage, ".huly.nginx.huly-orig"), "w", encoding="utf-8") as f:
        f.write(user_text)
    rep.add("nginx (.huly.nginx)", "your original is saved as `.huly.nginx.huly-orig` for reference")


# --------------------------------------------------------------------------- main


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--repo", required=True, help="this repository")
    p.add_argument("--huly-dir", required=True)
    p.add_argument("--huly-conf", required=True)
    p.add_argument("--stage", required=True)
    p.add_argument("--project", required=True)
    p.add_argument("--base-compose", required=True, help="docker compose config JSON of pristine upstream")
    p.add_argument("--user-compose", required=True, help="docker compose config JSON of the Huly checkout")
    p.add_argument("--ours-compose", required=True, help="docker compose config JSON of this repository")
    p.add_argument("--base-nginx", required=True)
    p.add_argument("--image-map", required=True)
    p.add_argument("--on-conflict", choices=["stop", "ours", "theirs"], default="stop")
    p.add_argument("--report", required=True)
    args = p.parse_args()
    args.huly_dir = os.path.abspath(args.huly_dir)
    args.repo = os.path.abspath(args.repo)
    os.makedirs(args.stage, exist_ok=True)

    rep = Report()
    plan_config(args, rep)
    plan_compose(args, rep)
    plan_nginx(args, rep)

    with open(args.report, "w", encoding="utf-8") as f:
        f.write(rep.render())
    if rep.errors:
        return 2
    if rep.conflicts:
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
