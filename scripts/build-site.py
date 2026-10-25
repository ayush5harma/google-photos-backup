#!/usr/bin/env python3
"""Build the static project site using the release version and approved artwork."""
from html.parser import HTMLParser
from pathlib import Path
import re
import shutil
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'build' / 'site'
ASSETS = ('app-icon.png', 'app-icon-dark.png', 'menu-bar-panel-light.png',
          'windows-connected-device-light.png', 'android-overview-dark.png')


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.targets = []
        self.ids = set()

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if 'id' in attrs:
            self.ids.add(attrs['id'])
        for key in ('href', 'src'):
            if attrs.get(key):
                self.targets.append(attrs[key])


def main():
    version = (ROOT / 'VERSION').read_text().strip()
    # The APK is signed outside CI, so Android can lag the desktop release.
    android_version = (ROOT / 'Android' / 'VERSION').read_text().strip()
    for value in (version, android_version):
        if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', value):
            raise ValueError('VERSION must be a release version')
    if OUTPUT.is_symlink() or (ROOT / 'build').is_symlink():
        raise ValueError('Build output must not be a symbolic link')
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    (OUTPUT / 'assets').mkdir(parents=True)
    for name in ('index.html', 'styles.css'):
        content = (ROOT / 'site' / name).read_text().replace('__ANDROID_VERSION__', android_version)
        content = content.replace('__VERSION__', version)
        if '__VERSION__' in content or '__ANDROID_VERSION__' in content:
            raise ValueError('Unresolved release version')
        (OUTPUT / name).write_text(content)
    for name in ASSETS:
        shutil.copyfile(ROOT / 'docs' / name, OUTPUT / 'assets' / name)
    (OUTPUT / '.nojekyll').touch()
    document = Links()
    document.feed((OUTPUT / 'index.html').read_text())
    for target in document.targets:
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc:
            if parsed.scheme != 'https':
                raise ValueError(f'Unexpected external URL: {target}')
            continue
        if parsed.path:
            local = (OUTPUT / parsed.path).resolve()
            if local.is_dir():
                local = local / 'index.html'
            if not local.is_relative_to(OUTPUT.resolve()) or not local.is_file():
                raise ValueError(f'Missing or escaping local asset: {target}')
        elif parsed.fragment and parsed.fragment not in document.ids:
            raise ValueError(f'Missing page anchor: {target}')
    print(f'Built Photos Backup {version}: {OUTPUT} ({len(document.targets)} links/assets checked)')


if __name__ == '__main__':
    main()
