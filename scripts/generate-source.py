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
assert info['CFBundleDisplayName'] == 'IDownloader'
assert info['CFBundleName'] == 'IDownloader'
version = {
    'version': info['CFBundleShortVersionString'],
    'buildVersion': info['CFBundleVersion'],
    'date': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
    'downloadURL': download_url,
    'size': Path(ipa).stat().st_size,
    'minOSVersion': info.get('MinimumOSVersion', '16.0'),
    'localizedDescription': 'Latest IDownloader testing build from main.',
}
source_url = 'https://github.com/dreed-7896/IDownloader/releases/download/nightly/source.json'
app = {
    'name': 'IDownloader',
    'bundleIdentifier': info['CFBundleIdentifier'],
    'developerName': 'Raahat',
    'subtitle': 'Download files and torrents on iOS',
    'localizedDescription': 'IDownloader downloads HTTP/HTTPS files with parallel connections and automatic single-part fallback, plus torrents and magnet links. Includes URL sharing, Live Activities and Dynamic Island progress, RSS feeds, file management, and a built-in video player. This source provides the latest testing build after every successful main build.',
    'iconURL': 'https://raw.githubusercontent.com/dreed-7896/IDownloader/main/docs/branding/icon.png',
    'tintColor': '2563EB',
    'versions': [version],
    # Compatibility fields for source readers that use the legacy app format.
    'version': version['version'],
    'versionDate': version['date'],
    'versionDescription': version['localizedDescription'],
    'downloadURL': download_url,
    'size': version['size'],
    'appPermissions': {
        'entitlements': [],
        'privacy': [{'name': k, 'usageDescription': v} for k, v in info.items() if k.startswith('NS') and k.endswith('UsageDescription')],
    },
}
source = {
    'name': 'IDownloader',
    'identifier': 'com.dreed7896.IDownloader.source',
    'sourceURL': source_url,
    'website': 'https://github.com/dreed-7896/IDownloader',
    'subtitle': 'Latest IDownloader testing builds',
    'iconURL': app['iconURL'],
    'tintColor': app['tintColor'],
    'apps': [app],
    'news': [],
}
Path(output).write_text(json.dumps(source, indent=2) + '\n')
print(f"Published source metadata for IDownloader {version['version']} ({version['buildVersion']})")
