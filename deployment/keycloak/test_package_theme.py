import hashlib
from pathlib import Path
import tempfile
import unittest

from package_theme import package, THEMES


class PackageThemeTest(unittest.TestCase):
    def test_shared_script_keeps_existing_branding_and_unrelated_scripts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            chart = root / 'identity/runtime/chart'
            chart.mkdir(parents=True)
            (chart / 'Chart.yaml').write_text('name: identity\n')
            for theme in ('wald', 'vereiner'):
                login = chart / 'files/themes' / theme / 'login'
                (login / 'resources/js').mkdir(parents=True)
                (login / 'theme.properties').write_text(
                    'parent=keycloak.v2\nstyles=css/brand.css\nfavicons=img/brand.svg\n'
                    'scripts=js/other.js js/registration.old.js\n')
                (login / 'resources/js/registration.old.js').write_text('obsolete')
                (login / 'resources/js/other.js').write_text('keep')
            filename = package(root, themes=THEMES)
            shared = None
            for theme in THEMES:
                login = chart / 'files/themes' / theme / 'login'
                script = (login / 'resources/js' / filename).read_bytes()
                self.assertEqual(filename, 'registration.' + hashlib.sha256(script).hexdigest()[:12] + '.js')
                self.assertEqual(script, script if shared is None else shared)
                shared = script
                properties = (login / 'theme.properties').read_text()
                if theme in ('wald', 'vereiner'):
                    self.assertIn('styles=css/brand.css\nfavicons=img/brand.svg', properties)
                    self.assertIn('scripts=js/other.js js/' + filename, properties)
                    self.assertEqual((login / 'resources/js/other.js').read_text(), 'keep')
                    self.assertFalse((login / 'resources/js/registration.old.js').exists())
                if theme == 'rfind-registration':
                    self.assertIn('parent=rfind', properties)
            self.assertEqual(package(root, themes=THEMES), filename)
            self.assertFalse((chart / 'files/themes/master').exists())
            # Go-git rejects Windows device names even on the Linux Fleet agent.
            self.assertFalse((chart / 'files/themes/con').exists())


if __name__ == '__main__':
    unittest.main()
