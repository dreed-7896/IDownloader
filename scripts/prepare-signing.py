#!/usr/bin/env python3
"""Preserve group entitlements in the IPA so sideloaders can register/remap them."""
import plistlib
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
root = Path(__file__).resolve().parent.parent
group = 'group.com.dreed7896.IDownloader.live-activity'


def sign(bundle, entitlements=None):
    command = ['codesign', '--force', '--sign', '-', '--timestamp=none', '--generate-entitlement-der']
    if entitlements:
        command += ['--entitlements', str(root / entitlements)]
    subprocess.run(command + [str(bundle)], check=True)


# Sign dependencies first, then extensions, then seal the containing app.
dependencies = list(app.rglob('*.framework')) + list(app.rglob('*.dylib'))
for dependency in sorted(dependencies, key=lambda p: len(p.parts), reverse=True):
    sign(dependency)

bundles = [
    (app / 'PlugIns/ShareExtension.appex', 'ShareExtension/ShareExtension.entitlements'),
    (app / 'PlugIns/ProgressWidgetExtension.appex', 'ProgressWidget/ProgressWidgetExtension.entitlements'),
    (app, 'iTorrent/Core/Assets/iTorrent.entitlements'),
]
for bundle, entitlements in bundles:
    sign(bundle, entitlements)
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(bundle)],
                            check=True, capture_output=True)
    actual = plistlib.loads(result.stdout)
    assert actual['com.apple.security.application-groups'] == [group], (bundle, actual)
    print(f'Verified App Group entitlement: {bundle.name}')

subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
