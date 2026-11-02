#!/usr/bin/env python3
"""kernel_cve_check.py VULNS KERNEL OBJDIR TRIAGE REPORT_DIR

Kernel CNA CVEs (VULNS = clone of git.kernel.org/.../security/vulns.git) against the kernel fork:
keeps CVEs whose files are on the network surface and compiled in OBJDIR (a kbuild O= dir:
<file>.o for sources, .*.o.cmd dependency lists for headers), introduced in <= 4.14 (or whose
introducing commit was backported into our tree), and whose fix is not referenced by a backport
marker in HEAD. For network/adjacent vectors (AV:N/AV:A) and CVEs the CNA has not scored yet it
dry-runs the oldest stable backport with `git apply --check` (patches cached in REPORT_DIR).
Two surfaces: "net" (packets from the network or the local link) and "sandbox" (what a compromised
browser renderer can reach from its seccomp + isolated_app sandbox: futex, memory syscalls, AF_UNIX
with fd passing, epoll/eventfd/pipe, signals/timers, binder, ashmem/memfd). For "sandbox" the
apply check runs for CNA vectors with high confidentiality/integrity impact or no score yet.
TRIAGE (tsv: cve, verdict, note) holds earlier decisions; only CVEs not in it are listed on stdout.
"""
import csv, glob, json, os, re, subprocess, sys, time

vulns, kdir, objdir, triage_f, rdir = sys.argv[1:6]
SURFACES = {
    'net': ('net/', 'include/net/', 'include/linux/skbuff.h', 'include/linux/netdevice.h',
            'include/linux/netfilter', 'include/uapi/linux/netfilter', 'drivers/net/ppp/',
            'drivers/net/wireless/'),
    'sandbox': ('kernel/futex', 'include/linux/futex', 'mm/', 'include/linux/mm', 'net/unix/',
                'include/net/af_unix.h', 'net/core/scm.c', 'include/net/scm.h', 'net/socket.c',
                'fs/eventpoll.c', 'fs/eventfd.c', 'fs/pipe.c', 'fs/timerfd.c', 'fs/splice.c',
                'fs/read_write.c', 'fs/select.c', 'fs/file.c', 'fs/fcntl.c', 'fs/locks.c',
                'kernel/signal.c', 'kernel/time/', 'kernel/fork.c', 'kernel/exit.c', 'kernel/pid.c',
                'kernel/sys.c', 'kernel/sched/core.c', 'drivers/android/', 'include/uapi/linux/android/',
                'drivers/staging/android/ashmem', 'lib/iov_iter.c', 'include/linux/uio.h'),
}
PREFIXES = tuple(p for v in SURFACES.values() for p in v)
BACKPORT_RE = re.compile(r'(?:commit ([0-9a-f]{12,40}) upstream|[Uu]pstream commit ([0-9a-f]{12,40})|'
                         r'cherry picked from commit ([0-9a-f]{12,40}))')

def ver(s):
    return tuple(int(x) for x in re.findall(r'\d+', s)[:3]) if re.match(r'^\d', s or '') else None

def norm(subj):
    return re.sub(r'^((UPSTREAM|BACKPORT|FROMGIT|FROMLIST|ANDROID|CHROMIUM)[:,] *)+', '', subj.strip()).lower()

# backport markers and subjects in our history (committed after v4.14)
log = subprocess.run(['git', '-C', kdir, 'log', '--since=2017-11-01', '--format=%s%x01%b%x02'],
                     capture_output=True, text=True, errors='replace').stdout
up_refs, subjects = set(), set()
for rec in log.split('\x02'):
    if '\x01' in rec:
        subj, body = rec.split('\x01', 1)
        subjects.add(norm(subj))
        for g in BACKPORT_RE.findall(body):
            up_refs.add(next(x for x in g if x)[:12])

# headers used by the build: map each dependency path to the longest suffix that exists in the tree
used_headers, seen_dep = set(), {}
for root, _, names in os.walk(objdir):
    for n in names:
        if not (n.startswith('.') and n.endswith('.o.cmd')):
            continue
        for line in open(os.path.join(root, n), errors='replace'):
            dep = line.strip().rstrip('\\').strip()
            if not dep.endswith('.h') or dep.startswith('$('):
                continue
            if dep not in seen_dep:
                segs = [x for x in dep.split('/') if x not in ('', '.', '..')]
                seen_dep[dep] = next(('/'.join(segs[i:]) for i in range(len(segs))
                                      if os.path.isfile(os.path.join(kdir, *segs[i:]))), None)
            if seen_dep[dep]:
                used_headers.add(seen_dep[dep])

def compiled(f):
    if f.endswith('.c'):
        return os.path.exists(os.path.join(objdir, f[:-2] + '.o'))
    return f in used_headers

triage = {}
if os.path.exists(triage_f):
    for r in csv.reader(open(triage_f), delimiter='\t'):
        if r and not r[0].startswith('#') and r[0] != 'cve':
            triage[r[0]] = (r[1], r[2] if len(r) > 2 else '')

os.makedirs(os.path.join(rdir, 'patches'), exist_ok=True)
stats = dict(cves=0, surface=0, in_414=0, compiled=0, fixed=0, open=0)
rows = []
for jf in sorted(glob.glob(os.path.join(vulns, 'cve/published/*/CVE-*.json'))):
    stats['cves'] += 1
    cna = json.load(open(jf))['containers']['cna']
    files, intro, intro_commits = set(), None, set()
    for a in cna.get('affected', []):
        files.update(a.get('programFiles', []))
        for v in a.get('versions', []):
            if v.get('versionType') == 'git' and v.get('status') == 'affected':
                intro_commits.add(v['version'][:12])
            if v.get('status') == 'unaffected' and v.get('version') == '0' and v.get('lessThan'):
                intro = v['lessThan']
    surf = sorted(f for f in files if f.startswith(PREFIXES))
    if not surf:
        continue
    stats['surface'] += 1
    iv = ver(intro) if intro else None
    bp_intro = any(c in up_refs for c in intro_commits if not c.startswith('1da177e4c3f4'))
    if not (iv is None or iv <= (4, 14, 999) or bp_intro):
        continue
    stats['in_414'] += 1
    comp = [f for f in surf if compiled(f)]
    if not comp:
        continue
    stats['compiled'] += 1
    base = jf[:-5]
    cve = os.path.basename(base)
    fix = open(base + '.sha1').read().split() if os.path.exists(base + '.sha1') else []
    title = (cna.get('title') or '').strip()
    if any(s[:12] in up_refs for s in fix) or (title and norm(title) in subjects):
        stats['fixed'] += 1
        continue
    stats['open'] += 1
    surface = '+'.join(k for k, v in SURFACES.items() if any(f.startswith(v) for f in comp))
    av = '-'
    if os.path.exists(base + '.cvss'):
        m = re.search(r'/AV:([NALP])/.*?/I:([NLH])/A:([NLH])', open(base + '.cvss').read())
        m2 = re.search(r'/C:([NLH])/', open(base + '.cvss').read())
        if m:
            av = 'AV:%s/C:%s/I:%s/A:%s' % (m.group(1), m2.group(1) if m2 else '?', m.group(2), m.group(3))
    apply_res, src = '', ''
    if av == '-' or ('net' in surface and av.startswith(('AV:N', 'AV:A'))) or \
            ('sandbox' in surface and av.startswith('AV:L') and ('C:H' in av or 'I:H' in av)):
        fixes = []
        if os.path.exists(base + '.dyad'):
            for line in open(base + '.dyad'):
                p = line.strip().split(':')
                if not line.startswith('#') and len(p) >= 4 and re.fullmatch(r'[0-9a-f]{40}', p[3]):
                    fixes.append((ver(p[2]) or (999,), p[2], p[3]))
        apply_res = 'no-fix-data' if not fixes else 'fails'
        for _, fver, fsha in sorted(fixes)[:3]:
            pf = os.path.join(rdir, 'patches', '%s-%s.patch' % (cve, fver))
            if not os.path.exists(pf):
                rc = subprocess.run(['curl', '-sfL', '-o', pf, 'https://git.kernel.org/pub/scm/linux/kernel/'
                                     'git/stable/linux.git/patch/?id=' + fsha]).returncode
                time.sleep(0.5)
                if rc or not os.path.exists(pf) or not os.path.getsize(pf):
                    if os.path.exists(pf): os.remove(pf)
                    continue
            if subprocess.run(['git', '-C', kdir, 'apply', '--check', os.path.abspath(pf)],
                              capture_output=True).returncode == 0:
                apply_res, src = 'clean', fver
                break
            src = src or fver
    verdict, note = triage.get(cve, ('NEW', ''))
    rows.append(dict(cve=cve, surface=surface, verdict=verdict, cvss=av, apply=apply_res, patch_from=src,
                     files=','.join(comp), title=title, note=note))

with open(os.path.join(rdir, 'report.tsv'), 'w') as o:
    w = csv.DictWriter(o, fieldnames=list(rows[0].keys()) if rows else ['cve'], delimiter='\t')
    w.writeheader()
    w.writerows(rows)

print('CVE records %(cves)d | network surface %(surface)d | present in 4.14 %(in_414)d | '
      'compiled %(compiled)d | fixed in our tree %(fixed)d | open %(open)d' % stats)
new = [r for r in rows if r['verdict'] == 'NEW']
shown = [r for r in new if r['apply']]      # the ones that got an apply check are the relevant ones
order = lambda r: (r['surface'], r['apply'] != 'clean', not r['cvss'].startswith('AV:N'), r['cve'])
print('new since the last triage: %d (relevant vector or not yet scored: %d); full list: %s'
      % (len(new), len(shown), os.path.join(rdir, 'report.tsv')))
for r in sorted(shown, key=order):
    print('%-15s %-11s %-22s %-6s %-9s %-34s %s' % (r['cve'], r['surface'], r['cvss'], r['apply'], r['patch_from'],
                                                    r['files'].split(',')[0][:34], r['title'][:80]))
