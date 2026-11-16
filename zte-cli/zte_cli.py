#!/usr/bin/env python3
"""zte-cli v1.0 - ZTE C300 ONU registration and provisioning.

Telnet sends credentials in cleartext. Use only on an isolated management network.
No third-party dependencies (works on Python 3.13+).
"""
import argparse
import datetime as dt
import getpass
import json
import re
import socket
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

VERSION = '2.0'
PROMPT = re.compile(rb'(?m)(?:^|\r?\n)[^\r\n]{0,100}(?:\(config[^)]*\))?[#>]\s*$')
LOGIN = re.compile(rb'(?i)(?:username|login)\s*:\s*$')
PASSWORD = re.compile(rb'(?i)password\s*:\s*$')
MORE = re.compile(rb'(?i)(?:--\s*more\s*--|----\s*more\s*----)')
ERROR = re.compile(r'(?im)^\s*(?:%\s*)?(?:error|invalid|unknown command|incomplete command|ambiguous command|failed|failure|permission denied|not supported|parameter error)\b')
SN_RE = re.compile(r'\b[A-Z]{4}[0-9A-F]{8}\b', re.I)
PON_RE = re.compile(r'(?:gpon[-_]olt[_ ]?)?(\d+/\d+/\d+)', re.I)

class CliError(RuntimeError):
    pass

class TelnetSession:
    def __init__(self, host, port=23, timeout=15):
        self.host, self.port, self.timeout = host, port, timeout
        self.sock = None
        self.buffer = bytearray()

    def connect(self, username, password):
        self.sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock.settimeout(0.4)
        for _ in range(6):
            data = self.read_until((LOGIN, PASSWORD, PROMPT), self.timeout)
            if LOGIN.search(data):
                self.send(username)
            elif PASSWORD.search(data):
                self.send(password)
            elif PROMPT.search(data):
                return
        raise CliError('Login did not reach a recognizable CLI prompt')

    def send(self, text):
        self.sock.sendall(text.encode('utf-8') + b'\r\n')

    def read_until(self, patterns, timeout):
        deadline = time.monotonic() + timeout
        data = bytearray()
        while time.monotonic() < deadline:
            try:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise CliError('Connection closed by OLT')
                # Minimal Telnet IAC negotiation; reject all options.
                cleaned = bytearray()
                i = 0
                while i < len(chunk):
                    if chunk[i] == 255 and i + 1 < len(chunk):
                        verb = chunk[i+1]
                        if verb == 255:
                            cleaned.append(255); i += 2; continue
                        if verb in (251, 252, 253, 254) and i+2 < len(chunk):
                            self.sock.sendall(bytes([255, 254 if verb == 251 else 252, chunk[i+2]]))
                            i += 3; continue
                        if verb == 250:  # subnegotiation
                            end = chunk.find(b'\xff\xf0', i+2)
                            if end >= 0:
                                i = end+2; continue
                    cleaned.append(chunk[i]); i += 1
                data.extend(cleaned)
                if MORE.search(data):
                    data = bytearray(MORE.sub(b'', data))
                    self.sock.sendall(b' ')
                if any(p.search(data) for p in patterns):
                    return bytes(data)
            except socket.timeout:
                continue
        raise CliError('Timed out waiting for OLT prompt/response')

    def command(self, command, timeout=None):
        self.send(command)
        raw = self.read_until((PROMPT,), timeout or self.timeout)
        text = raw.decode('utf-8', errors='replace').replace('\r', '')
        lines = text.splitlines()
        if lines and lines[0].strip() == command.strip():
            lines.pop(0)
        if lines and re.search(r'[#>]\s*$', lines[-1]):
            lines.pop()
        result = '\n'.join(lines).strip()
        if ERROR.search(result):
            raise CliError(f'OLT rejected {command!r}: {result[:350]}')
        return result

    def close(self):
        if self.sock:
            self.sock.close()

@dataclass
class ONU:
    sn: str
    pon: str
    model: str = ''
    onu_id: int | None = None
    onu_type: str = ''
    raw: str = ''

@dataclass
class Result:
    sn: str
    pon: str
    model: str
    onu_type: str = ''
    onu_id: int | None = None
    state: str = 'SKIPPED'
    error: str = ''
    commands: list = field(default_factory=list)
    selected: dict = field(default_factory=dict)
    executed: int = 0
    verification: dict = field(default_factory=dict)

def load_settings(path):
    data = json.loads(Path(path).read_text())
    if not isinstance(data.get('profiles'), dict):
        raise CliError('Configuration must define profiles object')
    return data

def ordered_unique(items):
    return list(dict.fromkeys(items))


def parse_types(text):
    """Discover registered and defined ONU types, preserving configuration order."""
    found = []
    for line in text.splitlines():
        for pattern in (r'^\s*onu\s+\d+\s+type\s+(\S+)\s+sn\s+\S+',
                        r'^\s*onu-type\s+(\S+)\s+gpon\b',
                        r'^\s*onu-type-if\s+(\S+)\s+\S+',
                        r'^\s*(?:\d+\s+)?([A-Za-z][\w.-]+)\s+GPON(?:\s|$)'):
            m = re.search(pattern, line, re.I)
            if m and m.group(1).lower() not in ('name', 'type', 'interface'):
                found.append(m.group(1)); break
    return ordered_unique(found)


def parse_vlans(text):
    """Discover configured VLAN IDs and DHCP snooping flags from running-config."""
    result = {}
    current = None
    for line in text.splitlines():
        m = re.match(r'^vlan\s+(\d{1,4})\s*$', line, re.I)
        if m:
            current = int(m.group(1))
            result[current] = {'dhcp_snooping': False}
            continue
        if current is not None:
            if re.match(r'^\s+ip\s+dhcp\s+snooping\s*$', line, re.I):
                result[current]['dhcp_snooping'] = True
            elif re.match(r'^(?:!|\S)', line):
                current = None
    return result


def parse_traffic_profiles(text):
    """Cache actual ingress/egress assignments from existing ONU configurations."""
    out = {'ingress': [], 'egress': []}
    for line in text.splitlines():
        m = re.match(r'^\s*traffic-profile\s+(\S+)\s+vport\s+\d+\s+direction\s+(ingress|egress)\b', line, re.I)
        if m and m.group(1) not in out[m.group(2).lower()]:
            out[m.group(2).lower()].append(m.group(1))
    return out


def parse_pon_descriptions(text):
    result, current = {}, None
    for line in text.splitlines():
        m = re.match(r'^\s*interface\s+gpon-olt_(\d+/\d+/\d+)\s*$', line, re.I)
        if m:
            current = m.group(1); continue
        if re.match(r'^\s*(?:!|exit|interface\s+)', line, re.I):
            current = None
        if current:
            m = re.match(r'^\s*description\s+(.+?)\s*$', line, re.I)
            if m: result[current] = m.group(1).strip().strip('"')
    return result


def parse_nids(description):
    """NIDS KVM subset for provisioning; retains hyphens in keys and strings in values."""
    if '::' not in description: return {}
    tail = description.split('::', 1)[1]
    result = {}
    # Split underscores only outside single-quoted strings.
    parts, token, quoted, i = [], '', False, 0
    while i < len(tail):
        ch = tail[i]
        if ch == "'":
            if quoted and i+1 < len(tail) and tail[i+1] == "'":
                token += "''"; i += 2; continue
            quoted = not quoted
        if ch == '_' and not quoted:
            parts.append(token); token = ''
        else: token += ch
        i += 1
    if quoted: raise CliError('Unclosed NIDS metadata quote')
    parts.append(token)
    for part in parts:
        if ':' not in part: continue
        key, value = part.split(':', 1)
        key, value = key.strip().upper(), value.strip()
        if value.startswith("'") and value.endswith("'"):
            value = value[1:-1].replace("''", "'")
        if key: result[key] = value
    return result


def resolve_cached(explicit, available, label):
    if explicit:
        if explicit not in available:
            raise CliError(f'NIDS {label}={explicit!r} is absent from cached OLT configuration')
        return explicit, 'NIDS'
    if not available:
        raise CliError(f'No cached {label} available; refusing to guess')
    return available[0], 'CACHE-FIRST'


def parse_unregistered(text):
    found = {}
    for line in text.splitlines():
        sm = SN_RE.search(line)
        pm = PON_RE.search(line)
        if not sm or not pm:
            continue
        sn, pon = sm.group().upper(), pm.group(1)
        # Model field must be explicitly labeled or provided by a named column.
        mm = re.search(r'(?i)\bmodel\s*[:=]\s*([\w.-]+)', line)
        model = mm.group(1) if mm else ''
        found[sn] = ONU(sn, pon, model=model, raw=line)
    return list(found.values())

def parse_registered(text):
    out = []
    for line in text.splitlines():
        sm = SN_RE.search(line)
        pm = PON_RE.search(line)
        if sm and pm:
            out.append(ONU(sm.group().upper(), pm.group(1), raw=line))
    return out

def extract_occupied_ids(text, pon):
    ids = set()
    # Trust only explicit ONU interface identifiers and interface-specific registration lines.
    for match in re.finditer(r'(?i)gpon-onu_?' + re.escape(pon) + r':(\d+)', text):
        ids.add(int(match.group(1)))
    # Caller must supply a single-PON block; never mix ONU IDs from other PONs.
    for match in re.finditer(r'(?im)^\s*onu\s+(\d+)\s+type\s+\S+\s+sn\s+\S+', text):
        ids.add(int(match.group(1)))
    return ids

def select_type(onu, available, settings):
    """Choose an exact/mapped type, then a configured OLT-supported generic fallback."""
    aliases = settings.get('model_aliases', {})
    model = onu.model.strip()
    mapped = next((v for k, v in aliases.items() if k.casefold() == model.casefold()), model)
    matches = [t for t in available if model and t.casefold() == mapped.casefold()]
    if len(matches) == 1:
        return matches[0], 'MAPPED' if mapped != model else 'EXACT'
    fallback = settings.get('fallback_onu_type', 'GENERIC-HGU')
    fallbacks = [t for t in available if t == fallback]
    if len(fallbacks) != 1:
        raise CliError(f'Unknown/ambiguous model {model or "(missing)"}; fallback type {fallback!r} not available on OLT')
    return fallbacks[0], 'FALLBACK'

def render(template, values):
    try:
        return template.format_map(values)
    except KeyError as exc:
        raise CliError(f'Missing template variable: {exc}') from exc

class Manager:
    def __init__(self, session, settings, preview):
        self.s, self.cfg, self.preview = session, settings, preview
        self.types = []
        self.unreg = []
        self.registered = []

    def refresh(self):
        discovery = self.cfg['discovery']
        # Mandatory snapshot. Failure blocks all provisioning.
        self.running = self.s.command(discovery.get('running', 'show running-config'), timeout=max(self.s.timeout, 60))
        if not self.running.strip():
            raise CliError('Empty running configuration; cache not loaded')
        self.types = parse_types(self.running)
        self.vlans = parse_vlans(self.running)
        self.traffic_profiles = parse_traffic_profiles(self.running)
        self.pon_descriptions = parse_pon_descriptions(self.running)
        self.registered = parse_registered(self.running)
        # Optional extra type definitions; never replace configured type order.
        extra = discovery.get('types')
        if extra:
            try: self.types = ordered_unique(self.types + parse_types(self.s.command(extra)))
            except CliError as exc: print('WARNING: additional type discovery:', exc)
        self.unreg = parse_unregistered(self.s.command(discovery['unregistered']))
        print(f'[CACHE] types={self.types} VLANs={self.vlans}')
        print(f'[CACHE] traffic ingress={self.traffic_profiles["ingress"]} egress={self.traffic_profiles["egress"]}')
        print(f'[DISCOVERY] {len(self.unreg)} unregistered ONUs')

    def show(self, arg):
        if arg == 'cache':
            print(json.dumps({'onu_types':self.types,'vlans':self.vlans,'traffic_profiles':self.traffic_profiles,'pon_descriptions':self.pon_descriptions}, indent=2))
        elif arg == 'types':
            print('\n'.join(sorted(self.types)) or '(none parsed)')
            if not self.types:
                print('Discovery errors:', *getattr(self, 'type_errors', []), sep='\n  ')
        elif arg == 'unreg':
            for o in self.unreg:
                print(f'{o.pon:<12} {o.sn:<16} {o.model or "MODEL UNKNOWN"}')
            if not self.unreg: print('(none)')
        elif arg == 'all':
            for o in sorted(self.registered, key=lambda x:(x.pon, x.sn)):
                print(f'{o.pon:<12} {o.sn}  {o.raw}')
            if not self.registered: print('(none parsed)')
        else:
            sn = arg.upper()
            if not SN_RE.fullmatch(sn):
                raise CliError('Expected show types|all|unreg|<onu-sn>')
            matches = [o for o in self.registered if o.sn == sn]
            if not matches:
                print('ONU not present in parsed registered list')
                return
            for o in matches:
                print(self.s.command(render(self.cfg['discovery']['onu_config'], {'pon':o.pon, 'sn':sn})))

    def reg(self, arg):
        self.refresh()  # snapshot once for the entire batch
        targets = self.unreg if arg == 'all' else [o for o in self.unreg if o.sn == arg.upper()]
        if not targets:
            print('No matching unregistered ONU found'); return
        results = []
        for i, onu in enumerate(targets, 1):
            r = Result(onu.sn, onu.pon, onu.model)
            results.append(r)
            print(f'[{i}/{len(targets)}] {onu.sn} {onu.pon}')
            try:
                if not self.types:
                    raise CliError('Cannot read configured ONU types from OLT (discovery failure)')
                nids = parse_nids(self.pon_descriptions.get(onu.pon, ''))
                r.onu_type, type_source = resolve_cached(nids.get('ONU-TYPE') or nids.get('TYPE'), self.types, 'ONU-TYPE')
                if onu.model and onu.model in self.types and not (nids.get('ONU-TYPE') or nids.get('TYPE')):
                    r.onu_type, type_source = onu.model, 'MODEL-EXACT'
                ingress, in_source = resolve_cached(nids.get('TRAFFIC-INGRESS'), self.traffic_profiles['ingress'], 'TRAFFIC-INGRESS')
                egress, out_source = resolve_cached(nids.get('TRAFFIC-EGRESS'), self.traffic_profiles['egress'], 'TRAFFIC-EGRESS')
                r.selected = {'onu_type':r.onu_type, 'type_source':type_source, 'traffic_ingress':ingress, 'traffic_egress':egress}
                print('  Resolved:', r.selected)
                profile = self.cfg['profiles'].get(r.onu_type) or self.cfg['profiles'].get('default')
                if not profile:
                    raise CliError(f'No provisioning profile for {r.onu_type} (or default)')
                # PON config must be scoped to the requested interface only.
                pon_config = self.s.command(render(self.cfg['discovery']['pon_config'], {'pon':onu.pon}))
                if not re.search(r'(?im)^\s*interface\s+gpon-olt_' + re.escape(onu.pon) + r'\b', pon_config):
                    raise CliError('PON configuration response does not identify requested interface')
                occupied = extract_occupied_ids(pon_config, onu.pon)
                if not occupied and not self.cfg.get('allow_empty_pon', False):
                    if not pon_config.strip() or re.search(r'(?i)(invalid|error|not found|unsupported)', pon_config):
                        raise CliError('Cannot validate occupied ONU IDs; empty/invalid PON config')
                    print('  PON configuration contains no registered ONU IDs; allocating first free ID')
                max_id = int(self.cfg.get('max_onu_id', 128))
                r.onu_id = next((n for n in range(1,max_id+1) if n not in occupied), None)
                if r.onu_id is None: raise CliError('No free ONU ID')
                values = {**profile.get('variables', {}), 'sn':onu.sn, 'pon':onu.pon,
                          'onu_id':r.onu_id, 'onu_type':r.onu_type,
                          'traffic_down':ingress, 'traffic_up':egress}
                # Do not invent service VLANs; require an explicit PON mapping or NIDS VLAN.
                explicit_vlan = nids.get('VLAN')
                if explicit_vlan:
                    match = re.fullmatch(r'(?:VLAN)?(\d{1,4})', explicit_vlan, re.I)
                    if not match: raise CliError(f'Invalid numeric NIDS VLAN: {explicit_vlan}')
                    values['service_vlan'] = int(match.group(1))
                elif onu.pon in self.cfg.get('pon_service_vlans', {}):
                    values['service_vlan'] = self.cfg['pon_service_vlans'][onu.pon]
                else:
                    raise CliError(f'No service VLAN defined for PON {onu.pon}; set NIDS VLAN or pon_service_vlans')
                if not 1 <= int(values['service_vlan']) <= 4094:
                    raise CliError('Service VLAN outside 1..4094')
                if int(values['service_vlan']) not in self.vlans:
                    raise CliError(f'Service VLAN {values["service_vlan"]} is not defined on OLT')
                if not self.vlans[int(values['service_vlan'])]['dhcp_snooping']:
                    print(f'  WARNING: VLAN {values["service_vlan"]} has no cached DHCP snooping configuration')
                tr69 = nids.get('TR69')
                if tr69 is not None:
                    if not re.fullmatch(r'\\d{1,4}', tr69) or not 1 <= int(tr69) <= 4094:
                        raise CliError(f'Invalid NIDS TR69 VLAN: {tr69}')
                    values['tr069_user_vlan'] = int(tr69)
                r.selected.update({'service_vlan':values['service_vlan'],
                                   'tr069_user_vlan':values['tr069_user_vlan']})
                commands = [render(c, values) for c in profile['commands']]
                if self.cfg.get('enable_wan_dhcp', False):
                    # Firmware-specific command is opt-in and requires explicit validation.
                    wan = self.cfg.get('wan_commands', [])
                    if any('{vlan_profile}' in c for c in wan):
                        raise CliError('WAN DHCP template still requires vlan-profile; configure WAN mapping separately')
                    if not wan: raise CliError('WAN DHCP enabled but wan_commands is empty')
                    commands += [render(c, values) for c in wan]
                if not commands or any(not c.strip() for c in commands):
                    raise CliError('Empty provisioning command')
                r.commands = commands
                if self.preview:
                    print('\n'.join('  ' + c for c in commands))
                    r.state = 'PREVIEW'; continue
                for command in commands:
                    self.s.command(command, timeout=self.cfg.get('command_timeout', 20))
                    r.executed += 1
                # Read back and require explicit verification evidence.
                checks = profile.get('verify', [])
                if not checks:
                    raise CliError('No verification checks defined for profile')
                all_ok = True
                for check in checks:
                    output = self.s.command(render(check['command'], values))
                    pattern = render(check['regex'], values)
                    ok = bool(re.search(pattern, output, re.I | re.M))
                    r.verification[check['name']] = {'ok':ok, 'command':check['command']}
                    if not ok: all_ok = False
                r.state = 'SUCCESS' if all_ok else 'VERIFY_FAILED'
                if not all_ok:
                    r.error = 'One or more running-config checks did not match'
                else:
                    if self.cfg.get('save_after_verify', True):
                        self.s.command(self.cfg.get('save_command', 'write'), timeout=60)
            except (CliError, KeyError, ValueError, socket.error) as exc:
                r.state = 'PARTIAL' if r.executed else ('FAILED' if r.commands else 'SKIPPED')
                r.error = str(exc)
            print(f'  {r.state}' + (f': {r.error}' if r.error else ''))
        counts = {state:sum(r.state == state for r in results) for state in ('SUCCESS','PARTIAL','FAILED','VERIFY_FAILED','SKIPPED','PREVIEW')}
        print('\nSUMMARY: ' + '  '.join(f'{k}={v}' for k,v in counts.items()))
        for r in results:
            if r.state in ('PARTIAL','FAILED','VERIFY_FAILED','SKIPPED'):
                print(f'  {r.sn}: {r.state} - {r.error}')
        report_dir = Path(self.cfg.get('report_dir', 'reports'))
        report_dir.mkdir(parents=True, exist_ok=True)
        name = report_dir / ('zte-cli-' + dt.datetime.now().strftime('%Y%m%d-%H%M%S') + '.json')
        from dataclasses import asdict
        name.write_text(json.dumps({'preview':self.preview, 'timestamp':dt.datetime.now(dt.timezone.utc).isoformat(), 'results':[asdict(r) for r in results], 'counts':counts}, indent=2))
        print(f'Report: {name}')
        if not self.preview:
            self.refresh()

def main():
    parser = argparse.ArgumentParser(description='ZTE C300 ONU management CLI')
    parser.add_argument('mode', nargs='?', choices=['preview'], help='preview: print planned registration commands; default applies them')
    parser.add_argument('--host', required=True, help='OLT management IP/hostname')
    parser.add_argument('--port', type=int, default=23)
    parser.add_argument('--user', required=True)
    parser.add_argument('--config', default='zte-cli.json')
    args = parser.parse_args()
    cfg = load_settings(args.config)
    print('*' * 49)
    print(f'  ZTE-CLI version {VERSION}')
    print('  Date: ' + dt.date.today().isoformat())
    print('  By Tishri Clarin')
    print('  ZTE GPON ONU discovery, registration,')
    print('  provisioning and configuration verification')
    print('*' * 49)
    print('MODE: ' + ('PREVIEW (read-only)' if args.mode == 'preview' else 'APPLY (changes OLT)'))
    password = getpass.getpass('OLT password: ')
    s = TelnetSession(args.host, args.port, cfg.get('timeout',15))
    try:
        s.connect(args.user, password)
        mgr = Manager(s, cfg, args.mode == 'preview')
        mgr.refresh()
        print('Commands: show cache|types|all|unreg|<sn>, reg <sn>|all, refresh, help, exit')
        while True:
            try:
                line = input('zte-cli> ').strip()
                if not line: continue
                cmd, _, arg = line.partition(' ')
                cmd, arg = cmd.lower(), arg.strip()
                if cmd in ('exit','quit'): break
                elif cmd == 'help': print('show cache | show types | show all | show unreg | show <onu-sn>\nreg <onu-sn> | reg all | refresh | exit')
                elif cmd == 'refresh': mgr.refresh()
                elif cmd == 'show': mgr.show(arg)
                elif cmd == 'reg' and (arg == 'all' or SN_RE.fullmatch(arg)):
                    mgr.reg(arg)
                else: print('Unknown command. Type help.')
            except (CliError, KeyError, ValueError) as exc:
                print('ERROR:', exc)
            except (EOFError, KeyboardInterrupt):
                print(); break
    finally:
        s.close()

if __name__ == '__main__':
    try: main()
    except (CliError, OSError, ValueError, json.JSONDecodeError) as exc:
        print('FATAL:', exc, file=sys.stderr)
        sys.exit(1)
