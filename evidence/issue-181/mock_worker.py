#!/usr/bin/env python3
"""r2-gallery #181 実機検証用のモック Worker。

一覧は 600 件（200 x 3ページ）を cursor ページングで返す。
2ページ目（cursor=c1）の最初の要求だけ HTTP 500 を返し、
旧実装なら「頼んだ時の件数」ラッチで 200 件に固まり、
新実装ならバックオフ後に自動で頼み直して続きに進む。

- GET /v1/libraries            → ライブラリ1件
- GET /v1/m/folders            → cursor なし: items 1-200 + cursor c1
                                  cursor=c1 : 初回のみ 500、以降 items 201-400 + cursor c2
                                  cursor=c2 : items 401-600 + cursor null
- GET /img/<key>               → 1px PNG（サムネ用）
- その他                        → 空の正常系 JSON
全アクセスを mock_worker.log に記録する。
"""
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT = 8123
LOG = "/tmp/r2g-181-verify/mock_worker.log"
TOTAL = 600
PAGE = 200
PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d494844520000000100000001080600000"
    "01f15c4890000000d49444154789c626001000000ffff030000060005"
    "57bfabd40000000049454e44ae426082"
)

# 番号入りサムネのキャッシュ（スクロール位置を目視できるよう、アイテム番号を描く）
_img_cache = {}

def numbered_png(i):
    if i in _img_cache:
        return _img_cache[i]
    from io import BytesIO
    from PIL import Image, ImageDraw
    im = Image.new("RGB", (240, 240), (30 + (i * 37) % 60, 30, 40))
    d = ImageDraw.Draw(im)
    d.text((60, 100), str(i), fill=(255, 220, 80))
    b = BytesIO()
    im.save(b, "PNG")
    data = b.getvalue()
    _img_cache[i] = data
    return data
# c1（2ページ目）の初回だけ応答を20秒遅らせる。その間に同じ並びの取り直し
# （引っ張って更新）が入ると、旧実装は戻ってきた応答を捨てて200件に固まり、
# 新実装は続きを頼み直す
slow_c1 = {"done": False}


def item(i):
    key = f"ph-{i:04d}.jpg"
    return {
        "key": key,
        "type": "photo",
        "url": f"http://127.0.0.1:{PORT}/img/{key}",
        "thumbUrl": f"http://127.0.0.1:{PORT}/img/{key}",
        "createdAt": 1763464000 + (TOTAL - i) * 60,
        "size": 1,
        "lib": "m",
        "thumbStored": True,
    }


def page(start, cursor_out):
    return {
        "items": [item(i) for i in range(start, min(start + PAGE, TOTAL + 1))],
        "cursor": cursor_out,
        "prefix": "",
        "folders": [],
        "total": TOTAL,
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
            return self._json({"libraries": [{"id": "m", "title": "Mock181"}]})

        if p == "/v1/m/folders":
            cursor = q.get("cursor", [""])[0] or None
            if cursor is None:
                slow_c1["done"] = False
                return self._json(page(1, "c1"))
            if cursor == "c1":
                if not slow_c1["done"]:
                    slow_c1["done"] = True
                    self._log("→ slow response (45s)")
                    time.sleep(45)
                return self._json(page(201, "c2"))
            if cursor == "c2":
                return self._json(page(401, None))
            return self._json({"items": [], "cursor": None, "prefix": "",
                               "folders": [], "total": TOTAL})

        if p.startswith("/img/"):
            try:
                n = int(p.rsplit("-", 1)[1].split(".")[0])
            except (ValueError, IndexError):
                n = 0
            body = numbered_png(n)
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
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
    HTTPServer(("0.0.0.0", PORT), H).serve_forever()
