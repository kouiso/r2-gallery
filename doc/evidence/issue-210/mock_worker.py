#!/usr/bin/env python3
"""r2-gallery #210 実機検証用のモック Worker。

- GET /v1/libraries            → ライブラリ1件（接続プローブを通す）
- GET /v1/m/folders            → prefix なし: 期限切れ URL の動画1件（グリッド用）
                                  prefix=key : 同じキーの新 URL 行（objectAt 相当）
- GET /expired.mp4             → 常に 403（期限切れ署名 URL 相当）
- GET /fresh.mp4               → 実際に再生できる小さい mp4
- その他                        → 空の正常系 JSON
全アクセスを mock_worker.log に記録して、objectAt 引き直しの証跡にする。
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT = 8123
KEY = "vid-210.mp4"
LOG = "/tmp/r2g-210-verify/mock_worker.log"
MP4 = "/tmp/r2g-210-verify/fresh.mp4"

EXPIRED_URL = f"http://127.0.0.1:{PORT}/expired.mp4?e=1&sig=fake"
FRESH_URL = f"http://127.0.0.1:{PORT}/fresh.mp4"


def item(url):
    return {
        "key": KEY,
        "type": "video",
        "url": url,
        "createdAt": int(time.time()),
        "size": 1,
        "lib": "m",
        "thumbStored": True,
    }


class H(BaseHTTPRequestHandler):
    def _log(self, extra=""):
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {self.command} {self.path} {extra}\n")

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._log()
        u = urlparse(self.path)
        q = parse_qs(u.query)
        p = u.path.rstrip("/")

        if p == "/v1/libraries":
            return self._json({"libraries": [{"id": "m", "title": "Mock210"}]})

        if p == "/v1/m/folders":
            prefix = q.get("prefix", [""])[0]
            if prefix == KEY:
                # objectAt(lib,key) → 取り直し後の新 URL 行
                return self._json({"items": [item(FRESH_URL)], "cursor": None,
                                   "prefix": prefix, "folders": [], "total": 1})
            # 一覧: 期限切れ（e=1）の URL を返す
            return self._json({"items": [item(EXPIRED_URL)], "cursor": None,
                               "prefix": prefix, "folders": [], "total": 1})

        if p == "/expired.mp4":
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if p == "/fresh.mp4":
            with open(MP4, "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # その他の起動時コール（albums/trash/meta 等）は空を返す
        return self._json({"items": [], "folders": [], "albums": [],
                           "cursor": None, "meta": None, "total": 0})

    def do_POST(self):
        self._log()
        self._json({})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    open(LOG, "w").close()
    HTTPServer(("127.0.0.1", PORT), H).serve_forever()
