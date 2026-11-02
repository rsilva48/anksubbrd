#!/usr/bin/env python3
"""Generate an AltStore-style source from the actual packaged IPA."""
import argparse
import datetime
import hashlib
import json
import pathlib
import plistlib
import re
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ipa', required=True, type=pathlib.Path)
    parser.add_argument('--notes', required=True, type=pathlib.Path)
    parser.add_argument('--output', required=True, type=pathlib.Path)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository):
        parser.error('Invalid repository')
    if not re.fullmatch(r'v\d+\.\d+\.\d+', args.tag):
        parser.error('Invalid tag')
    if not re.fullmatch(r'[0-9a-fA-F]{40}', args.commit):
        parser.error('Invalid commit')
    with zipfile.ZipFile(args.ipa) as archive:
        paths = [name for name in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', name)]
        if len(paths) != 1:
            raise ValueError('Expected exactly one application Info.plist in IPA')
        info = plistlib.loads(archive.read(paths[0]))
    version = info['CFBundleShortVersionString']
    if version != args.tag[1:]:
        raise ValueError('IPA version does not match release tag')
    with args.ipa.open('rb') as ipa_file:
        digest = hashlib.file_digest(ipa_file, 'sha256').hexdigest()
    owner, repo = args.repository.split('/')
    icon_url = f'https://raw.githubusercontent.com/{args.repository}/{args.commit}/ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
    download_url = f'https://github.com/{args.repository}/releases/download/{args.tag}/{args.ipa.name}'
    version_info = {
        'version': version, 'buildVersion': str(info['CFBundleVersion']),
        'date': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
        'localizedDescription': args.notes.read_text(encoding='utf-8'),
        'downloadURL': download_url, 'size': args.ipa.stat().st_size,
        'sha256': digest, 'minOSVersion': info['MinimumOSVersion'],
    }
    source = {
        'name': 'AniBridge Player', 'identifier': f'io.github.{owner.lower()}.{repo.lower()}',
        'subtitle': 'Reproductor personal con subtítulos para AirPlay',
        'website': f'https://github.com/{args.repository}', 'iconURL': icon_url,
        'apps': [{
            'name': 'AniBridge Player', 'bundleIdentifier': info['CFBundleIdentifier'],
            'developerName': owner, 'localizedDescription': 'Reproductor personal para iPhone y iPad con bridge propio y subtítulos AirPlay.',
            'iconURL': icon_url, 'tintColor': '4B49D6', 'versions': [version_info],
        }], 'news': [],
    }
    args.output.write_text(json.dumps(source, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'Generated {args.output}: {version}, {version_info["size"]} bytes')


if __name__ == '__main__':
    main()
