#!/bin/bash
# Daily update — refreshes SEED_TAGS (pitch scan) + SEED_SHORTS (views/count)
# Runs every day at 9 AM via macOS LaunchAgent: com.nirmaan.pitchscan
# Run manually: bash /Users/cp/nirmaan-dashboard/scan_and_update.sh

set -e
REPO="/Users/cp/nirmaan-dashboard"
CAPS="/tmp/nirmaan_scan_caps"
mkdir -p "$CAPS"

echo "[$(date)] ── Nirmaan daily update starting ──"

python3 << 'PYEOF'
import re, os, json, urllib.request, datetime, subprocess

API_KEY = 'AIzaSyCNTUjiXTQ-ftrP1NCiqBQXKO2Vu6XWFXs'
UPLOADS_PLAYLIST = 'UUvCAK_O_4gB4OvHr765ZuQg'
REPO = '/Users/cp/nirmaan-dashboard'
CAPS = '/tmp/nirmaan_scan_caps'

# ─────────────────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────────────────
def yt_get(url):
    with urllib.request.urlopen(url) as r:
        return json.loads(r.read())

def fetch_all_uploads(days=92):
    """Return every upload from the last `days` days."""
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    items, page_token = [], ''
    while True:
        url = (f'https://www.googleapis.com/youtube/v3/playlistItems'
               f'?part=snippet,contentDetails&playlistId={UPLOADS_PLAYLIST}'
               f'&maxResults=50&key={API_KEY}')
        if page_token:
            url += f'&pageToken={page_token}'
        data = yt_get(url)
        stop = False
        for it in data.get('items', []):
            pub_dt = datetime.datetime.fromisoformat(
                it['contentDetails']['videoPublishedAt'].replace('Z', '+00:00'))
            if pub_dt < cutoff:
                stop = True
                break
            items.append(it)
        page_token = data.get('nextPageToken', '')
        if not page_token or stop:
            break
    return items

def parse_duration(dur_str):
    if not dur_str or dur_str == 'P0D':
        return 0
    m = re.match(r'P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?', dur_str)
    if not m:
        return 0
    d, h, mi, s = (int(m.group(i) or 0) for i in range(1, 5))
    return d * 86400 + h * 3600 + mi * 60 + s

# ─────────────────────────────────────────────────────────
# PART 1 — Pitch scan (SEED_TAGS)
# ─────────────────────────────────────────────────────────
print('\n[PITCH SCAN]')

PITCH_PATTERNS = {
    "pass999": [r"999", r"સુપર\s*પાસ", r"superpass", r"super\s*pass", r"સુપરપાસ",
                r"નિર્માણ\s*સુપર", r"nirmaan\s*super", r"nirmaan\s*pass", r"nirman\s*pass",
                r"6\s*મહિના", r"six\s*month"],
    "trial":   [r"ટ્રાયલ", r"trial", r"ફ્રી\s*ટ્રાયલ", r"free\s*trial", r"FREE\s*TRIAL",
                r"1\s*રૂ", r"₹\s*1\b", r"rs\.?\s*1\b", r"1\s*rupee", r"2\s*દિવસ",
                r"2\s*days", r"ઉપલબ્ધ\s*છે"],
    "pass499": [r"499"],
}

def clean_vtt(raw):
    seen, out = set(), []
    for line in raw.split('\n'):
        line = re.sub(r'<[^>]+>', '', line).strip()
        if re.match(r'^\d{2}:\d{2}', line) or line in ('WEBVTT', '') or '-->' in line:
            continue
        if line and line not in seen:
            seen.add(line)
            out.append(line)
    return ' '.join(out)

def detect_pitch(text):
    found = []
    for ptype, pats in PITCH_PATTERNS.items():
        for p in pats:
            if re.search(p, text, re.IGNORECASE):
                found.append(ptype)
                break
    return list(set(found))

# Fetch uploads and find live streams
upload_items = fetch_all_uploads(days=92)
all_upload_ids = [it['contentDetails']['videoId'] for it in upload_items]

live_ids = []
for i in range(0, len(all_upload_ids), 50):
    batch = all_upload_ids[i:i+50]
    data = yt_get(f'https://www.googleapis.com/youtube/v3/videos'
                  f'?part=liveStreamingDetails&id={",".join(batch)}&key={API_KEY}')
    for v in data.get('items', []):
        if v.get('liveStreamingDetails', {}).get('actualStartTime'):
            live_ids.append(v['id'])

# Load current SEED_TAGS
with open(f'{REPO}/index.html', encoding='utf-8') as f:
    html = f.read()
m = re.search(r'const SEED_TAGS = (\{.*?\});', html, re.DOTALL)
seed = json.loads(m.group(1))

to_scan = [v for v in live_ids if v not in seed or seed[v].get('pending')]
print(f'Live streams: {len(live_ids)} | Already scanned: {len(live_ids)-len(to_scan)} | To scan: {len(to_scan)}')

new_results = {}
for vid in to_scan:
    vtt = f'{CAPS}/{vid}.gu.vtt'
    subprocess.run(
        ['yt-dlp', '--write-auto-subs', '--skip-download', '--sub-langs', 'gu',
         '-o', f'{CAPS}/%(id)s.%(ext)s', f'https://www.youtube.com/watch?v={vid}'],
        capture_output=True, timeout=60)
    if os.path.exists(vtt):
        with open(vtt, encoding='utf-8') as f:
            raw = f.read()
        types = detect_pitch(clean_vtt(raw))
        new_results[vid] = {"types": types, "pending": False, "source": "transcript"}
        print(f'  {vid}: {types}')
    else:
        new_results[vid] = {"types": [], "pending": True, "error": "captions not ready"}
        print(f'  {vid}: pending')

updated_tags = {**seed, **new_results}
tags_json = json.dumps(updated_tags, ensure_ascii=False, separators=(',', ':'))
html = re.sub(r'const SEED_TAGS = \{.*?\};', f'const SEED_TAGS = {tags_json};', html, flags=re.DOTALL)
print(f'SEED_TAGS: {len(updated_tags)} entries ({len(new_results)} new/updated)')

# ─────────────────────────────────────────────────────────
# PART 2 — Shorts refresh (SEED_SHORTS)
# ─────────────────────────────────────────────────────────
print('\n[SHORTS REFRESH]')

# Re-use the same upload_items (already fetched above for pitch scan)
all_ids_with_meta = [
    {'id': it['contentDetails']['videoId'],
     'title': it['snippet'].get('title', ''),
     'publishedAt': it['contentDetails'].get('videoPublishedAt', '')[:10]}
    for it in upload_items
]

shorts = []
for i in range(0, len(all_ids_with_meta), 50):
    batch = all_ids_with_meta[i:i+50]
    ids_str = ','.join(v['id'] for v in batch)
    data = yt_get(f'https://www.googleapis.com/youtube/v3/videos'
                  f'?part=contentDetails,statistics,snippet&id={ids_str}&key={API_KEY}')
    for item in data.get('items', []):
        dur_secs = parse_duration(item['contentDetails'].get('duration', ''))
        title = item['snippet'].get('title', '')
        pub = item['snippet'].get('publishedAt', '')[:10]
        stats = item.get('statistics', {})
        is_short = dur_secs <= 180 or bool(re.search(r'#shorts?\b', title, re.IGNORECASE))
        if is_short:
            shorts.append({
                'id': item['id'],
                'title': title,
                'publishedAt': pub,
                'durationSeconds': dur_secs,
                'viewCount': int(stats.get('viewCount', 0)),
                'likeCount': int(stats.get('likeCount', 0)),
                'commentCount': int(stats.get('commentCount', 0)),
            })

shorts.sort(key=lambda x: x['publishedAt'], reverse=True)
total_views = sum(s['viewCount'] for s in shorts)
shorts_json = json.dumps(shorts, ensure_ascii=False, separators=(',', ':'))
html = re.sub(r'const SEED_SHORTS = \[.*?\];', f'const SEED_SHORTS = {shorts_json};', html, flags=re.DOTALL)
print(f'SEED_SHORTS: {len(shorts)} shorts, {total_views:,} total views')
if shorts:
    print(f'  Date range: {shorts[-1]["publishedAt"]} → {shorts[0]["publishedAt"]}')

# ─────────────────────────────────────────────────────────
# Write updated HTML
# ─────────────────────────────────────────────────────────
with open(f'{REPO}/index.html', 'w', encoding='utf-8') as f:
    f.write(html)
print('\nindex.html written.')
PYEOF

# Commit and push if anything changed
cd "$REPO"
if git diff --quiet index.html; then
    echo "[$(date)] No changes — nothing to push."
else
    git add index.html
    git commit -m "Daily update: pitch + shorts — $(date '+%d %b %Y')"
    GIT_SSH_COMMAND="ssh -i /Users/cp/.ssh/nirmaan_github -o StrictHostKeyChecking=no" \
        git push origin main
    echo "[$(date)] ✅ Pushed to GitHub — Netlify deploying now."
fi
