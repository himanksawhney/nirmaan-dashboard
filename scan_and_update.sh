#!/bin/bash
# Daily pitch scan — scans new/pending videos and updates SEED_TAGS in index.html
# Run: bash /Users/cp/nirmaan-dashboard/scan_and_update.sh

set -e
REPO="/Users/cp/nirmaan-dashboard"
CAPS="/tmp/nirmaan_scan_caps"
mkdir -p "$CAPS"

echo "[$(date)] Starting daily pitch scan..."

python3 << 'PYEOF'
import re, os, json, urllib.request, datetime, subprocess, tempfile

API_KEY = 'AIzaSyCNTUjiXTQ-ftrP1NCiqBQXKO2Vu6XWFXs'
CHANNEL_ID = 'UCvCAK_O_4gB4OvHr765ZuQg'
UPLOADS_PLAYLIST = 'UUvCAK_O_4gB4OvHr765ZuQg'
REPO = '/Users/cp/nirmaan-dashboard'
CAPS = '/tmp/nirmaan_scan_caps'

PITCH_PATTERNS = {
    "pass999": [r"999", r"સુપર\s*પાસ", r"superpass", r"super\s*pass", r"સુપરપાસ",
                r"નિર્માણ\s*સુપર", r"nirmaan\s*super", r"nirmaan\s*pass", r"nirman\s*pass", r"6\s*મહિના", r"six\s*month"],
    "trial":   [r"ટ્રાયલ", r"trial", r"ફ્રી\s*ટ્રાયલ", r"free\s*trial", r"FREE\s*TRIAL",
                r"1\s*રૂ", r"₹\s*1\b", r"rs\.?\s*1\b", r"1\s*rupee", r"2\s*દિવસ", r"2\s*days", r"ઉપલબ્ધ\s*છે"],
    "pass499": [r"499"],
}

def clean_vtt(raw):
    seen, out = set(), []
    for line in raw.split('\n'):
        line = re.sub(r'<[^>]+>', '', line).strip()
        if re.match(r'^\d{2}:\d{2}', line) or line in ('WEBVTT','') or '-->' in line:
            continue
        if line and line not in seen:
            seen.add(line); out.append(line)
    return ' '.join(out)

def detect(text):
    found = []
    for ptype, pats in PITCH_PATTERNS.items():
        for p in pats:
            if re.search(p, text, re.IGNORECASE):
                found.append(ptype); break
    return list(set(found))

# 1. Fetch all live stream IDs from last 3 months
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=92)
all_ids, page_token = [], ''
while True:
    url = (f'https://www.googleapis.com/youtube/v3/playlistItems?part=snippet,contentDetails'
           f'&playlistId={UPLOADS_PLAYLIST}&maxResults=50&key={API_KEY}')
    if page_token: url += f'&pageToken={page_token}'
    with urllib.request.urlopen(url) as r: data = json.loads(r.read())
    stop = False
    for it in data.get('items', []):
        pub_dt = datetime.datetime.fromisoformat(it['contentDetails']['videoPublishedAt'].replace('Z','+00:00'))
        if pub_dt < cutoff: stop = True; break
        all_ids.append(it['contentDetails']['videoId'])
    page_token = data.get('nextPageToken', '')
    if not page_token or stop: break

# Filter live streams
live_ids = []
for i in range(0, len(all_ids), 50):
    batch = all_ids[i:i+50]
    url = f'https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id={",".join(batch)}&key={API_KEY}'
    with urllib.request.urlopen(url) as r: data = json.loads(r.read())
    for v in data.get('items', []):
        if v.get('liveStreamingDetails', {}).get('actualStartTime'): live_ids.append(v['id'])

# 2. Load SEED_TAGS
with open(f'{REPO}/index.html', encoding='utf-8') as f: html = f.read()
m = re.search(r'const SEED_TAGS = (\{.*?\});', html, re.DOTALL)
seed = json.loads(m.group(1))

# 3. Scan missing/pending
to_scan = [v for v in live_ids if v not in seed or seed[v].get('pending')]
print(f'Live streams: {len(live_ids)} | Already scanned: {len(live_ids)-len(to_scan)} | To scan: {len(to_scan)}')

new_results = {}
for vid in to_scan:
    vtt = f'{CAPS}/{vid}.gu.vtt'
    subprocess.run(['yt-dlp','--write-auto-subs','--skip-download','--sub-langs','gu',
                    '-o',f'{CAPS}/%(id)s.%(ext)s', f'https://www.youtube.com/watch?v={vid}'],
                   capture_output=True, timeout=60)
    if os.path.exists(vtt):
        with open(vtt, encoding='utf-8') as f: raw = f.read()
        types = detect(clean_vtt(raw))
        new_results[vid] = {"types": types, "pending": False, "source": "transcript"}
        print(f'  {vid}: {types}')
    else:
        new_results[vid] = {"types": [], "pending": True, "error": "captions not ready"}
        print(f'  {vid}: pending')

# 4. Update SEED_TAGS
updated = {**seed, **new_results}
new_seed_json = json.dumps(updated, ensure_ascii=False, separators=(',',':'))
new_html = re.sub(r'const SEED_TAGS = \{.*?\};', f'const SEED_TAGS = {new_seed_json};', html, flags=re.DOTALL)
with open(f'{REPO}/index.html', 'w', encoding='utf-8') as f: f.write(new_html)
print(f'SEED_TAGS updated: {len(updated)} entries ({len(new_results)} new)')
PYEOF

# 5. Commit and push if changed
cd "$REPO"
if git diff --quiet index.html; then
    echo "[$(date)] No changes — nothing to push."
else
    git add index.html
    git commit -m "Daily pitch scan update — $(date '+%d %b %Y')"
    GIT_SSH_COMMAND="ssh -i /Users/cp/.ssh/nirmaan_github -o StrictHostKeyChecking=no" git push origin main
    echo "[$(date)] Pushed updated SEED_TAGS to GitHub ✓"
fi
