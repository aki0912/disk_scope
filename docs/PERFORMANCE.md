# 性能改善の測定

2026-09-27、macOS 27 / Apple Silicon、Swift 6.4、Rust 1.98.1のリリースビルドで測定。比較元は初回コミット `58f1242`。

| 処理・条件 | 改善前 | 改善後 | 短縮率 |
| --- | ---: | ---: | ---: |
| 1フォルダに5万ファイル：走査からJSON出力まで | 173.05 ms | 60.60 ms | 約65% |
| 200フォルダに合計5万ファイル：走査からJSON出力まで | 74.25 ms | 71.81 ms | 約3% |
| 5万項目から画面用の上位300件を選出 | 248.22 ms | 15.13 ms | 約94% |

走査の比較は同じ空ファイル群を使用し、変更前後を交互に実行。各バイナリの初回を除外し、続く8回の中央値を使用した。OSのキャッシュが温まった条件であり、初回読み込みや外部SSDの結果は異なる。分散したフォルダの差は小さく、明確な高速化とは判断していない。

走査時間にはプロセス起動、完了通知のポーリング、JSON生成、標準出力への転送を含む。Python側のJSON解析時間は含まない。Swiftの選出処理は、同じ容量の5万項目を使用し、元の全件ソートと上位選出の結果が一致することを毎回確認した。こちらも初回を除く8回の中央値。SwiftのJSONデコード、描画、アプリの起動時間はこの選出時間に含まない。

## 変更内容

- 大きいフォルダのメタデータ取得を512件ずつに分け、最大8ワーカーに分配。小さいフォルダは担当ワーカー内で処理し、キューの負荷を抑える。
- 完了結果のキューを16バッチに制限。キャンセル時に受信側を閉じ、送信待ちのワーカーが終了できるようにする。
- 進捗の共有カウンターをファイルごとではなくバッチ単位で更新する。
- 全件の並べ替えを廃止し、一覧は上位300件、ツリーマップの内部は上位45件だけをヒープで選出する。選出中に全項目の件数・容量を集計し、「その他」の面積を維持する。
- 名前検索も全項目を対象に上位を選出し、画面の再描画時に同じ検索を繰り返さない。

## 再測定

比較元のビルドを、無視対象の `build/` 以下に作成する。

```sh
mkdir -p build/baseline
git archive 58f1242 rust | tar -x -C build/baseline
cargo build --release --manifest-path build/baseline/rust/Cargo.toml --example scan
cargo build --release --manifest-path rust/Cargo.toml --example scan
python3 scripts/benchmark_scanner.py --baseline build/baseline/rust/target/release/examples/scan

swiftc -O Sources/DiskScopeCore/ScanData.swift Benchmarks/Selection.swift -o build/selection-benchmark
build/selection-benchmark
```

走査ベンチマークは一時フォルダを作成し、終了時に削除する。全項目の相対位置、種別、容量、日時、状態と、件数・エラー数が変更前後で一致することも確認する。通常の検証は `scripts/test.sh` で行い、13,304ファイルの容量照合、512件のバッチ境界、走査中キャンセル、上位選出・名前検索の一致を含む。
