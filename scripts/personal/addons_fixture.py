"""Generate a local layout fixture using the candidate's actual add-ons stylesheet.

The cards are samples, not installed extensions. No profile data is read.
"""
import argparse
import html
from pathlib import Path
import zipfile
from ui_patch import ADDONS_CSS_ARCHIVE

NAMES = ['1Password – Password Manager', 'Always active Window – Always Visible',
         'Crunchyroll Comments', 'Private Internet Access', 'Return YouTube Dislike',
         'Share-A-Cart – Easily Share Shopping Carts', 'SponsorBlock for YouTube',
         'UnDistracted – Hide Facebook, YouTube Feeds', 'Video Speed Controller',
         'vidIQ Vision for YouTube', 'Wappalyzer – Technology profiler',
         'YouTube Auto Translate', 'Zotero Connector']


def generate(app, output):
    with zipfile.ZipFile(app / 'Contents/Resources/omni.ja') as archive:
        css = archive.read(ADDONS_CSS_ARCHIVE).decode()
    cards = ''.join('''<addon-card><div class="addon card"><div class="addon-card-collapsed">
      <span class="card-heading-icon addon-icon">%s</span><div class="card-contents">
      <div class="addon-name-container"><h3 class="addon-name" title="%s">%s</h3></div>
      <span class="addon-description">Sample extension card for layout verification.</span></div>
      <button aria-label="More options">⋯</button></div></div></addon-card>'''
      % (html.escape(name[0]), html.escape(name), html.escape(name)) for name in NAMES)
    fixture_style = '''
      :root { font: 16px system-ui; color-scheme: dark;
        --space-large: 16px; --space-medium: 16px; --space-xxlarge: 32px;
        --main-margin-start: 0px; --main-margin-end: 0px;
        --page-main-content-width: 664px; --z-index-popup: 10;
        --text-color: #fbfbfe; --text-color-deemphasized: #cfcfd8; }
      html, body { margin: 0; padding: 0; background: #1c1b22; color: #fbfbfe; }
      #main { margin: 0; }
      .card { padding: 16px; border: 1px solid #36343e; border-radius: 10px;
        background: #23222b; box-sizing: border-box; }
      .addon-icon { display: inline-flex; align-items: center; justify-content: center;
        flex: 0 0 32px; height: 32px; margin-inline-end: 16px; }
      button { align-self: start; flex: 0 0 auto; margin-inline-start: 8px; }
    '''
    body = '<div id="content"><div id="main"><addon-list type="extension"><section><h2 class="list-section-heading">Enabled</h2>' + cards + '</section></addon-list></div></div>'
    sample = '<!doctype html><meta charset="utf-8"><style>' + css + fixture_style + '</style>' + body
    previews = ''
    for width, expected in [(1500, 3), (1000, 2), (700, 1), (320, 1)]:
        scale = min(1, 1000 / width)
        previews += '<section><h2>%d px available list width</h2><p class="result">Checking…</p><div style="width:%dpx;height:300px;overflow:hidden"><iframe title="%d px sample extensions" data-expected="%d" style="width:%dpx;height:900px;transform:scale(%f);transform-origin:top left" srcdoc="%s"></iframe></div></section>' % (width, int(width * scale), width, expected, width, scale, html.escape(sample, quote=True))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text('''<!doctype html><meta charset="utf-8"><title>Responsive add-ons layout verification</title>
      <style>body{font:16px system-ui;background:#1c1b22;color:#fbfbfe;margin:24px}
      section{margin-block:32px} iframe{border:0} .result{color:#a7e8b7}
      h1{font-size:24px} h2{font-size:18px}</style>
      <h1>Responsive add-ons layout — sample cards</h1>
      <p>Candidate stylesheet rendered in this browser. No extensions are installed by this fixture.</p>'''
      + previews + '''<script>
      for (const frame of document.querySelectorAll('iframe')) {
        frame.addEventListener('load', () => requestAnimationFrame(() => requestAnimationFrame(() => {
          const doc = frame.contentDocument;
          const cards = [...doc.querySelectorAll('addon-card')];
          const top = cards[0].getBoundingClientRect().top;
          const columns = cards.filter(card => Math.abs(card.getBoundingClientRect().top - top) < 1).length;
          const overflow = doc.documentElement.scrollWidth > doc.documentElement.clientWidth + 1;
          const pass = columns === Number(frame.dataset.expected) && !overflow;
          frame.closest('section').querySelector('.result').textContent =
            `${pass ? 'PASS' : 'FAIL'}: ${columns} column${columns === 1 ? '' : 's'}; ${overflow ? 'horizontal overflow' : 'no horizontal overflow'}.`;
        })));
      }
      </script>''')
    print(output.resolve())


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    generate(args.app, args.output)
