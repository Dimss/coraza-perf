#!/usr/bin/env python3
"""HTML rendering for the performance report: sections, cards, tables, charts.

Every builder here takes `results[(profile, config)]` — one cell per load
profile per ruleset — and returns a fragment for templates/report-template.html.
A cell is produced by scripts/report.py, which medians it across repeats; this
module does no file discovery and no aggregation of its own, so the page can
never disagree with the delta report about what was measured.

Was `generate-report.py`, which took the latest single run per cell and
hardcoded the profile list, the config list and the scenario name. Those now
arrive as arguments.
"""

import json
import re
from pathlib import Path
import html
try:
    import yaml
except ImportError:  # rule counts fall back to FALLBACK_RULE_COUNTS
    yaml = None

# A rule is a SecRule/SecAction directive carrying an id. Chained sub-rules have
# no id of their own and only evaluate when their parent matches, so they are not
# counted; neither are configuration directives (SecRuleEngine, SecRequestBodyAccess)
# or SecMarker jump targets, which cost nothing per request.
RULE_DIRECTIVE_RE = re.compile(r'^(SecRule|SecAction)\b')
RULE_ID_RE = re.compile(r"\bid:\s*'?(\d+)")
LINE_CONTINUATION_RE = re.compile(r'\\\s*\n\s*')

# Used only when a manifest cannot be read; the charts' x-axis depends on these.
FALLBACK_RULE_COUNTS = {'off': 0, 'minimal': 1, 'medium': 30, 'crs': 563}

BASELINE_CONFIG = 'off'

# Cycled when a profile or ruleset is not one of the curated ones below, so a
# report of profiles nobody anticipated still renders.
PROFILE_PALETTE = ['#3b82f6', '#8b5cf6', '#ec4899', '#f59e0b', '#10b981', '#06b6d4']
CONFIG_PALETTE = ['#6b7280', '#3b82f6', '#8b5cf6', '#ef4444', '#f59e0b', '#14b8a6']


def profile_colors(profiles):
    """Stable colour per profile: curated where known, cycled otherwise."""
    curated = {'baseline-get': '#3b82f6', 'args-heavy': '#8b5cf6', 'headers-heavy': '#ec4899'}
    out, i = {}, 0
    for p in profiles:
        if p in curated:
            out[p] = curated[p]
        else:
            out[p] = PROFILE_PALETTE[i % len(PROFILE_PALETTE)]
            i += 1
    return out


def config_colors(configs):
    """Stable colour per WAF config: curated where known, cycled otherwise."""
    curated = {'off': '#6b7280', 'minimal': '#3b82f6', 'medium': '#8b5cf6', 'crs': '#ef4444'}
    out, i = {}, 0
    for c in configs:
        if c in curated:
            out[c] = curated[c]
        else:
            out[c] = CONFIG_PALETTE[i % len(CONFIG_PALETTE)]
            i += 1
    return out


def config_label(config):
    return config.upper() if config == 'crs' else config.capitalize()


def profile_title(profile):
    return profile.replace('-', ' ').title()


def calc_overhead(baseline_ms, waf_ms):
    """Calculate percentage overhead."""
    if baseline_ms == 0:
        return 0
    return ((waf_ms - baseline_ms) / baseline_ms) * 100


def signed_pct(value):
    """'+12%' / '-3%'. The old code hardcoded the '+', so a WAF run that came
    out faster than its baseline — noise — printed as '+-3%'."""
    return f'{value:+.0f}%'


def signed_ms(value):
    return f'{value:+.2f}'

def format_rules(count, title_case=False):
    """Render a rule count with the right plural, e.g. '1 rule' / '563 rules'."""
    noun = 'Rule' if count == 1 else 'Rules'
    return f'{count} {noun}' if title_case else f'{count} {noun.lower()}'


def count_ruleset_rules(manifest_path):
    """Count the rules a ruleset manifest actually loads into the WAF.

    Parses the multi-document YAML, keeps only the RuleSource documents the
    RuleSet references, and counts distinct rule ids across them. Returns None
    if the manifest cannot be read or parsed, so the caller can fall back.
    """
    if yaml is None:
        return None
    try:
        with open(manifest_path) as f:
            docs = list(yaml.safe_load_all(f))
    except (OSError, yaml.YAMLError):
        return None

    sources = {}
    referenced = None

    for doc in docs:
        if not isinstance(doc, dict):
            continue
        spec = doc.get('spec') or {}
        name = (doc.get('metadata') or {}).get('name')

        if doc.get('kind') == 'RuleSource' and name:
            sources[name] = spec.get('rules') or ''
        elif doc.get('kind') == 'RuleSet':
            referenced = [s.get('name') for s in (spec.get('sources') or [])]

    # Without a RuleSet, fall back to every RuleSource in the file.
    names = referenced if referenced is not None else list(sources)

    rule_ids = set()
    for name in names:
        # Join line continuations so each directive is one logical line.
        text = LINE_CONTINUATION_RE.sub(' ', sources.get(name, ''))
        for line in text.splitlines():
            stripped = line.strip()
            if not RULE_DIRECTIVE_RE.match(stripped):
                continue
            match = RULE_ID_RE.search(stripped)
            if match:
                rule_ids.add(match.group(1))

    return len(rule_ids)


def resolve_rule_counts(base_path, configs, ruleset_files):
    """Resolve rule counts per WAF config, parsing manifests where possible."""
    counts = {}

    for config in configs:
        manifest = ruleset_files.get(config)
        if manifest is None:
            counts[config] = 0  # 'off' has no ruleset
            continue

        counted = count_ruleset_rules(base_path / manifest)
        if counted is None:
            counted = FALLBACK_RULE_COUNTS.get(config, 0)
            print(f"   ⚠️  Could not parse {manifest}, using fallback count {counted} for '{config}'")
        counts[config] = counted

    return counts


def load_profile_content(profile_path):
    """Load and parse profile file content."""
    with open(profile_path) as f:
        return f.read()

def format_code_for_modal(content):
    """Format code content for modal display with syntax highlighting."""
    lines = content.split('\n')
    formatted_lines = []

    for line in lines:
        if line.strip().startswith('#'):
            formatted_lines.append(f'<span class="comment">{html.escape(line)}</span>')
        elif '=' in line and not line.strip().startswith('#'):
            parts = line.split('=', 1)
            if len(parts) == 2:
                key = f'<span class="keyword">{html.escape(parts[0])}</span>'
                value = f'<span class="string">{html.escape(parts[1])}</span>'
                formatted_lines.append(f'{key}={value}')
            else:
                formatted_lines.append(html.escape(line))
        else:
            formatted_lines.append(html.escape(line))

    return '\n'.join(formatted_lines)

# Curated copy for the profiles the harness ships. Anything else is described
# from its own .env, so a profile added later still gets a card.
PROFILE_META = {
    'baseline-get': {
        'title': 'Baseline GET',
        'icon': '🎯',
        'description': 'Simple GET / request with no query parameters or custom headers. Represents the WAF\'s best-case scenario.',
        'tags': ['Simple', 'Minimal Data'],
    },
    'args-heavy': {
        'title': 'Args Heavy',
        'icon': '🔢',
        'description': 'GET request with 25 query parameters. Exercises CRS ARGS rules extensively (~165 rules iterate over ARGS).',
        'tags': ['25 Parameters', 'CRS Test'],
    },
    'headers-heavy': {
        'title': 'Headers Heavy',
        'icon': '📋',
        'description': 'GET request with 15 additional HTTP headers. Tests REQUEST_HEADERS inspection rules.',
        'tags': ['15 Headers', 'Header Inspection'],
    },
}


def describe_profile(name, env):
    """Curated metadata for a known profile, else derived from its .env."""
    if name in PROFILE_META:
        return PROFILE_META[name]
    if not env:
        return {'title': profile_title(name), 'icon': '📄',
                'description': f'Load profile {name}. Definition not found in '
                               f'manifests/load-profiles/{name}.env.',
                'tags': ['Unknown shape']}
    args = len([a for a in (env.get('REQ_PATH', '/').split('?', 1) + [''])[1].split('&') if a])
    headers = len(env.get('HEADERS') or [])
    body = env.get('PAYLOAD_FILE') or env.get('PAYLOAD') or (
        f"{env.get('PAYLOAD_SIZE')} bytes" if (env.get('PAYLOAD_SIZE') or '0') != '0' else '')
    method = env.get('METHOD') or ('POST' if body else 'GET')
    bits = [f'{args} query argument{"s" if args != 1 else ""}' if args else 'no query arguments',
            f'{headers} extra header{"s" if headers != 1 else ""}' if headers else 'no extra headers']
    if body:
        bits.append(f'a request body ({body})')
    tags = [t for t in [f'{args} Parameters' if args else None,
                        f'{headers} Headers' if headers else None,
                        'Body' if body else None,
                        f'Expects {env["EXPECT_STATUS"]}' if env.get('EXPECT_STATUS', '200') != '200' else None]
            if t] or ['Simple']
    return {
        'title': profile_title(name),
        'icon': '🧪',
        'description': f'{method} {html.escape(env.get("REQ_PATH", "/").split("?")[0])} with '
                       + ', '.join(bits) + '.',
        'tags': tags,
    }


def profile_shape(env):
    """(query arguments, extra headers, has body) for a load profile's .env."""
    if not env:
        return 0, 0, False
    query = (env.get('REQ_PATH', '/').split('?', 1) + [''])[1]
    args = len([a for a in query.split('&') if a])
    headers = len(env.get('HEADERS') or [])
    body = bool(env.get('PAYLOAD_FILE') or env.get('PAYLOAD')
                or (env.get('PAYLOAD_SIZE') or '0') != '0')
    return args, headers, body


def complexity_label(name, env):
    """Axis label naming what makes a shape expensive, e.g. 'Args Heavy (25 params)'.

    The counts used to be written into the label by hand, so they described the
    author's profiles whatever the report was actually built from.
    """
    args, headers, body = profile_shape(env)
    title = PROFILE_META.get(name, {}).get('title', profile_title(name))
    detail = []
    if args:
        detail.append(f'{args} param{"s" if args != 1 else ""}')
    if headers:
        detail.append(f'{headers} header{"s" if headers != 1 else ""}')
    if body:
        detail.append('body')
    return f'{title} ({", ".join(detail)})' if detail else title


def generate_profile_cards(base_path, profiles, profile_envs=None):
    """Generate HTML cards for the load profiles actually measured."""
    profile_envs = profile_envs or {}

    cards_html = []
    for name in profiles:
        profile = describe_profile(name, profile_envs.get(name))
        # Load profile content
        profile_path = base_path / 'manifests' / 'load-profiles' / f"{name}.env"
        if profile_path.exists():
            content = load_profile_content(profile_path)
            formatted_content = format_code_for_modal(content)
        else:
            formatted_content = "Profile file not found"

        tags_html = ''.join([f'<span class="card-tag">{tag}</span>' for tag in profile['tags']])

        card_html = f'''
                <div class="card" onclick='openModal("{profile["title"]}", `<div class="code-block">{formatted_content}</div>`)'>
                    <div class="card-title">
                        <span class="card-icon">{profile['icon']}</span>
                        {profile['title']}
                    </div>
                    <div class="card-description">{profile['description']}</div>
                    <div class="card-meta">
                        {tags_html}
                    </div>
                </div>
'''
        cards_html.append(card_html)

    return '\n'.join(cards_html)

# Single source of truth for WAF ruleset metadata. Rule counts are parsed from
# the manifests at generation time, so {rules} is filled in by the caller.
RULESETS = [
    {
        'id': 'off',
        'name': 'off',
        'title': 'OFF (No WAF)',
        'icon': '🔓',
        'description': 'No WAF enabled. Traffic flows through Istio/Envoy without WAF filtering. Used as baseline for comparison.',
        'tags': ['{rules_title}', 'Baseline'],
        'file': None
    },
    {
        'id': 'minimal',
        'name': 'minimal',
        'title': 'Minimal',
        'icon': '🛡️',
        'description': 'Simplest WAF configuration with {rules_lower}. Engine initialization plus basic attack keyword blocking.',
        'tags': ['{rules_title}', 'Basic Protection'],
        'file': 'manifests/rulesets/minimal.yaml'
    },
    {
        'id': 'medium',
        'name': 'medium',
        'title': 'Medium',
        'icon': '🔒',
        'description': 'Typical hand-written security policy with {rules_lower} covering common attack patterns.',
        'tags': ['{rules_title}', 'Custom Policy'],
        'file': 'manifests/rulesets/medium.yaml'
    },
    {
        'id': 'crs',
        'name': 'crs',
        'title': 'CRS (CoreRuleSet)',
        'icon': '🛡️',
        'description': 'Full OWASP CoreRuleSet 4.7.0 with {rules_lower}. Industry-standard WAF ruleset.',
        'tags': ['{rules_title}', 'OWASP CRS 4.7.0'],
        'file': 'manifests/rulesets/crs.yaml'
    }
]

RULESET_FILES = {r['id']: r['file'] for r in RULESETS}
RULESET_META = {r['id']: r for r in RULESETS}


def ruleset_files(configs):
    """Manifest path per config: curated where known, conventional otherwise."""
    out = {}
    for c in configs:
        if c in RULESET_FILES:
            out[c] = RULESET_FILES[c]
        else:
            out[c] = f'manifests/rulesets/{c}.yaml'
    return out


def describe_ruleset(config):
    """Curated metadata for a shipped ruleset, else a generic descriptor."""
    if config in RULESET_META:
        return RULESET_META[config]
    return {
        'id': config,
        'name': config,
        'title': config_label(config),
        'icon': '📜',
        'description': 'Ruleset {name} with {rules_lower}, read from '
                       'manifests/rulesets/{name}.yaml.'.replace('{name}', config),
        'tags': ['{rules_title}', 'Custom'],
        'file': f'manifests/rulesets/{config}.yaml',
    }


def generate_ruleset_cards(base_path, rule_counts, configs):
    """Generate HTML cards for the WAF rulesets actually measured.

    Returns:
        tuple: (cards_html, ruleset_data_dict) where ruleset_data_dict contains
               the ruleset content to be injected into JavaScript
    """
    cards_html = []
    ruleset_data = {}

    for config in configs:
        ruleset = describe_ruleset(config)
        rules = rule_counts.get(ruleset['id'], 0)
        fmt = {
            'rules': rules,
            'rules_lower': format_rules(rules),
            'rules_title': format_rules(rules, title_case=True)
        }
        description = ruleset['description'].format(**fmt)
        tags = [tag.format(**fmt) for tag in ruleset['tags']]

        # Load ruleset content
        if ruleset['file']:
            ruleset_path = base_path / ruleset['file']
            if ruleset_path.exists():
                content = load_profile_content(ruleset_path)
                # Store the escaped content
                ruleset_data[ruleset['id']] = html.escape(content)
            else:
                ruleset_data[ruleset['id']] = "Ruleset file not found"
        else:
            # OFF configuration has no file
            ruleset_data[ruleset['id']] = (
                "# No WAF Configuration\n"
                "# Traffic flows through Istio/Envoy without WAF filtering\n"
                "# Used as baseline measurement for comparison\n\n"
                "Engine: Not deployed\n"
                "Rules: 0\n"
                "Overhead: 0% (baseline)"
            )

        tags_html = ''.join([f'<span class="card-tag">{tag}</span>' for tag in tags])

        # Use data-ruleset-id instead of inline content
        card_html = f'''
                <div class="card" onclick='openRulesetModal("{ruleset["id"]}")'>
                    <div class="card-title">
                        <span class="card-icon">{ruleset['icon']}</span>
                        {ruleset['title']}
                    </div>
                    <div class="card-description">{description}</div>
                    <div class="card-meta">
                        {tags_html}
                    </div>
                </div>
'''
        cards_html.append(card_html)

    return '\n'.join(cards_html), ruleset_data

def generate_scenario_card(base_path, scenario, env):
    """Generate HTML card for the scenario these results were measured under.

    Reads the scenario's own .env. It used to open `fixed-500qps-short.env`
    whatever had been run, and state 500 qps / 16 connections / 60 seconds as
    literals in the card body — three numbers that silently described a
    different run than the one being reported.
    """
    scenario_path = base_path / 'scenarios' / f'{scenario}.env'

    if scenario_path.exists():
        content = load_profile_content(scenario_path)
        formatted_content = format_code_for_modal(content)
    else:
        formatted_content = f"Scenario file not found: scenarios/{scenario}.env"

    env = env or {}
    qps, duration, conns = env.get('QPS'), env.get('DURATION'), env.get('CONNS')
    rate = 'unthrottled (max throughput)' if qps == '0' else (f'{qps} req/s' if qps else 'unknown')
    rate_tag = 'Unthrottled' if qps == '0' else (f'{qps} QPS' if qps else 'Rate unknown')

    if qps and duration and conns:
        description = (f'Sends {"as many requests as it can" if qps == "0" else f"a constant {qps} requests per second"} '
                       f'for {duration} using {conns} concurrent connections.')
    else:
        description = (f'Load intensity for {scenario}. Definition not found in '
                       f'scenarios/{scenario}.env, so the figures below are the ones '
                       f'fortio reported, not the ones that were asked for.')

    meta = ''.join(
        f'<div class="meta-item"><div class="meta-label">{label}</div>'
        f'<div class="meta-value">{value}</div></div>'
        for label, value in [('QPS Target', rate),
                             ('Connections', conns or 'unknown'),
                             ('Duration', duration or 'unknown')])

    tags = ''.join(f'<span class="card-tag">{t}</span>' for t in
                   [rate_tag,
                    f'{conns} Connections' if conns else 'Connections unknown',
                    f'{duration} Duration' if duration else 'Duration unknown'])

    card_html = f'''
                <div class="card" onclick='openModal("Test Scenario: {scenario}", `<div class="code-block">{formatted_content}</div><div style="margin-top: 1.5rem;"><h4 style="color: #374151; margin-bottom: 0.75rem;">Configuration</h4><div class="meta-grid">{meta}</div></div>`)'>
                    <div class="card-title">
                        <span class="card-icon">⚡</span>
                        {scenario}
                    </div>
                    <div class="card-description">
                        {description}
                    </div>
                    <div class="card-meta">
                        {tags}
                    </div>
                </div>
'''

    return card_html

def generate_test_matrix(results, profiles, configs):
    """Generate test matrix table showing all test permutations."""

    num_configs = len(configs)

    table_html = f'''
                <table class="matrix-table">
                    <thead>
                        <tr>
                            <th rowspan="2" style="vertical-align: middle;">Load Profiles</th>
                            <th colspan="{num_configs}" style="background: linear-gradient(135deg, #ec4899 0%, #db2777 100%);">WAF Rulesets</th>
                        </tr>
                        <tr>
'''

    # Second header row with individual ruleset names
    for config in configs:
        table_html += f'                            <th>{config_label(config)}</th>\n'

    table_html += '''                        </tr>
                    </thead>
                    <tbody>
'''

    # Row for each profile
    for profile in profiles:
        table_html += f'                        <tr>\n'
        table_html += f'                            <td>{profile_title(profile)}</td>\n'

        for config in configs:
            key = (profile, config)
            if key in results:
                # Completed, plus how many repeats the cell's median covers.
                # One run is not a data point (README, "Methodology"), and a
                # bare tick cannot tell you which cells are only indicative.
                runs = results[key].get('runs', 1)
                repeats = f'{runs} run{"s" if runs != 1 else ""}'
                caution = '' if runs >= 3 else ' style="color:#b45309"'
                status_html = f'''
                            <td>
                                <div class="matrix-cell">
                                    <div class="matrix-status completed">✓</div>
                                    <div class="matrix-metrics"{caution}>{repeats}</div>
                                </div>
                            </td>
'''
            else:
                # Test missing
                status_html = '''
                            <td>
                                <div class="matrix-cell">
                                    <div class="matrix-status missing">✗</div>
                                </div>
                            </td>
'''
            table_html += status_html

        table_html += '                        </tr>\n'

    table_html += '''                    </tbody>
                </table>
'''

    return table_html

def generate_percentile_cards(results, profiles, configs):
    """Generate percentile comparison cards (P50, P95, P99)."""
    percentiles = ['p50', 'p95', 'p99']

    cards_html = []

    for pct in percentiles:
        pct_display = pct.upper()

        card_html = f'''
            <div class="percentile-card">
                <div class="percentile-card-header">
                    <div class="percentile-badge">{pct_display}</div>
                    <div class="percentile-title">Latency comparison across all load profiles</div>
                </div>
                <div class="comparison-grid">
'''

        for profile in profiles:
            baseline_value = results.get((profile, BASELINE_CONFIG), {}).get(pct, 0)

            card_html += f'''
                    <div class="profile-comparison">
                        <div class="profile-name">{profile_title(profile)}</div>
                        <div class="waf-configs">
'''

            for config in configs:
                key = (profile, config)
                if key in results:
                    value = results[key].get(pct, 0)

                    # Calculate overhead
                    if config == BASELINE_CONFIG:
                        overhead_text = 'baseline'
                        overhead_class = 'baseline'
                    elif baseline_value > 0:
                        overhead_pct = calc_overhead(baseline_value, value)
                        overhead_text = signed_pct(overhead_pct)

                        if overhead_pct < 20:
                            overhead_class = 'low'
                        elif overhead_pct < 100:
                            overhead_class = 'medium'
                        else:
                            overhead_class = 'high'
                    else:
                        # No waf-off cell for this profile: there is no cost to
                        # state, and 0 would read as "the WAF was free".
                        overhead_text = 'no baseline'
                        overhead_class = 'baseline'

                    card_html += f'''
                            <div class="waf-config-item">
                                <div class="config-name">{config}</div>
                                <div class="config-value">{value:.2f}ms</div>
                                <div class="config-overhead">{overhead_text}</div>
                            </div>
'''
                else:
                    card_html += f'''
                            <div class="waf-config-item">
                                <div class="config-name">{config}</div>
                                <div class="config-value">—</div>
                                <div class="config-overhead baseline">missing</div>
                            </div>
'''

            card_html += '''
                        </div>
                    </div>
'''

        card_html += '''
                </div>
            </div>
'''

        cards_html.append(card_html)

    return '\n'.join(cards_html)

def generate_profile_tables(results, profiles, configs):
    """Generate HTML tables for each profile.

    Columns carry what the methodology needs to judge a number: the repeat
    count behind each median, the added milliseconds as well as the percentage,
    and the observed rate flagged when it missed what was asked for.
    """
    html_parts = []

    for profile in profiles:
        baseline = results.get((profile, BASELINE_CONFIG))
        baseline_p50 = (baseline or {}).get('p50', 0)

        table_html = f'''
            <div style="margin-top: 3rem;">
                <h3 style="margin-bottom: 1rem; color: #374151;">Load Profile: {profile_title(profile)}</h3>
                <table>
                    <thead>
                        <tr>
                            <th>WAF Config</th>
                            <th>Runs</th>
                            <th>p50 (ms)</th>
                            <th>p95 (ms)</th>
                            <th>p99 (ms)</th>
                            <th>Actual QPS</th>
                            <th>Errors</th>
                            <th>Overhead vs OFF (p50)</th>
                        </tr>
                    </thead>
                    <tbody>
'''

        for config in configs:
            key = (profile, config)
            if key in results:
                r = results[key]
                overhead = ""
                overhead_class = ""

                if config != BASELINE_CONFIG and baseline_p50 > 0:
                    ovh_pct = calc_overhead(baseline_p50, r['p50'])
                    overhead = f"{signed_pct(ovh_pct)} ({signed_ms(r['p50'] - baseline_p50)} ms)"

                    if ovh_pct < 20:
                        overhead_class = "low"
                    elif ovh_pct < 100:
                        overhead_class = "medium"
                elif config != BASELINE_CONFIG:
                    overhead = "no baseline"

                runs = r.get('runs', 1)
                runs_cell = (f'{runs}' if runs >= 3
                             else f'<span style="color:#b45309" title="Fewer than 3 repeats; '
                                  f'one run is noise">{runs}</span>')

                off = r.get('off_target')
                qps_cell = (f"{r['actual_qps']:.1f}" if not off else
                            f'<span style="color:#b45309" title="requested '
                            f'{off["target"]:.0f} qps">{r["actual_qps"]:.1f} '
                            f'({signed_pct(off["pct"])})</span>')

                err = r.get('error_pct', 0.0)
                err_cell = (f'{err:.2f}%' if err <= 0 else
                            f'<span style="color:#dc2626">{err:.2f}%</span>')
                blocked = r.get('blocked_pct', 0.0)
                if blocked:
                    err_cell += f'<br><span style="color:#6b7280;font-size:0.8em">{blocked:.1f}% blocked</span>'

                table_html += f'''
                        <tr>
                            <td class="metric">{config}</td>
                            <td>{runs_cell}</td>
                            <td>{r['p50']:.2f}</td>
                            <td>{r['p95']:.2f}</td>
                            <td>{r['p99']:.2f}</td>
                            <td>{qps_cell}</td>
                            <td>{err_cell}</td>
                            <td class="overhead {overhead_class}">{overhead}</td>
                        </tr>
'''
            else:
                table_html += f'''
                        <tr>
                            <td class="metric">{config}</td>
                            <td colspan="7" style="text-align: center; color: #dc2626;">MISSING</td>
                        </tr>
'''

        table_html += '''
                    </tbody>
                </table>
            </div>
'''
        html_parts.append(table_html)

    return '\n'.join(html_parts)

def prepare_chart_data(results, profiles, configs, rule_counts, profile_labels=None):
    """Prepare Chart.js configuration objects."""

    # Latency chart data. Colours are looked up, not indexed by a fixed list:
    # the profiles are whatever was measured, not a known set of three.
    pcolor = profile_colors(profiles)
    ccolor = config_colors(configs)
    profile_labels = profile_labels or {p: profile_title(p) for p in profiles}

    latency_datasets = []
    for profile in profiles:
        colors = {'p50': pcolor[profile]}
        p50_data = []

        for config in configs:
            key = (profile, config)
            if key in results:
                p50_data.append(results[key]['p50'])
            else:
                p50_data.append(None)

        latency_datasets.append({
            'label': f'{profile} (p50)',
            'data': p50_data,
            'backgroundColor': colors['p50'] + '80',
            'borderColor': colors['p50'],
            'borderWidth': 2
        })

    latency_chart = {
        'type': 'bar',
        'data': {
            'labels': configs,
            'datasets': latency_datasets
        },
        'options': {
            'responsive': True,
            'maintainAspectRatio': False,
            'plugins': {
                'title': {
                    'display': True,
                    'text': 'p50 Latency Comparison (ms)',
                    'font': {'size': 16}
                },
                'legend': {
                    'position': 'top',
                }
            },
            'scales': {
                'y': {
                    'beginAtZero': True,
                    'title': {
                        'display': True,
                        'text': 'Latency (ms)'
                    }
                },
                'x': {
                    'title': {
                        'display': True,
                        'text': 'WAF Configuration'
                    }
                }
            }
        }
    }

    # Overhead chart data. The heaviest ruleset measured is the headline, which
    # is 'crs' in the shipped set but is resolved by rule count so a report that
    # did not run CRS still charts something true.
    waf_by_size = sorted((c for c in configs if c != BASELINE_CONFIG),
                         key=lambda c: rule_counts.get(c, 0))
    headline = waf_by_size[-1] if waf_by_size else None
    overhead_data = []
    for profile in profiles:
        baseline_p50 = results.get((profile, BASELINE_CONFIG), {}).get('p50', 0)
        headline_p50 = results.get((profile, headline), {}).get('p50', 0) if headline else 0
        if baseline_p50 > 0 and headline_p50 > 0:
            overhead_pct = calc_overhead(baseline_p50, headline_p50)
            overhead_data.append(overhead_pct)
        else:
            overhead_data.append(None)

    overhead_cycle = ['rgb(220, 38, 38)', 'rgb(245, 158, 11)', 'rgb(5, 150, 105)',
                      'rgb(37, 99, 235)', 'rgb(124, 58, 237)', 'rgb(13, 148, 136)']
    overhead_borders = [overhead_cycle[i % len(overhead_cycle)] for i in range(len(profiles))]

    overhead_chart = {
        'type': 'bar',
        'data': {
            'labels': [profile_title(p) for p in profiles],
            'datasets': [{
                'label': f'{config_label(headline) if headline else "WAF"} Overhead (%)',
                'data': overhead_data,
                'backgroundColor': [c.replace('rgb(', 'rgba(').replace(')', ', 0.7)')
                                    for c in overhead_borders],
                'borderColor': overhead_borders,
                'borderWidth': 2
            }]
        },
        'options': {
            'responsive': True,
            'maintainAspectRatio': False,
            'plugins': {
                'title': {
                    'display': True,
                    'text': (f"{config_label(headline)} ({rule_counts.get(headline, 0)} rules) "
                             f"Overhead vs Baseline by Load Profile" if headline
                             else "WAF Overhead vs Baseline by Load Profile"),
                    'font': {'size': 16}
                },
                'legend': {
                    'display': False
                }
            },
            'scales': {
                'y': {
                    'beginAtZero': True,
                    'title': {
                        'display': True,
                        'text': 'Overhead (%)'
                    }
                },
                'x': {
                    'title': {
                        'display': True,
                        'text': 'Load Profile'
                    }
                }
            }
        }
    }

    # 1. Latency Distribution Chart (showing multiple percentiles)
    percentile_datasets = []
    percentiles = ['p50', 'p75', 'p90', 'p95', 'p99']
    percentile_colors = {
        'p50': '#10b981',
        'p75': '#3b82f6',
        'p90': '#8b5cf6',
        'p95': '#f59e0b',
        'p99': '#ef4444'
    }

    for profile in profiles:
        for pct in percentiles:
            data = []
            for config in configs:
                key = (profile, config)
                if key in results:
                    data.append(results[key].get(pct, 0))
                else:
                    data.append(None)

            percentile_datasets.append({
                'label': f'{profile} - {pct}',
                'data': data,
                'backgroundColor': percentile_colors[pct] + '80',
                'borderColor': percentile_colors[pct],
                'borderWidth': 2,
                'stack': profile
            })

    latency_distribution_chart = {
        'type': 'bar',
        'data': {
            'labels': [config_label(c) for c in configs],
            'datasets': percentile_datasets
        },
        'options': {
            'responsive': True,
            'maintainAspectRatio': False,
            'plugins': {
                'title': {
                    'display': True,
                    'text': 'Latency Distribution Across Percentiles',
                    'font': {'size': 16, 'weight': 'bold'}
                },
                'legend': {
                    'position': 'right',
                    'labels': {'font': {'size': 10}}
                }
            },
            'scales': {
                'y': {
                    'beginAtZero': True,
                    'stacked': False,
                    'title': {
                        'display': True,
                        'text': 'Latency (ms)'
                    }
                },
                'x': {
                    'title': {
                        'display': True,
                        'text': 'WAF Configuration'
                    }
                }
            }
        }
    }

    # 2. Request Complexity Scaling (Line Chart)
    complexity_datasets = []

    for config in configs:
        data = []
        for profile in profiles:
            key = (profile, config)
            if key in results:
                data.append(results[key]['p50'])
            else:
                data.append(None)

        complexity_datasets.append({
            'label': config_label(config),
            'data': data,
            'borderColor': ccolor[config],
            'backgroundColor': ccolor[config] + '40',
            'borderWidth': 3,
            'tension': 0.3,
            'fill': False,
            'pointRadius': 6,
            'pointHoverRadius': 8
        })

    complexity_scaling_chart = {
        'type': 'line',
        'data': {
            # Was a literal three-item list, so a fourth profile went unlabelled
            # and a different three were labelled as the author's.
            'labels': [profile_labels.get(p, profile_title(p)) for p in profiles],
            'datasets': complexity_datasets
        },
        'options': {
            'responsive': True,
            'maintainAspectRatio': False,
            'plugins': {
                'title': {
                    'display': True,
                    'text': 'Request Complexity Impact on Latency (p50)',
                    'font': {'size': 16, 'weight': 'bold'}
                },
                # Was 'Notice: CRS gets FASTER with more complex requests!' —
                # a reading of one cluster's run, printed over every dataset
                # including ones that show the opposite.
                'subtitle': {
                    'display': True,
                    'text': 'p50 per ruleset across request shapes. Profiles are in run order, '
                            'not sorted by complexity.',
                    'font': {'size': 12, 'style': 'italic'},
                    'color': '#6b7280'
                },
                'legend': {
                    'position': 'top'
                }
            },
            'scales': {
                'y': {
                    'beginAtZero': True,
                    'title': {
                        'display': True,
                        'text': 'p50 Latency (ms)'
                    }
                },
                'x': {
                    'title': {
                        'display': True,
                        'text': 'Request Complexity'
                    }
                }
            }
        }
    }

    # 3. Rules Efficiency: marginal cost of each additional rule.
    #
    # Total overhead is roughly `fixed + marginal * rules`, where `fixed` is the
    # per-request cost of turning the WAF on at all (WASM VM entry, transaction
    # setup, variable population). Dividing total overhead by rule count buries
    # that fixed term in the result and makes small rulesets look inefficient
    # purely because the denominator is small. Differencing adjacent rulesets
    # cancels the fixed term and leaves the real per-rule cost.
    ruleset_rules = rule_counts

    waf_configs = sorted(
        (c for c in configs if c != BASELINE_CONFIG and ruleset_rules.get(c, 0) > 0),
        key=lambda c: ruleset_rules[c]
    )
    segments = list(zip(waf_configs, waf_configs[1:]))
    segment_labels = [f'{ruleset_rules[lo]} → {ruleset_rules[hi]} rules' for lo, hi in segments]

    marginal_datasets = []
    fixed_costs = []

    for profile in profiles:
        marginal_data = []
        for lo, hi in segments:
            lo_key, hi_key = (profile, lo), (profile, hi)
            if lo_key in results and hi_key in results:
                delta_ms = results[hi_key]['p50'] - results[lo_key]['p50']
                delta_rules = ruleset_rules[hi] - ruleset_rules[lo]
                marginal_data.append(delta_ms / delta_rules if delta_rules else None)
            else:
                marginal_data.append(None)

        marginal_datasets.append({
            'label': profile_title(profile),
            'data': marginal_data,
            'backgroundColor': pcolor[profile] + '80',
            'borderColor': pcolor[profile],
            'borderWidth': 2
        })

        # Fixed cost of enabling the WAF, reported separately because it is not
        # attributable to any individual rule.
        off_key = (profile, BASELINE_CONFIG)
        first_key = (profile, waf_configs[0]) if waf_configs else None
        if first_key and off_key in results and first_key in results:
            fixed_costs.append(results[first_key]['p50'] - results[off_key]['p50'])

    if fixed_costs:
        fixed_note = (
            f'Fixed cost of enabling the WAF is excluded '
            f'({min(fixed_costs):.2f}-{max(fixed_costs):.2f} ms, off → {waf_configs[0]}).'
        )
    else:
        fixed_note = 'Marginal p50 cost of each additional rule.'

    rules_efficiency_chart = {
        'type': 'bar',
        'data': {
            'labels': segment_labels,
            'datasets': marginal_datasets
        },
        'options': {
            'responsive': True,
            'maintainAspectRatio': False,
            'plugins': {
                'title': {
                    'display': True,
                    'text': 'Marginal Cost per Added Rule (p50)',
                    'font': {'size': 16, 'weight': 'bold'}
                },
                'subtitle': {
                    'display': True,
                    'text': fixed_note,
                    'font': {'size': 12}
                },
                'legend': {
                    'position': 'top'
                }
            },
            'scales': {
                'y': {
                    'beginAtZero': True,
                    'title': {
                        'display': True,
                        'text': 'Marginal Latency per Rule (ms)'
                    }
                },
                'x': {
                    'title': {
                        'display': True,
                        'text': 'Ruleset Growth Step'
                    }
                }
            }
        }
    }

    # 4. Tail Latency Ratio Bar Chart.
    #
    # p99 - p50 in milliseconds conflates dispersion with absolute slowness: a
    # config is penalised for being slow even when its distribution is just as
    # tight as the baseline's. The ratio is scale-free, so it isolates
    # predictability from magnitude (which the latency and overhead charts
    # already cover).
    tail_ratio_data = []
    tail_labels = []
    tail_colors = []

    for profile in profiles:
        for config in configs:
            key = (profile, config)
            if key in results:
                p50 = results[key]['p50']
                p99 = results[key]['p99']
                ratio = p99 / p50 if p50 > 0 else 0

                # Chart.js renders an array label as one line per element.
                tail_labels.append([profile, config])
                tail_ratio_data.append(ratio)

                # Thresholds are on dispersion, not on absolute latency.
                if ratio < 2:
                    tail_colors.append('#10b981')  # Green
                elif ratio < 3:
                    tail_colors.append('#f59e0b')  # Orange
                else:
                    tail_colors.append('#ef4444')  # Red

    tail_ratio_chart = {
        'type': 'bar',
        'data': {
            'labels': tail_labels,
            'datasets': [{
                'label': 'p99 / p50 Ratio',
                'data': tail_ratio_data,
                'backgroundColor': tail_colors,
                'borderColor': tail_colors,
                'borderWidth': 2
            }]
        },
        'options': {
            'responsive': True,
            'maintainAspectRatio': False,
            'plugins': {
                'title': {
                    'display': True,
                    'text': 'Tail Latency Ratio (p99 / p50)',
                    'font': {'size': 16, 'weight': 'bold'}
                },
                'subtitle': {
                    'display': True,
                    'text': 'Scale-free spread, independent of absolute latency. '
                            'Lower = more predictable. Green < 2x, Orange < 3x, Red ≥ 3x',
                    'font': {'size': 11}
                },
                'legend': {
                    'display': False
                }
            },
            'scales': {
                'y': {
                    'beginAtZero': True,
                    'title': {
                        'display': True,
                        'text': 'p99 / p50 (x)'
                    }
                },
                'x': {
                    'title': {
                        'display': True,
                        'text': 'Profile + Configuration'
                    },
                    'ticks': {
                        'font': {'size': 10}
                    }
                }
            }
        }
    }

    # 5. Latency Heatmap (implemented as a matrix using background colors in HTML table)
    # We'll pass the data and let the HTML/JS handle rendering
    heatmap_data = []
    for profile in profiles:
        row = {'profile': profile_title(profile)}
        for config in configs:
            key = (profile, config)
            if key in results:
                row[config] = results[key]['p95']
            else:
                row[config] = None
        heatmap_data.append(row)

    return {
        # The heatmap's columns and the modal's titles used to be a hardcoded
        # ['off','minimal','medium','crs'] in the template's JavaScript.
        'configs': list(configs),
        'configLabels': {c: config_label(c) for c in configs},
        'latencyChart': latency_chart,
        'overheadChart': overhead_chart,
        'latencyDistributionChart': latency_distribution_chart,
        'complexityScalingChart': complexity_scaling_chart,
        'rulesEfficiencyChart': rules_efficiency_chart,
        'tailRatioChart': tail_ratio_chart,
        'heatmapData': heatmap_data
    }

def generate_key_findings(results, profiles, configs, rule_counts):
    """Generate key findings dynamically from test results."""
    if not results:
        return '''
            <div class="findings">
                <h3>⚠️ No Results Available</h3>
                <p>No test results were found. Run performance tests to generate findings.</p>
            </div>
        '''

    findings = []

    # Calculate CRS overhead range across profiles (using p95)
    crs_overheads = []
    baseline_latencies = []
    crs_latencies = []

    for profile in profiles:
        baseline_key = (profile, BASELINE_CONFIG)
        crs_key = (profile, 'crs')

        if baseline_key in results and crs_key in results:
            baseline_p95 = results[baseline_key]['p95']
            crs_p95 = results[crs_key]['p95']

            if baseline_p95 > 0:
                overhead = ((crs_p95 - baseline_p95) / baseline_p95) * 100
                crs_overheads.append(overhead)
                baseline_latencies.append(baseline_p95)
                crs_latencies.append(crs_p95)

    if crs_overheads:
        min_overhead = min(crs_overheads)
        max_overhead = max(crs_overheads)
        avg_overhead = sum(crs_overheads) / len(crs_overheads)

        findings.append(
            f'<li><strong>CRS Overhead Range:</strong> OWASP CoreRuleSet overhead varies from '
            f'+{min_overhead:.0f}% to +{max_overhead:.0f}% (avg: +{avg_overhead:.0f}%) across '
            f'different request profiles at p95. Overhead is highly dependent on request complexity.</li>'
        )

    # Baseline performance range
    if baseline_latencies:
        min_baseline = min(baseline_latencies)
        max_baseline = max(baseline_latencies)
        findings.append(
            f'<li><strong>Baseline Performance:</strong> Without WAF, latency ranges from '
            f'{min_baseline:.2f}ms to {max_baseline:.2f}ms at p95 across different load profiles.</li>'
        )

    # CRS absolute latency
    if crs_latencies:
        min_crs = min(crs_latencies)
        max_crs = max(crs_latencies)
        findings.append(
            f'<li><strong>CRS Latency Impact:</strong> With {rule_counts.get("crs", 0)} OWASP CoreRuleSet rules, '
            f'latency ranges from {min_crs:.2f}ms to {max_crs:.2f}ms at p95. '
            f'Absolute overhead is {min_crs - min(baseline_latencies):.2f}ms to '
            f'{max_crs - max(baseline_latencies):.2f}ms.</li>'
        )

    # Compare ruleset sizes if data available
    minimal_overheads = []
    medium_overheads = []

    for profile in profiles:
        baseline_key = (profile, BASELINE_CONFIG)
        minimal_key = (profile, 'minimal')
        medium_key = (profile, 'medium')

        if baseline_key in results:
            baseline_p95 = results[baseline_key]['p95']

            if minimal_key in results and baseline_p95 > 0:
                minimal_p95 = results[minimal_key]['p95']
                overhead = ((minimal_p95 - baseline_p95) / baseline_p95) * 100
                minimal_overheads.append(overhead)

            if medium_key in results and baseline_p95 > 0:
                medium_p95 = results[medium_key]['p95']
                overhead = ((medium_p95 - baseline_p95) / baseline_p95) * 100
                medium_overheads.append(overhead)

    if minimal_overheads and medium_overheads:
        avg_minimal = sum(minimal_overheads) / len(minimal_overheads)
        avg_medium = sum(medium_overheads) / len(medium_overheads)

        findings.append(
            f'<li><strong>Custom Rulesets:</strong> Minimal ruleset '
            f'({format_rules(rule_counts.get("minimal", 0))}) adds avg +{avg_minimal:.0f}% overhead, '
            f'while medium ruleset ({format_rules(rule_counts.get("medium", 0))}) adds '
            f'avg +{avg_medium:.0f}% overhead at p95.</li>'
        )

    # Repeats behind the medians. One run per cell is not reportable, and the
    # page should say so rather than let the reader assume otherwise.
    run_counts = [c.get('runs', 1) for c in results.values()]
    if run_counts and min(run_counts) < 3:
        thin = sum(1 for n in run_counts if n < 3)
        findings.append(
            f'<li><strong>⚠️ Repeats:</strong> {thin} of {len(run_counts)} cells rest on fewer '
            f'than 3 runs (range {min(run_counts)}–{max(run_counts)}). The methodology asks for '
            f'at least 3 per data point; treat thin cells as indicative, not reportable.</li>'
        )
    elif run_counts:
        findings.append(
            f'<li><strong>✅ Repeats:</strong> every cell is the median of at least '
            f'{min(run_counts)} runs.</li>'
        )

    # Offered load actually held. A cell that fell short describes a lighter
    # workload than the baseline it is compared against.
    missed = [(p, c) for (p, c), d in results.items() if d.get('off_target')]
    if missed:
        named = ', '.join(f'{profile_title(p)}/{c}' for p, c in sorted(missed))
        findings.append(
            f'<li><strong>⚠️ Offered Load Not Held:</strong> {named} missed the requested rate '
            f'by more than 5%. That is a finding in itself, but it also invalidates those cells\' '
            f'latency comparison — the percentiles describe a lighter workload than the baseline.</li>'
        )

    # Error rates. This used to read a key no cell ever carried
    # (`error_rate`), so it reported a zero error rate unconditionally.
    errored = [(p, c) for (p, c), d in results.items() if d.get('error_pct', 0) > 0]
    if errored:
        named = ', '.join(f'{profile_title(p)}/{c} {results[(p, c)]["error_pct"]:.2f}%'
                          for p, c in sorted(errored))
        findings.append(
            f'<li><strong>⚠️ Error Rates Detected:</strong> {named}. A valid run has '
            f'<code>error_pct</code> 0; 403s from a blocking profile are counted separately as '
            f'blocked, not as errors.</li>'
        )
    else:
        findings.append(
            '<li><strong>✅ Zero Error Rate:</strong> every cell completed with 0% errors '
            '(403 responses on blocking profiles are counted as blocked, not failed).</li>'
        )

    if not findings:
        findings.append(
            '<li><strong>Insufficient Data:</strong> Not enough test results to generate meaningful findings. '
            'Run complete test suite for comprehensive analysis.</li>'
        )

    findings_html = '\n'.join(['                    ' + f for f in findings])

    return f'''
            <div class="findings">
                <h3>🔍 Performance Insights</h3>
                <p><em>The following findings are dynamically generated from the test results in this report:</em></p>
                <ul>
{findings_html}
                </ul>
            </div>
'''


def generate_validity_banner(scenario, profiles, configs, results, legacy_metrics=0):
    """Banner over the report stating what would make it unreportable.

    The page is generated either way; what it must not do is look complete when
    the baseline is missing, the offered load was not held, or every median
    rests on a single run.
    """
    problems = []

    no_baseline = [p for p in profiles if (p, BASELINE_CONFIG) not in results]
    if no_baseline:
        named = ', '.join(profile_title(p) for p in no_baseline)
        problems.append(
            f'<li><strong>No <code>waf-{BASELINE_CONFIG}</code> run for {named}.</strong> '
            f'Those rows are absolute latency, which is a property of the cluster and does not '
            f'travel. Capture the baseline in the same session, before the WAF-on runs '
            f'(<code>scripts/suite.sh</code> does this), and regenerate.</li>')

    missed = [(p, c) for (p, c), d in results.items() if d.get('off_target')]
    if missed:
        named = ', '.join(f'{profile_title(p)}/{c} ({signed_pct(results[(p, c)]["off_target"]["pct"])})'
                          for p, c in sorted(missed))
        problems.append(
            f'<li><strong>Offered load not held:</strong> {named}. The latency comparison for '
            f'those cells is invalid — their percentiles describe a lighter workload than the '
            f'baseline they are measured against.</li>')

    thin = [(p, c) for (p, c), d in results.items() if d.get('runs', 1) < 3]
    if thin:
        problems.append(
            f'<li><strong>{len(thin)} of {len(results)} cells rest on fewer than 3 runs.</strong> '
            f'One run is noise; the median needs repeats. Re-run the suite and regenerate — '
            f'results accumulate, so the medians widen as you go.</li>')

    if legacy_metrics:
        problems.append(
            f'<li><strong>{legacy_metrics} metrics file(s) skipped.</strong> They predate '
            f'scenario-scoped names and cannot be attributed to <code>{scenario}</code>, so their '
            f'server-side tiles are absent rather than possibly wrong.</li>')

    if not problems:
        return ''

    return f'''
        <div class="validity-banner">
            <h4>⚠️ Read this before circulating</h4>
            <ul>
{chr(10).join('                ' + p for p in problems)}
            </ul>
        </div>
'''


SERVER_COLUMNS = [
    ('rules', 'Rules loaded', lambda s: f"{s['rule_count']:.0f}" if s.get('rule_count') is not None else '—'),
    ('reloads', 'Reloads in window', lambda s: f"{s['plugin_loads_delta']:.0f}" if s.get('plugin_loads_delta') is not None else '—'),
    ('rps_pass', 'RPS pass', lambda s: f"{s['rps']['pass']:.1f}" if (s.get('rps') or {}).get('pass') is not None else '—'),
    ('rps_block', 'RPS block', lambda s: f"{s['rps']['block']:.1f}" if (s.get('rps') or {}).get('block') is not None else '—'),
    ('anomaly', 'Anomaly p95', lambda s: f"{s['anomaly_p95']:.2f}" if s.get('anomaly_p95') is not None else '—'),
    ('cache_p99', 'Cache p99 (ms)', lambda s: f"{s['cache_p99_ms']:.2f}" if s.get('cache_p99_ms') is not None else '—'),
    ('cache_mb', 'Cache (MB)', lambda s: f"{s['cache_size_mb']:.2f}" if s.get('cache_size_mb') is not None else '—'),
    ('workqueue', 'Workqueue max', lambda s: f"{s['workqueue_max']:.0f}" if s.get('workqueue_max') is not None else '—'),
]


def generate_server_section(results, profiles, configs):
    """Server-side tiles from collect.sh, per cell. Empty when none were collected.

    Client latency says what the WAF cost; this says what the WAF and the
    operator were doing while it cost it — above all whether the ruleset under
    test was the one actually loaded, and whether a plugin reload landed inside
    the measurement window.
    """
    rows = []
    for profile in profiles:
        for config in configs:
            srv = (results.get((profile, config)) or {}).get('server')
            if not srv:
                continue
            cells = ''.join(f'<td>{fn(srv)}</td>' for _, _, fn in SERVER_COLUMNS)
            rows.append(f'''
                        <tr>
                            <td class="metric">{profile_title(profile)}</td>
                            <td class="metric">{config}</td>
                            {cells}
                        </tr>''')

    if not rows:
        return ''

    head = ''.join(f'<th>{label}</th>' for _, label, _ in SERVER_COLUMNS)
    return f'''
        <section id="server" class="section">
            <h2 class="section-title">Server-side Summary</h2>
            <p class="section-subtitle">
                Pulled from Prometheus by <code>collect.sh</code> for each run's window, median
                across repeats. <strong>Rules loaded</strong> confirms the ruleset under test was
                the one in force; <strong>reloads in window</strong> must be 0 for a valid run.
            </p>
            <table>
                <thead>
                    <tr><th>Load Profile</th><th>WAF Config</th>{head}</tr>
                </thead>
                <tbody>{''.join(rows)}
                </tbody>
            </table>
        </section>
'''
