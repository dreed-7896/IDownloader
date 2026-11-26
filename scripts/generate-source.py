#!/usr/bin/env python3
"""Generate a SideStore/AltStore/LiveContainer catalog from the built IPA."""
import datetime
import json
import plistlib
import sys
import zipfile
from pathlib import Path

ipa, download_url, output = sys.argv[1:]
with zipfile.ZipFile(ipa) as archive:
    paths = [p for p in archive.namelist() if p.startswith('Payload/') and p.count('/') == 2 and p.endswith('.app/Info.plist')]
    if len(paths) != 1:
        raise ValueError('Expected one top-level app Info.plist')
    info = plistlib.loads(archive.read(paths[0]))
assert info['CFBundleIdentifier'] == 'com.dreed7896.IDownloader'
assert info['CFBundleDisplayName'] == 'Drift'
assert info['CFBundleName'] in ('Drift', 'Stash', 'Pulled')  # product name stays Pulled for update continuity
version = {
    'version': info['CFBundleShortVersionString'],
    'buildVersion': info['CFBundleVersion'],
    'date': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
    'downloadURL': download_url,
    'size': Path(ipa).stat().st_size,
    'minOSVersion': info.get('MinimumOSVersion', '16.0'),
    'localizedDescription': 'Latest Drift build from main.',
}
source_url = 'https://github.com/dreed-7896/IDownloader/releases/download/nightly/source.json'
app = {
    'name': 'Drift',
    'bundleIdentifier': info['CFBundleIdentifier'],
    'developerName': 'Raahat',
    'subtitle': 'A light browser that saves any video',
    'localizedDescription': 'Drift is a minimal web browser that saves the videos you watch. Play a video on any site and tap the download button to save it, including HLS streams. Tabs, private tabs, bookmarks, history and an ad blocker. The Downloads tab keeps everything from before: parallel file downloads, torrents and magnet links, sharing from other apps, Live Activities, a video gallery and a built-in player.',
    'iconURL': 'https://raw.githubusercontent.com/dreed-7896/IDownloader/main/docs/branding/icon.png',
    'tintColor': '3DD6A3',
    'versions': [version],
    # Compatibility fields for source readers that use the legacy app format.
    'version': version['version'],
    'versionDate': version['date'],
    'versionDescription': version['localizedDescription'],
    'downloadURL': download_url,
    'size': version['size'],
    'appPermissions': {
        'entitlements': ['com.apple.security.application-groups'],
        'privacy': {k: v for k, v in info.items() if k.startswith('NS') and k.endswith('UsageDescription')},
    },
}
source = {
    'name': 'Drift',
    'identifier': 'com.dreed7896.IDownloader.source',
    'sourceURL': source_url,
    'website': 'https://github.com/dreed-7896/IDownloader',
    'subtitle': 'Latest Drift builds',
    'iconURL': app['iconURL'],
    'tintColor': app['tintColor'],
    'apps': [app],
    'news': [],
}
Path(output).write_text(json.dumps(source, indent=2) + '\n')
print(f"Published source metadata for Drift {version['version']} ({version['buildVersion']})")
