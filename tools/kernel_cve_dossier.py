#!/usr/bin/env python3
"""kernel_cve_dossier.py VULNS KERNEL TRIAGE REPORT_DIR OUT_DIR [VERDICT] [BATCH_SIZE]

Prepares a review of the CVEs that carry VERDICT (default: baseline) in TRIAGE or in
REPORT_DIR/report.tsv of the last kernel_cve_check.py run (that is where NEW and recheck
live; TRIAGE may be a comma-separated list as for that tool): for each one a
"dossier" with the CNA record, the oldest stable fix (cached in REPORT_DIR/patches, fetched when
missing) and the matching code of our tree, so a reviewer needs few lookups of their own.
Mechanical findings per CVE:
  reverse-applies   the fix is already in the tree, byte for byte, without a backport marker
  applies           the fix applies cleanly (vulnerable code present as upstream had it)
  added-present     share of the fix's added lines that already exist in our file
  removed-present   share of the lines the fix removes that exist in our file
  anchors           hunks whose surrounding code was found in our file
Output: OUT_DIR/batch-NN-<area>.md (BATCH_SIZE dossiers each, grouped by area), OUT_DIR/index.tsv
(one line per CVE with the mechanical findings) and OUT_DIR/auto.tsv (verdicts that need no
reviewer: reverse-applies). Reads the kernel tree only (`git apply --check`), changes nothing.
"""
import csv, json, os, re, subprocess, sys, time

vulns, kdir, triage_f, rdir, odir = sys.argv[1:6]
want = sys.argv[6] if len(sys.argv) > 6 else 'baseline'
batch_size = int(sys.argv[7]) if len(sys.argv) > 7 else 20
MAX_DIFF, MAX_SNIP_HUNKS, SNIP_BEFORE, SNIP_AFTER, MAX_DESC = 170, 4, 22, 34, 1700

def ver(s):
    return tuple(int(x) for x in re.findall(r'\d+', s)[:3]) if re.match(r'^\d', s or '') else (999,)

def sig(line):
    s = ' '.join(line.split())
    if len(s) < 12 or s.startswith(('/*', '*', '//', '#include')) or not re.search(r'[A-Za-z_]{3}', s):
        return None
    return s

def area(path):
    for pre, a in (('net/ipv4', 'ipv4'), ('net/ipv6', 'ipv6'), ('net/core', 'netcore'),
                   ('include/net', 'netcore'), ('include/linux/skbuff', 'netcore'),
                   ('include/linux/netdevice', 'netcore'), ('net/', 'netcore')):
        if path.startswith(pre):
            return a
    return 'mmkernel'

def parse_patch(text):
    """-> [(path, [(header, [lines])])] for the files of a `git format-patch` style patch."""
    files, cur, hunk = [], None, None
    for line in text.split('\n'):
        if line.startswith('diff --git '):
            m = re.match(r'diff --git a/(\S+) b/(\S+)', line)
            cur = (m.group(2) if m else '?', [])
            files.append(cur)
            hunk = None
        elif line.startswith('@@') and cur is not None:
            hunk = (line, [])
            cur[1].append(hunk)
        elif hunk is not None and line[:1] in (' ', '+', '-') and not line.startswith(('+++', '---')):
            hunk[1].append(line)
        elif hunk is not None and line.startswith('-- '):
            hunk = None
    return files

triage = {}
for tf in triage_f.split(','):
    if os.path.exists(tf):
        triage.update((r[0], r[1]) for r in csv.reader(open(tf), delimiter='\t') if r and r[0].startswith('CVE'))
report = {r['cve']: r for r in csv.DictReader(open(os.path.join(rdir, 'report.tsv')), delimiter='\t')}
todo = [c for c, v in triage.items() if v == want and report.get(c, {}).get('verdict', want) == want]
todo += [c for c, r in report.items() if r['verdict'] == want and c not in todo]
os.makedirs(odir, exist_ok=True)
pdir = os.path.join(rdir, 'patches')
os.makedirs(pdir, exist_ok=True)
file_cache = {}

def our_file(path):
    if path not in file_cache:
        p = os.path.join(kdir, path)
        file_cache[path] = open(p, errors='replace').read().split('\n') if os.path.isfile(p) else None
    return file_cache[path]

index, auto, dossiers = [], [], {}
for n, cve in enumerate(todo):
    year = cve.split('-')[1]
    base = os.path.join(vulns, 'cve/published', year, cve)
    if not os.path.exists(base + '.json'):
        index.append(dict(cve=cve, area='?', finding='no-cna-record'))
        continue
    cna = json.load(open(base + '.json'))['containers']['cna']
    title = (cna.get('title') or '').strip()
    desc = cna['descriptions'][0]['value'] if cna.get('descriptions') else ''
    desc = re.sub(r'^In the Linux kernel, the following vulnerability has been resolved:\s*', '', desc)
    intro = next((v['lessThan'] for a in cna.get('affected', []) for v in a.get('versions', [])
                  if v.get('status') == 'unaffected' and v.get('version') == '0' and v.get('lessThan')), '?')
    cvss = ''
    if os.path.exists(base + '.cvss'):
        cvss = ' '.join(open(base + '.cvss').read().split())[:420]
    rep = report.get(cve, {})
    files_compiled = rep.get('files', '')
    fixes = []
    if os.path.exists(base + '.dyad'):
        for line in open(base + '.dyad'):
            p = line.strip().split(':')
            if not line.startswith('#') and len(p) >= 4 and re.fullmatch(r'[0-9a-f]{40}', p[3]):
                fixes.append((ver(p[2]), p[2], p[3]))
    patch, pver, state = None, '', 'no-fix-data'
    for _, fver, fsha in sorted(fixes)[:3]:
        pf = os.path.join(pdir, '%s-%s.patch' % (cve, fver))
        if not os.path.exists(pf):
            rc = subprocess.run(['curl', '-sfL', '--max-time', '60', '-o', pf,
                                 'https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/patch/?id='
                                 + fsha]).returncode
            time.sleep(0.5)
            if rc or not os.path.exists(pf) or not os.path.getsize(pf):
                if os.path.exists(pf):
                    os.remove(pf)
                continue
        ap = os.path.abspath(pf)
        if patch is None:
            patch, pver, state = pf, fver, 'fails'
        if subprocess.run(['git', '-C', kdir, 'apply', '--check', ap], capture_output=True).returncode == 0:
            patch, pver, state = pf, fver, 'applies'
            break
        if subprocess.run(['git', '-C', kdir, 'apply', '--check', '-R', ap], capture_output=True).returncode == 0:
            patch, pver, state = pf, fver, 'reverse-applies'
            break
    out = ['', '=' * 100, '## %s — %s' % (cve, title), '',
           'introduced: %s | compiled files hit: %s | CNA vector: %s' % (intro, files_compiled, cvss or 'none yet'),
           '', desc[:MAX_DESC] + (' […]' if len(desc) > MAX_DESC else ''), '']
    add_tot = add_hit = rem_tot = rem_hit = hunks = anchored = 0
    missing_files, funcs_absent = [], []
    if patch:
        text = open(patch, errors='replace').read()
        pfiles = [f for f in parse_patch(text) if not f[0].startswith(('tools/', 'Documentation/'))]
        snips = []
        for path, hk in pfiles:
            ours = our_file(path)
            if ours is None:
                missing_files.append(path)
                continue
            norm = {}
            for i, l in enumerate(ours):
                s = sig(l)
                if s and s not in norm:
                    norm[s] = i
            for header, lines in hk:
                hunks += 1
                for l in lines:
                    s = sig(l[1:])
                    if not s:
                        continue
                    if l[0] == '+':
                        add_tot += 1
                        add_hit += s in norm
                    elif l[0] == '-':
                        rem_tot += 1
                        rem_hit += s in norm
                anchor = next((norm[s] for s in (sig(l[1:]) for l in lines if l[0] == '-') if s in norm), None)
                if anchor is None:
                    anchor = next((norm[s] for s in (sig(l[1:]) for l in lines if l[0] == ' ') if s in norm), None)
                fn = re.search(r'@@.*@@\s*(?:.*?\b)?([A-Za-z_][A-Za-z0-9_]*)\s*\(', header)
                fname = fn.group(1) if fn else None
                if anchor is not None:
                    anchored += 1
                    if len(snips) < MAX_SNIP_HUNKS:
                        a, b = max(0, anchor - SNIP_BEFORE), min(len(ours), anchor + SNIP_AFTER)
                        snips.append('### our tree: %s lines %d-%d\n```c\n%s\n```' % (
                            path, a + 1, b, '\n'.join('%d\t%s' % (a + 1 + i, l) for i, l in enumerate(ours[a:b]))))
                elif fname:
                    present = any(re.search(r'\b%s\s*\(' % re.escape(fname), l) for l in ours)
                    if not present:
                        funcs_absent.append(fname)
                    snips.append('### our tree: %s — hunk context NOT found; function %s() %s in the file' % (
                        path, fname, 'exists' if present else 'does NOT exist'))
        dl = text[text.find('diff --git'):].split('\n') if 'diff --git' in text else []
        out += ['### upstream fix (%s, stable %s, `git apply --check`: %s)' % (os.path.basename(patch), pver, state),
                '```diff'] + dl[:MAX_DIFF] + (['[… %d more lines, full patch: %s]' % (len(dl) - MAX_DIFF, patch)]
                                             if len(dl) > MAX_DIFF else []) + ['```', '']
        out += snips
    finding = state
    out += ['', 'mechanical: apply=%s; fix lines already in our file %d/%d; removed lines present %d/%d; '
            'hunks located %d/%d%s%s' % (state, add_hit, add_tot, rem_hit, rem_tot, anchored, hunks,
                                         '; files absent: ' + ','.join(missing_files) if missing_files else '',
                                         '; functions absent: ' + ','.join(sorted(set(funcs_absent))) if funcs_absent else '')]
    first = (files_compiled.split(',')[0] if files_compiled else '') or '?'
    row = dict(cve=cve, area=area(first), finding=finding, added='%d/%d' % (add_hit, add_tot),
               removed='%d/%d' % (rem_hit, rem_tot), anchors='%d/%d' % (anchored, hunks),
               funcs_absent=','.join(sorted(set(funcs_absent))), patch=os.path.basename(patch) if patch else '',
               files=files_compiled, title=title)
    index.append(row)
    if state == 'reverse-applies':
        auto.append((cve, 'not-present', 'fix already in the tree without a backport marker: %s reverse-applies '
                     '(mechanical, kernel_cve_dossier.py)' % os.path.basename(patch)))
    else:
        dossiers.setdefault(row['area'], []).append((first, cve, '\n'.join(out)))
    if (n + 1) % 25 == 0:
        print('  %d/%d' % (n + 1, len(todo)), file=sys.stderr)

cols = ['cve', 'area', 'finding', 'added', 'removed', 'anchors', 'funcs_absent', 'patch', 'files', 'title']
with open(os.path.join(odir, 'index.tsv'), 'w') as o:
    w = csv.DictWriter(o, fieldnames=cols, delimiter='\t', extrasaction='ignore', restval='')
    w.writeheader()
    w.writerows(index)
with open(os.path.join(odir, 'auto.tsv'), 'w') as o:
    for r in auto:
        o.write('\t'.join(r) + '\n')
batches, bn = [], 0
for a in sorted(dossiers):
    items = sorted(dossiers[a])
    k = max(1, -(-len(items) // batch_size))          # number of batches for this area
    per = -(-len(items) // k)
    for i in range(0, len(items), per):
        bn += 1
        chunk = items[i:i + per]
        name = 'batch-%02d-%s.md' % (bn, a)
        with open(os.path.join(odir, name), 'w') as o:
            o.write('# CVE dossiers, batch %d (%s): %d CVEs\n\nCVEs: %s\n' % (
                bn, a, len(chunk), ' '.join(c for _, c, _ in chunk)))
            o.write('\n'.join(d for _, _, d in chunk) + '\n')
        batches.append((name, a, len(chunk), os.path.getsize(os.path.join(odir, name))))
print('%d CVEs with verdict %s: %d decided mechanically (auto.tsv), %d in %d batches' % (
    len(todo), want, len(auto), sum(b[2] for b in batches), len(batches)))
for b in batches:
    print('  %-28s %-9s %3d CVEs %7d bytes' % b)
