# 元レイアウト復元

変更前の実公開HTMLを根拠にCSSを完全保持、GLOBAL LINKS、FEED、CRITICAL、OPS HEALTH、FINGERPRINT、AUDIO、BACKUP、OPS SUMMARYの順序を保持する。元の6列FEED表と6つの要約カードを保持。

古い取得JSは戻さず、現在のdashboard.jsonへ安全に接続する。HTTP/形式/鮮度チェック、1回ずつの取得、8秒timeout、失敗時の現在値消去、textContentと安全な音声URLを使用。数値0を表示。404になっていた静的RMS画像は同じ位置のSVGに置き換える。低周波はOPS SUMMARYへ表示。

公開ルートHTMLとその2つの元ソース、および新JSのみ変更。ADSB専用ページやバックアップ処理は変更しない。2026-10-12 09:13 JSTに適用済み。HTTP配信とDOM検証を確認。

```bash
sudo python3 /home/taku/index-layout-restore-20261012/install.py --apply
```

変更前SHA検査、ファイル退避、配置失敗時復元付き。復元コマンドは適用時表示。DB操作、監視collector実行、DD起動は行わない。新しいHTMLが一時的にJS未配置の状態を参照しないようJSから配置する。

検証: 元CSS一致、h2順序一致、IDの一意性と描画先一致、Node構文とDOM検証。実ブラウザによる画像比較は未実施。
