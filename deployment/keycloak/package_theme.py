"""Package shared registration behavior while retaining each realm's branding."""
import argparse
import hashlib
from pathlib import Path


THEMES = ('con-registration', 'wald', 'vereiner', 'rfind-registration')


def package(fleet_root, *, themes=('con-registration',)):
    source = Path(__file__).parent / 'themes/con-registration/login'
    if not (Path(fleet_root) / 'identity/runtime/chart/Chart.yaml').is_file():
        raise ValueError('Expected a Fleet worktree containing the identity chart')
    script = (source / 'resources/js/registration.js').read_bytes()
    filename = 'registration.' + hashlib.sha256(script).hexdigest()[:12] + '.js'
    for theme in themes:
        if theme not in THEMES:
            raise ValueError('Unsupported registration theme: ' + theme)
        target = Path(fleet_root) / 'identity/runtime/chart/files/themes' / theme / 'login'
        # Branded Wald/Vereiner properties stay owned by Fleet. RFInD inherits
        # its runtime image theme rather than masking its assets/footer/messages.
        properties = Path(__file__).parent / 'themes' / theme / 'login/theme.properties'
        text = (properties if properties.is_file() else target / 'theme.properties').read_text()
        lines = text.splitlines()
        for index, line in enumerate(lines):
            if line.startswith('scripts='):
                existing = [item for item in line[8:].split()
                            if not item.startswith('js/registration.')]
                lines[index] = 'scripts=' + ' '.join([*existing, 'js/' + filename])
                break
        else:
            lines.append('scripts=js/' + filename)
        scripts = target / 'resources/js'
        scripts.mkdir(parents=True, exist_ok=True)
        (scripts / filename).write_bytes(script)
        (target / 'theme.properties').write_text('\n'.join(lines) + '\n')
        for old in scripts.glob('registration.*.js'):
            if old.name != filename:
                old.unlink()
    return filename


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fleet_root', type=Path)
    parser.add_argument('--theme', action='append', choices=THEMES, dest='themes')
    args = parser.parse_args()
    print(package(args.fleet_root, themes=args.themes or ('con-registration',)))
