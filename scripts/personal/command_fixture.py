#!/usr/bin/env python3
"""Loopback-only native command fixture; no user data or external services."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json

RESOURCE_REQUESTS = 0
PAGE = b'''<!doctype html><meta charset="utf-8"><title>Zen Command Test</title>
<style>body{font:20px system-ui;max-width:750px;margin:80px auto;line-height:1.6}p{padding:8px;background:#edf3ff}</style>
<h1>Zen Command Test</h1><p id="resource"></p><p id="state"></p>
<article><h2>Native browser command verification</h2>
Use this neutral page for zoom, cache refresh, toolbar and developer-tool checks.
Network cache refresh should fetch a new resource response. The synthetic cookie
and local storage marker should remain available. Nothing on this page contains
accounts, credentials, personal data or a connection to an outside website.</article>
<script src="/resource.js"></script><script>
if(!sessionStorage.getItem('initialized')) {
 document.cookie='zen_command_test=present; SameSite=Lax; path=/';
 localStorage.setItem('zen_command_test','present');
 sessionStorage.setItem('initialized','true');
}
document.getElementById('resource').textContent='Resource response: '+window.resourceResponse;
document.getElementById('state').textContent='Cookie: '+(document.cookie.includes('zen_command_test=present')?'kept':'missing')+
'; Local storage: '+(localStorage.getItem('zen_command_test')==='present'?'kept':'missing');
</script>'''

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        global RESOURCE_REQUESTS
        if self.path == '/resource.js':
            RESOURCE_REQUESTS += 1
            data = f'window.resourceResponse={RESOURCE_REQUESTS};'.encode()
            kind, cache = 'text/javascript', 'public, max-age=3600'
        elif self.path == '/counts':
            data = json.dumps({'resource_requests': RESOURCE_REQUESTS}).encode()
            kind, cache = 'application/json', 'no-store'
        else:
            data, kind, cache = PAGE, 'text/html; charset=utf-8', 'no-store'
        self.send_response(200)
        self.send_header('Content-Type', kind)
        self.send_header('Cache-Control', cache)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(f'http://127.0.0.1:{server.server_port}/', flush=True)
    server.serve_forever()
