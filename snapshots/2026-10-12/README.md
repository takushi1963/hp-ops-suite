# 稼働構成の保存 2026-10-12

現在配備されたHTML、監視・解析・バックアップスクリプト、関連systemd設定のコピー。manifest.jsonに配置先、SHA256、元の権限を記録する。ファイル名に含まれる日付は今回の現状保存用。

このスナップショットは自動復元・自動デプロイを行わない。復元時には現在のファイルと差分を確認し、必要なファイルだけ配置する。システム全体、DB、録音、秘密情報、Git認証設定は含まない。

確認済み: 日次rsyncは2026-10-11 02:01:49 JSTに終了コード0。低周波解析タイマー稼働。DDの画像と過去成功記録は存在するが、次回DDの完了確認と復元試験は未実施。

root cronの確認済みバックアップ予定:

```
0 2 * * * /bin/bash /home/taku/scripts/backup/backup_rsync.sh
0 2 * * 1 /bin/bash /home/taku/scripts/backup/backup_dd.sh
```

systemdの日次rsyncも02:00。週次DDは共通ロックを待つ。各ロック最大6時間、合計最大12時間待機。

現在のindex.htmlは統合ダッシュボードのレイアウト。元のレイアウトへ戻す作業は未完了であり、その前の現状を保存した。

backup/audio/adsbに残っていた不存在の.git/modules参照は退避し、親リポジトリによる通常ファイル管理へ戻した。退避先は/home/taku/git-registration-repair-20261012T002941。
