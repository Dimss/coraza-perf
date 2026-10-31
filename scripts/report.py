#!/usr/bin/env python3
"""Aggregate Path A (in-cluster) results into one HTML report per scenario,
covering every load profile measured under it — `results/<scenario>-report.html`.

Result files are named `<scenario>[+<profile>]__<tag>__<ts>.json`, so the
scenario, the load profiles and the rulesets are all discovered from `results/`
rather than configured. Runs sharing a cell are MEDIANED across repeats
(README.md, "Methodology"); WAF cost is the delta against that profile's own
`waf-off` baseline, per percentile.

If `collect.sh` was used, the matching `metrics__<scenario>__<tag>__<ts>.jsonl`
files are folded in as per-cell server-side tiles (RPS by outcome, active rule
count, plugin reloads in-window, cache p99, cache size, workqueue). The report
is the durable per-run artifact: no live Grafana/Prometheus needed to view it
later or to compare runs across time.

Rendering lives in scripts/reportlib.py and templates/report-template.html.

    python3 scripts/report.py                     # every scenario in results/
    python3 scripts/report.py --scenario NAME     # just one
    python3 scripts/report.py --scenario NAME --out somewhere.html

Cluster facts the results cannot carry are read from the environment when set:
PLATFORM, ISTIO_VERSION, OPERATOR_VERSION, NAMESPACE. Unset renders as
"not recorded" — the page never claims a cluster it cannot prove.
"""
import argparse, glob, json, os, pathlib, re, statistics, datetime, collections, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reportlib

try:
    import yaml as _yaml
except ImportError:
    _yaml = None

PCTS = ["p50", "p75", "p90", "p95", "p99", "p99.9"]
PCT_KEY = {"p50": 50.0, "p75": 75.0, "p90": 90.0, "p95": 95.0, "p99": 99.0, "p99.9": 99.9}
BASELINE_TAG = "waf-off"
# Validity criteria (README.md): a cell whose observed rate missed the
# requested one by more than this describes a different workload.
QPS_TOLERANCE = 0.05


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


# ---- fortio JSON -----------------------------------------------------------
def parse_run(path):
    d = json.load(open(path))
    h = d.get("DurationHistogram", {})
    pct = {round(p["Percentile"], 1): p["Value"] * 1000.0 for p in h.get("Percentiles", [])}
    codes = d.get("RetCodes", {})
    total = sum(codes.values()) or 1
    ok = sum(v for k, v in codes.items() if str(k).startswith("2"))
    blocked = sum(v for k, v in codes.items() if str(k) == "403")  # WAF block, not an error
    return {
        "pcts": {p: pct.get(PCT_KEY[p]) for p in PCTS},
        "avg": (h.get("Avg") or 0.0) * 1000.0,
        "qps": d.get("ActualQPS", 0.0),
        "err": 100.0 * (total - ok - blocked) / total,
        "blocked": 100.0 * blocked / total,
        "requested_qps": _as_float(d.get("RequestedQPS")),
        "conn": d.get("NumThreads"),
        # fortio records its own version, so the report can state the load
        # generator it actually ran instead of a literal in the generator.
        "fortio": d.get("Version"),
    }


def _as_float(v):
    """fortio writes RequestedQPS as a string ("500") or a number."""
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


# ---- collect.sh metrics jsonl ---------------------------------------------
def _series(resp):
    """Yield (labels, [float values]) from a Prometheus query_range response."""
    if not isinstance(resp, dict):
        return
    for s in resp.get("data", {}).get("result", []):
        vals = []
        for _, v in s.get("values", []):
            try:
                vals.append(float(v))
            except (TypeError, ValueError):
                pass
        yield s.get("metric", {}), vals


def parse_metrics(path):
    """Reduce a metrics__*.jsonl file to a compact server-side summary."""
    by_name = collections.defaultdict(list)  # metric name -> [(labels, vals)]
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        for labels, vals in _series(obj.get("result", {})):
            by_name[obj.get("metric", "")].append((labels, vals))

    def all_vals(name):
        return [v for _, vs in by_name.get(name, []) for v in vs]

    srv = {}
    # active rule count — the ruleset actually loaded (max over window)
    rc = all_vals("waf_active_rule_count")
    srv["rule_count"] = int(max(rc)) if rc else None
    # RPS by outcome — mean over window per outcome label
    rps = {}
    for labels, vals in by_name.get("waf_rps_by_outcome", []):
        m = mean(vals)
        if m is not None:
            rps[labels.get("outcome", "?")] = m
    srv["rps"] = rps or None
    # plugin reloads DURING the window (counter delta; should be 0 for a valid run).
    # The query sums by status, so there is one series per status and the window
    # delta is the sum of theirs — reading only the first series under-reports a
    # reload that failed, which is exactly the case worth seeing.
    deltas = [max(vals) - min(vals) for _, vals in by_name.get("waf_plugin_loads", []) if vals]
    srv["plugin_loads_delta"] = sum(deltas) if deltas else None
    # cache poll p99 (seconds -> ms), cache size (bytes -> MB), workqueue, anomaly
    cp99 = all_vals("cache_latency_p99")
    srv["cache_p99_ms"] = max(cp99) * 1000.0 if cp99 else None
    cs = all_vals("cache_size_bytes")
    srv["cache_size_mb"] = max(cs) / 1e6 if cs else None
    wq = all_vals("workqueue_depth")
    srv["workqueue_max"] = max(wq) if wq else None
    an = all_vals("waf_anomaly_p95")
    srv["anomaly_p95"] = mean(an)
    return srv if any(v is not None for v in srv.values()) else None


# ---- discovery -------------------------------------------------------------
DEFAULT_PROFILE = "default-get"


def _index(results_dir, pattern):
    """Every matching result file under results_dir, at any depth.

    Each perf-test run writes its own `results/<scenario>-DDMMYYHHMMSS/`
    directory, so the files for one scenario are spread across as many
    directories as there have been runs. Searching recursively is what lets the
    medians span repeats: point --results at results/ for every run of a
    scenario, or at one run directory for that session alone. Loose files
    written before run directories existed still sit at the top level and are
    picked up by the same walk.
    """
    out = []
    for path in glob.glob(os.path.join(results_dir, "**", pattern), recursive=True):
        parts = os.path.basename(path).rsplit(".", 1)[0].split("__")
        if len(parts) >= 3:
            out.append((parts, path))
    return sorted(out, key=lambda e: (e[0][-1], e[1]))  # by timestamp, then path


def result_files(results_dir):
    """(group, tag, stamp, path) for every fortio result."""
    return [(p[0], p[1], p[-1], path) for p, path in _index(results_dir, "*.json")]


def groups_in(results_dir):
    """Result groups present: `<scenario>` or `<scenario>+<load-profile>`."""
    return sorted({group for group, _, _, _ in result_files(results_dir)})


def scenarios_in(results_dir):
    """Scenarios present. One report per scenario, covering all its profiles."""
    return sorted({g.partition("+")[0] for g in groups_in(results_dir)})


def profiles_in(results_dir, scenario):
    """Load profiles measured under one scenario, in the order they first ran.

    Run order, not alphabetical: the suite walks a profile set from the
    cheapest request shape to the most expensive, and every chart reads left to
    right in that order. The timestamp is the last `__`-separated field of the
    filename.

    A group with no `+` is a run with no LOAD_PROFILE set, i.e. run.sh's
    built-in shape; it is named so it can sit in the matrix beside the others.
    """
    first_seen = {}
    for group, _, stamp, _ in result_files(results_dir):
        scn, plus, profile = group.partition("+")
        if scn != scenario:
            continue  # 'smoke' must not swallow 'smoke-long'
        name = profile if plus else DEFAULT_PROFILE
        if name not in first_seen or stamp < first_seen[name]:
            first_seen[name] = stamp
    return sorted(first_seen, key=lambda n: (first_seen[n], n))


def group_for(scenario, profile):
    return scenario if profile == DEFAULT_PROFILE else f"{scenario}+{profile}"


# ---- aggregation -----------------------------------------------------------
def metrics_by_tag(results_dir, group):
    """Server summaries for THIS result group only, keyed by tag.

    collect.sh writes `metrics__<group>__<tag>__<ts>.jsonl`. Older files are
    `metrics__<tag>__<ts>.jsonl` and carry no scenario, so there is no way to
    tell which run they belong to; folding them in regardless used to pull one
    scenario's Prometheus window into another scenario's tiles. They are counted
    and skipped instead — a missing tile is recoverable, a wrong one is not.
    """
    mruns = collections.defaultdict(list)  # tag -> [server summary]
    legacy = 0
    for parts, path in _index(results_dir, "metrics__*.jsonl"):
        if len(parts) < 4:  # metrics, group, tag, ts
            legacy += 1
            continue
        if parts[1] != group:
            continue
        s = parse_metrics(path)
        if s:
            mruns[parts[2]].append(s)
    return mruns, legacy


def aggregate(results_dir, group):
    """One result group -> one list of modes (tags), medianed across repeats.

    Repeats are counted across run directories: three invocations of suite.sh
    write three directories, and the median for a tag covers all three.
    """
    fruns = collections.defaultdict(list)  # tag -> [run]
    for g, tag, _, path in result_files(results_dir):
        if g == group:
            fruns[tag].append(parse_run(path))

    mruns, legacy_metrics = metrics_by_tag(results_dir, group)

    # order: baseline first, then by ruleset complexity (minimal < medium < crs), unknown last
    _RULESET_RANK = {"off": 0, "minimal": 1, "medium": 2, "crs": 3}
    def _tag_rank(t):
        suffix = t[len("waf-"):] if t.startswith("waf-") else t
        return _RULESET_RANK.get(suffix, 99)
    tags = sorted(fruns, key=lambda t: (t != BASELINE_TAG, _tag_rank(t), t))
    modes = []
    for tag in tags:
        rs = fruns[tag]
        srv_list = mruns.get(tag)
        modes.append({
            "mode": tag,
            "label": ("WAF off (B0)" if tag == BASELINE_TAG else tag),
            # The template must not infer which row is the baseline from "its
            # deltas are all null" — a WAF run in a scenario with no baseline
            # also has null deltas, and used to be drawn in the B0 slot.
            "is_baseline": tag == BASELINE_TAG,
            "runs": len(rs),
            "pcts": {p: median([r["pcts"][p] for r in rs]) for p in PCTS},
            "avg": median([r["avg"] for r in rs]),
            "qps": median([r["qps"] for r in rs]),
            "err": median([r["err"] for r in rs]),
            "blocked": median([r["blocked"] for r in rs]),
            "conn": next((r["conn"] for r in rs if r["conn"]), None),
            "requested_qps": next((r["requested_qps"] for r in rs if r["requested_qps"]), None),
            "fortio": next((r["fortio"] for r in rs if r.get("fortio")), None),
            "server": _median_server(srv_list) if srv_list else None,
        })

    base = next((m for m in modes if m["mode"] == BASELINE_TAG), None)
    for m in modes:
        if base and m["mode"] != BASELINE_TAG:
            m["delta"] = {p: (m["pcts"][p] - base["pcts"][p])
                          if (m["pcts"][p] is not None and base["pcts"][p] is not None) else None
                          for p in PCTS}
        else:
            m["delta"] = {p: None for p in PCTS}
    return modes, legacy_metrics


def off_target(actual, requested):
    """Observed rate against the rate asked for, or None when within tolerance.

    Per the validity criteria, a shortfall here is a finding on its own and it
    also invalidates that cell's latency comparison: the percentiles describe a
    lighter workload than the baseline they are measured against.
    """
    if not requested or requested <= 0 or actual is None:
        return None
    pct = (actual - requested) / requested * 100.0
    return {"target": requested, "pct": pct} if abs(pct) > QPS_TOLERANCE * 100 else None


def build_cells(results_dir, scenario):
    """All of one scenario's groups as a {(profile, config): cell} grid.

    A cell is what reportlib's builders consume. It is the median across
    repeats, not the latest run: `p50`..`p99_9` keyed the way the charts expect,
    plus the repeat count, the validity flags and any server-side summary.
    """
    profiles = profiles_in(results_dir, scenario)
    cells, configs, legacy, fortio_versions = {}, [], 0, set()

    for profile in profiles:
        modes, legacy_here = aggregate(results_dir, group_for(scenario, profile))
        # Every group sees the same unscoped files, so this is a max, not a sum.
        legacy = max(legacy, legacy_here)
        for m in modes:
            tag = m["mode"]
            config = tag[len("waf-"):] if tag.startswith("waf-") else tag
            if config not in configs:
                configs.append(config)
            p = m["pcts"]
            cells[(profile, config)] = {
                "p50": p["p50"] or 0.0, "p75": p["p75"] or 0.0, "p90": p["p90"] or 0.0,
                "p95": p["p95"] or 0.0, "p99": p["p99"] or 0.0, "p99_9": p["p99.9"] or 0.0,
                "avg": m["avg"] or 0.0,
                "actual_qps": m["qps"] or 0.0,
                "requested_qps": m["requested_qps"],
                "error_pct": m["err"] or 0.0,
                "blocked_pct": m["blocked"] or 0.0,
                "runs": m["runs"],
                "delta": m["delta"],
                "off_target": off_target(m["qps"], m["requested_qps"]),
                "server": m["server"],
                "conn": m["conn"],
            }
            if m.get("fortio"):
                fortio_versions.add(m["fortio"])

    # Baseline first, then by ruleset size; the same order the suite runs them.
    rank = {"off": 0, "minimal": 1, "medium": 2, "crs": 3}
    configs.sort(key=lambda c: (rank.get(c, 99), c))
    return {
        "scenario": scenario,
        "profiles": profiles,
        "configs": configs,
        "cells": cells,
        "legacy_metrics": legacy,
        "fortio": sorted(fortio_versions),
    }


def _median_server(srv_list):
    out = {}
    keys = set().union(*[s.keys() for s in srv_list])
    for k in keys:
        if k == "rps":
            outcomes = set().union(*[(s.get("rps") or {}).keys() for s in srv_list])
            out["rps"] = {o: median([(s.get("rps") or {}).get(o) for s in srv_list]) for o in outcomes} or None
        else:
            out[k] = median([s.get(k) for s in srv_list])
    return out


def _parse_env_fragment(path):
    """Pull KEY="value" and HEADERS=( ... ) out of a sourced bash fragment.

    Deliberately not a shell: these files are flat assignments, and shelling out
    to source them would execute whatever a user put in a custom profile.
    """
    out, headers = {}, []
    try:
        text = open(path).read()
    except OSError:
        return None
    m = re.search(r"HEADERS=\((.*?)\)", text, re.S)
    if m:
        headers = re.findall(r'"([^"]*)"', m.group(1))
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        km = re.match(r'^([A-Z_]+)=(.*)$', line)
        if km and km.group(1) != "HEADERS":
            out[km.group(1)] = km.group(2).strip().strip('"').strip("'")
    out["HEADERS"] = headers
    return out


def parse_scenario(scenarios_dir, name):
    """Load intensity knobs for the scenario behind a result group."""
    env = _parse_env_fragment(os.path.join(scenarios_dir, f"{name}.env"))
    if env is None:
        return {"name": name, "found": False}
    return {
        "name": name, "found": True,
        "qps": env.get("QPS"), "duration": env.get("DURATION"), "conns": env.get("CONNS"),
    }


def parse_load_profile(profiles_dir, name):
    """Request shape for the load profile behind a result group."""
    env = _parse_env_fragment(os.path.join(profiles_dir, f"{name}.env"))
    if env is None:
        return {"name": name, "found": False}
    size = env.get("PAYLOAD_SIZE") or "0"
    method = env.get("METHOD") or ""
    has_body = bool(env.get("PAYLOAD_FILE") or env.get("PAYLOAD")) or size not in ("", "0")
    return {
        "name": name, "found": True,
        # fortio implies POST when a body is set and no method is given
        "method": method or ("POST" if has_body else "GET"),
        "method_implied": not method,
        "path": env.get("REQ_PATH") or "/",
        "content_type": env.get("CONTENT_TYPE") or "",
        "payload_file": env.get("PAYLOAD_FILE") or "",
        "payload_inline": bool(env.get("PAYLOAD")),
        "payload_size": int(size) if size.isdigit() else 0,
        "headers": env.get("HEADERS") or [],
        "expect_status": env.get("EXPECT_STATUS") or "200",
    }


def parse_rulesets(manifests_dir):
    """Read rulesets/*.yaml and return {ruleset_name: {name, rule_count, sources}}."""
    if _yaml is None:
        return {}
    rulesets_dir = os.path.join(manifests_dir, "rulesets")
    result = {}
    for path in sorted(glob.glob(os.path.join(rulesets_dir, "*.yaml"))):
        rs_name = os.path.basename(path).replace(".yaml", "")
        sources = []
        with open(path) as f:
            for doc in _yaml.safe_load_all(f):
                if not doc or doc.get("kind") != "RuleSource":
                    continue
                rules_text = (doc.get("spec") or {}).get("rules", "") or ""
                rule_count = len(re.findall(r"^SecRule\b|^SecAction\b", rules_text, re.MULTILINE))
                sources.append({
                    "name": doc["metadata"]["name"],
                    "rules": rules_text.strip(),
                    "rule_count": rule_count,
                })
        result[rs_name] = {
            "name": rs_name,
            "rule_count": sum(s["rule_count"] for s in sources),
            "sources": sources,
        }
    return result


# ---- cluster facts the results cannot carry --------------------------------
def cluster_facts(fortio_versions):
    """What the report may claim about the cluster it ran on.

    The matrix template used to state OpenShift 4.22.18, Istio v1.27.5 and
    operator v0.5.0 as literals — true of one machine on one day and of nothing
    else. Nothing in results/ records them, so they are read from the
    environment and rendered as "not recorded" when unset. Fortio's version is
    the exception: every result JSON carries it.
    """
    unknown = '<span style="color:#9ca3af">not recorded</span>'
    loadgen = (' / '.join(f'Fortio {v}' for v in fortio_versions)) if fortio_versions else unknown
    return {
        "__PLATFORM__": os.environ.get("PLATFORM") or unknown,
        "__ISTIO_VERSION__": os.environ.get("ISTIO_VERSION") or unknown,
        "__OPERATOR_VERSION__": os.environ.get("OPERATOR_VERSION") or unknown,
        "__NAMESPACE__": os.environ.get("NAMESPACE") or "waf-perf",
        "__LOAD_GENERATOR__": loadgen,
    }


# ---- render ----------------------------------------------------------------
def build(results_dir, scenario, out_path):
    """Render one scenario — every load profile measured under it — to HTML."""
    here = os.path.dirname(os.path.abspath(__file__))
    base_path = pathlib.Path(here).parent

    data = build_cells(results_dir, scenario)
    cells, profiles, configs = data["cells"], data["profiles"], data["configs"]
    if not cells:
        raise SystemExit(f"no runs for scenario '{scenario}' in {results_dir}")

    scn_env = _parse_env_fragment(os.path.join(here, "..", "scenarios", f"{scenario}.env"))
    profile_envs = {
        p: _parse_env_fragment(os.path.join(here, "..", "manifests", "load-profiles", f"{p}.env"))
        for p in profiles
    }

    rule_counts = reportlib.resolve_rule_counts(base_path, configs, reportlib.ruleset_files(configs))

    ruleset_cards, ruleset_data = reportlib.generate_ruleset_cards(base_path, rule_counts, configs)
    complexity_labels = {p: reportlib.complexity_label(p, profile_envs.get(p)) for p in profiles}
    chart_data = reportlib.prepare_chart_data(cells, profiles, configs, rule_counts,
                                              complexity_labels)
    chart_data["rulesets"] = ruleset_data
    chart_data["rulesetTitles"] = {c: reportlib.describe_ruleset(c)["title"] for c in configs}

    def count_list(cfgs):
        values = [str(rule_counts[c]) for c in cfgs]
        return f"{', '.join(values[:-1])}, or {values[-1]}" if len(values) > 1 else (values[0] if values else "0")

    total_cells = len(profiles) * len(configs)
    runs = sum(c["runs"] for c in cells.values())
    duration = (scn_env or {}).get("DURATION") or "?"
    conns = (scn_env or {}).get("CONNS")
    qps = (scn_env or {}).get("QPS")

    fields = {
        "__SCENARIO_NAME__": scenario,
        "__SCENARIO_CARD__": reportlib.generate_scenario_card(base_path, scenario, scn_env),
        "__PROFILE_CARDS__": reportlib.generate_profile_cards(base_path, profiles, profile_envs),
        "__RULESET_CARDS__": ruleset_cards,
        "__TEST_MATRIX_TABLE__": reportlib.generate_test_matrix(cells, profiles, configs),
        "__PERCENTILE_CARDS__": reportlib.generate_percentile_cards(cells, profiles, configs),
        "__PROFILE_TABLES__": reportlib.generate_profile_tables(cells, profiles, configs),
        "__KEY_FINDINGS__": reportlib.generate_key_findings(cells, profiles, configs, rule_counts),
        "__VALIDITY_BANNER__": reportlib.generate_validity_banner(
            scenario, profiles, configs, cells, data["legacy_metrics"]),
        "__SERVER_SECTION__": reportlib.generate_server_section(cells, profiles, configs),
        "__RULE_COUNT_LIST__": count_list(configs),
        "__WAF_RULE_COUNT_LIST__": count_list([c for c in configs if c != "off"]),
        "__TARGET_QPS__": ("unthrottled" if qps == "0" else f"{qps} req/s") if qps else "unknown",
        "__CONNECTIONS__": conns or "unknown",
        "__RUN_SUMMARY__": (f"{len(cells)} of {total_cells} cells measured, "
                            f"{runs} runs total, {duration} each"),
        "__GENERATED_DATE__": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
    }
    fields.update(cluster_facts(data["fortio"]))

    tpl = open(os.path.join(base_path, "templates", "report-template.html")).read()
    html = tpl
    for key, value in fields.items():
        html = html.replace(key, str(value))
    # CRS rule text contains literal "</script" (XSS signatures); embedding it
    # raw would close the <script> tag early and break the page. "<\/" is a
    # valid JSON escape, so the parsed strings are unchanged.
    blob = json.dumps(chart_data).replace("</", "<\\/")
    html = html.replace("/*__DATA__*/null", f"/*__DATA__*/{blob}")

    out = os.path.abspath(out_path)
    open(out, "w").write(html)

    print(f">> wrote {out}")
    print(f"   scenario '{scenario}': {len(profiles)} profile(s) x {len(configs)} ruleset(s), "
          f"{len(cells)}/{total_cells} cells, {runs} runs")
    print(f"   rule counts: " + ", ".join(f"{c}={rule_counts[c]}" for c in configs))

    no_baseline = [p for p in profiles if (p, "off") not in cells]
    if no_baseline:
        print(f"!! no '{BASELINE_TAG}' run for: {', '.join(no_baseline)} — those profiles show "
              f"absolute latency only, with no WAF cost. Capture the baseline in the same "
              f"session (scripts/suite.sh does this) and regenerate.")
    thin = [f"{p}/{c}" for (p, c), cell in sorted(cells.items()) if cell["runs"] < 3]
    if thin:
        print(f"!! fewer than 3 runs in {len(thin)} cell(s): {', '.join(thin)} — indicative only.")
    missed = [f"{p}/{c} ({cell['off_target']['pct']:+.0f}%)"
              for (p, c), cell in sorted(cells.items()) if cell["off_target"]]
    if missed:
        print(f"!! offered load not held: {', '.join(missed)} — those cells' latency "
              f"comparison is invalid.")
    if data["legacy_metrics"]:
        print(f"!! skipped {data['legacy_metrics']} metrics__<tag>__<ts>.jsonl file(s) with no "
              f"scenario in the name. Re-collect with "
              f"scripts/collect.sh <start> <end> <tag> <scenario>.")
    print(f"   file://{out}")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", help="one scenario (default: every scenario in --results)")
    ap.add_argument("--results", default=os.path.join(here, "..", "results"))
    ap.add_argument("--out", help="output file; only valid for a single scenario "
                                  "(default: <results>/<scenario>-report.html)")
    args = ap.parse_args()

    scns = scenarios_in(args.results)
    if not scns:
        raise SystemExit(f"no *.json results in {args.results} — run scripts/suite.sh first")
    # The scenario is in every result filename, so there is nothing to ask for:
    # with no --scenario, report on all of them. One page per scenario, since
    # each is a different load intensity and they never share a baseline.
    if args.scenario:
        if args.scenario not in scns:
            raise SystemExit(f"scenario '{args.scenario}' not found; present: {scns}")
        scenarios = [args.scenario]
    else:
        scenarios = scns
    if args.out and len(scenarios) > 1:
        raise SystemExit(f"--out names one file but {len(scenarios)} scenarios are present "
                         f"{scenarios}; add --scenario <name>, or drop --out to write "
                         f"<results>/<scenario>-report.html")

    for s in scenarios:
        build(args.results, s, args.out or os.path.join(args.results, f"{s}-report.html"))


if __name__ == "__main__":
    main()
