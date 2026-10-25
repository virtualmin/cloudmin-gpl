"""Theme metadata used by live tests on the installed Webmin tree."""
from pathlib import Path
import re


# theme_info(name) reads capabilities without tying checks to a directory name.
def theme_info(name):
    # Keep the metadata lookup within one installed theme directory.
    if not re.fullmatch(r'[a-z0-9-]+', name):
        raise ValueError('Invalid theme directory')
    webmin = Path(__file__).resolve().parents[3]
    return dict(line.split('=', 1) for line in
                (webmin / name / 'theme.info').read_text().splitlines()
                if '=' in line and not line.startswith('#'))


# is_spa_theme(name) distinguishes SPA navigation from full-page rendering.
def is_spa_theme(name):
    return theme_info(name).get('spa') == '1'
