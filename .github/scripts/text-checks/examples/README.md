# 書き方チェックと公開内容チェックの例

- `issue_ok.md` / `pr_ok.md` / `public_ok.md` は通る例（終了コード 0）。
- `issue_ng.md` / `pr_ng.md` は引っかかる例（終了コード 1）。
- 公開内容チェックの引っかかる例は、作り物の鍵などを含むため、ファイルには置かず
  `script/tests/test_text_checks.py` の中で文字をつないで作る（鍵の検査に誤って当たらないように）。

- `issue_skillsheet_example.md`（feature / bugfix の見出し）、`issue_skillsheet_task_example.md`、
  `pr_skillsheet_example.md` は、使う側の見出しの例です。設定なしでは足りないになり、
  `config_skillsheet_example.json` を付けると通ります。別名は kouiso/brain #135 の対応表どおりです。
- `issue_skillsheet_empty.md` は、別名の見出しがあるが中身が空の例です。設定ありでも足りないになります。
