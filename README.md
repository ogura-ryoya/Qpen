# Qpen

Windows のエクスプローラーで選んだファイルを、**Ctrl+Q** でまとめて開くツール。

- PDF と Excel など、種類の違うファイルを混ぜて選んでも開ける
- Ctrl+Q が効くのはエクスプローラーが前面にあるときだけ（デスクトップでは効かない）。ほかのアプリには影響しない
- タスクトレイに常駐し、サインイン時に自動で起動する（トレイのメニューで切れる）

## インストール

1. **[Qpen-setup.cmd](https://github.com/ogura-ryoya/Qpen/releases/latest/download/Qpen-setup.cmd)** をダウンロードする（最新の版のインストーラー）
2. ダウンロードした **Qpen-setup.cmd** をダブルクリックする（ダウンロードのフォルダなど、どこに置いたままでもよい）

「Qpen をインストールした」と通知が出れば完了。Qpen は `%LOCALAPPDATA%\Qpen` に入るので、Qpen-setup.cmd はインストール後に消してよい。インストールのログは `%TEMP%\Qpen-setup.log` と `%LOCALAPPDATA%\Qpen\log.txt` に残る。

- ブラウザが「危険なファイルかもしれない」などと止めたら、**保存** を選ぶ（ダウンロードの一覧の **…** から選ぶこともある）
- 「開いているファイル - セキュリティの警告」（発行元を確認できませんでした）が出たら **実行** を押す。「Windows によって PC が保護されました」と出たら、**詳細情報** を押してから **実行**
- 2 分たっても何も出ないときは、ウイルス対策ソフトに止められているかもしれない。そのときは [最新のリリース](https://github.com/ogura-ryoya/Qpen/releases/latest) の **Source code (zip)** をダウンロードして展開し、展開したフォルダで次のコマンドを PowerShell から動かしても入れられる。それでも入らないときは [Issues](https://github.com/ogura-ryoya/Qpen/issues) で知らせてほしい

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

## 使い方

エクスプローラーでファイルを選んで **Ctrl+Q** を押すと、それぞれ既定のアプリで開く。フォルダは開かない。16 個以上のときは、開く前に確かめる。ほかのアプリが Ctrl+Q を使っていて効かないときは、そう知らせる。

トレイの青い「Q」を右クリックすると、次のことができる。

- バージョンの確認
- **更新履歴を見る**：これまでの版で何が変わったかを GitHub で見る
- **更新を確認**：新しい版があれば、すぐに更新する
- **ログをコピー**：うまく動かないときは、これを押してから開発者に貼り付けて送る（トレイにアイコンが出ないときは `%LOCALAPPDATA%\Qpen\log.txt` を送る）
- **サインイン時に起動**：チェックを外すと、次のサインインから自動では起動しない（もう一度押すと元に戻る）
- **終了**：止める。スタートメニューの「Qpen」からまた起動できる
- **アンインストール**：確認のあと、Qpen のファイル・ショートカット・ログをすべて消す（消せなかったものがあれば、画面に出す）

## 更新

起動時と、動いている間は1日ごとに新しい版を確かめ、あれば自動で更新する。更新の内容は [Releases](https://github.com/ogura-ryoya/Qpen/releases) で見られる。

## 動作環境

Windows 10 / 11（追加のインストールは要らない）。会社の PC などで PowerShell スクリプトの実行が禁止されていると動かない。

## 開発者向け

`Qpen.ps1` の `$Version` を上げて main にプッシュすると、GitHub Actions がテスト（`tests/run.ps1`）を動かし、インストーラーを作ってリリースに付ける。インストーラー `Qpen-setup.cmd` は `.github/scripts/build-setup.ps1` が `setup.ps1`・`install.ps1`・`Qpen.ps1` を埋め込んで作る。リリースノートは前のリリースからのコミットメッセージで作られる（CLAUDE.md・tests・.github だけを変えたコミットは載らない）。

## ライセンス

[MIT](LICENSE)
