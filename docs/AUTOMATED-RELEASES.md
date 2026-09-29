# PRのマージ後にDMGを自動配布する

リポジトリの管理者向けの手順です。初回は「認証情報を登録する」を実行してください。以後はPRを`main`へマージすると、GitHub Actionsがテスト、ビルド、Developer ID署名、Appleの公証、DMG作成を行い、GitHub Releasesへプレビュー版として公開します。

## 認証情報を登録する

証明書が入っているMacで、プロジェクトのターミナルから実行します。Python 3、Xcode、ログイン済みのGitHub CLI（`gh`）が必要です。

```sh
python3 scripts/configure_release_secrets.py
```

Developer ID Application証明書を選び、Apple Accountのメールアドレスと公証用のアプリ用パスワードを入力します。macOSの確認が出た場合は、選んだ秘密鍵の書き出しを許可してください。通常のApple Accountパスワードを入力する必要はありません。

スクリプトは選んだ証明書と秘密鍵だけを、一時的なパスワード付きPKCS#12ファイルに書き出します。次の値を`aki0912/disk_scope`のGitHub Actions Secretsへ登録し、一時ファイルを削除します。秘密情報をソースやチャットへ貼り付ける必要はありません。

| Secret | 内容 |
| --- | --- |
| `SIGNING_CERTIFICATE_BASE64` | 証明書と秘密鍵を含む暗号化済みPKCS#12 |
| `SIGNING_CERTIFICATE_PASSWORD` | PKCS#12用に自動生成したパスワード |
| `SIGNING_IDENTITY` | 選択した証明書のSHA-1識別子 |
| `APPLE_ID` | 公証に使うApple Account |
| `APPLE_TEAM_ID` | 証明書のTeam ID |
| `APPLE_APP_PASSWORD` | 公証用のアプリ用パスワード |

このMacに保存した`DiskScope-notary`プロファイルは、GitHubの一時実行環境には引き継がれません。上記の登録は初回と、証明書・パスワードを更新したときに必要です。途中で失敗した場合は、同じコマンドを実行し直してください。

## マージ後の結果を確認する

GitHubのActionsで`Build signed DMG`を開きます。すべて成功すると、ReleasesにDMGとSHA-256ファイルが表示されます。実行中は下書きとして作成し、添付ファイルをダウンロードして一致を確認してから公開します。

起動条件は`main`へのpushです。PRのマージに加えて、`main`への直接pushでも実行します。手動実行はActionsの`Run workflow`から`main`を指定します。未マージのPRや別ブランチからは署名・公開しません。

失敗した場合はActionsの失敗ステップを確認し、原因を解消して`Re-run failed jobs`で再実行します。作成途中の下書きは再利用し、公開済みの同じリリースは上書きしません。認証エラーはSecrets、コンパイルエラーはソース、公証エラーはAppleの提出結果を確認してください。解決しない場合は、秘密情報を除いた実行URLとエラー内容を管理者へ共有してください。

## リリース番号の付け方

`Info.plist`のアプリ版番号と、ワークフローの実行番号を組み合わせます。例は`v0.1.0-build.42`、ファイル名は`DiskScope-0.1.0-build.42-arm64.dmg`です。アプリの`CFBundleVersion`にも実行番号を設定します。ソースの`Info.plist`は自動変更しません。

再実行時は同じ番号、新しいpushでは新しい番号になります。正式な版番号を上げるときは`Info.plist`と`docs/INSTALL-ja.txt`を変更してください。自動版は常にプレビュー版で、既存の正式版のLatest指定を変更しません。

## 追加費用が発生しない構成

公開リポジトリの標準`macos-26`ランナーだけを使います。リポジトリが非公開になった場合や、別のリポジトリへコピーされた場合は、ジョブ開始前にスキップします。有料の大型ランナー、Actionsの成果物保存、追加のキャッシュ保存は使用せず、DMGはReleasesへ直接添付します。

公開リポジトリの標準ランナーは[GitHubの料金条件](https://docs.github.com/en/billing/concepts/product-billing/github-actions)で無料です。Apple Developer Programの既存の年会費は別途必要です。料金条件を変更する機能や課金設定は、このワークフローでは操作しません。

## 認証情報の扱い

署名情報はテスト完了後のステップでだけ読み込み、GitHubの一時Macに専用キーチェーンを作成します。処理終了時は成功・失敗を問わず削除します。Secretsを利用できる`main`への変更は、署名・公開の権限を持つ変更としてレビューしてください。

自動検証はインストール先のMacでの動作確認を代替しません。対応OSでのインストール・起動・解析は、配布前後の実機確認として引き続き行ってください。
