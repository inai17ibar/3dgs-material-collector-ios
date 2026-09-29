# 3DGS Material Collector

3D Gaussian Splatting (3DGS) 用の写真・動画素材を撮影する iOS の撮影補助アプリです。
ARKit でカメラの位置を追跡し、被写体の周りのどの位置から撮れたかを AR マーカーと
カバー率で表示しながら、写真の自動シャッターまたは動画撮影を行います。撮影したデータは
Mac アプリ [3DGS Composer](https://github.com/inai17ibar/3dgs-composer) でそのまま 3DGS にできます。

## 機能

- **撮影プラン**: 被写体の大きさ（小物 / 人物・家具 / 空間）と撮影方法（写真 / 動画）から、
  撮影位置の数・必要な枚数・動画の秒数・被写体との距離の目安を表示
- **AR ガイド**: 被写体の中心を設定すると、周囲に撮影位置（高さ別のリング）の球を表示。
  撮影済みの位置は緑になります
- **リアルタイムの指示**: 「右へ回り込んでください（あと約 30°）」「カメラを高くして…」
  「少し離れてください」などを表示。動きが速すぎるとき・トラッキングが不安定なときは警告
- **カバー率マップ**: 真上から見た撮影位置のマップ（自分の位置が常に下）とカバー率 %
- **写真モード**: 視点が一定角度以上変わり、カメラが止まっている瞬間に自動撮影（手動も可）。
  対応端末では高解像度フレームを保存
- **動画モード**: ARKit のカメラ映像を H.264 で録画し、経過秒数と目安の秒数を表示
- **露出・ホワイトバランス固定**: 撮影中の明るさの変化を防止
- **書き出し**: 撮影ごとのフォルダを「ファイル」アプリに保存し、ZIP にして AirDrop などで共有

## 出力フォルダ

```text
Captures/20260928-101500-small/
  images/frame_00001.jpg …  写真（センサーの向きのまま・横長）
  video.mov                 動画（動画モード）
  manifest.json             撮影条件・各写真の ARKit カメラ姿勢と内部パラメータ
  transforms.json           Nerfstudio 形式のカメラ姿勢（写真モード）
  sparse/0/*.txt            COLMAP テキスト形式のカメラ姿勢（写真モード、3D 点なし）
```

Mac の 3DGS Composer では「写真を選択」で `images` フォルダを、「動画を選択」で `video.mov` を選びます。
`sparse/0` は ARKit の姿勢を COLMAP の座標系（x 右・y 下・z 前、world→camera）に変換したもので、
`colmap point_triangulator` の入力として使えます。

## 必要環境

- iOS 17 以降、ARKit のワールドトラッキング対応の iPhone（A12 以降）
- Xcode 16 以降、[XcodeGen](https://github.com/yonaskolb/XcodeGen)

## ビルド

```sh
brew install xcodegen
xcodegen generate
open MaterialCollector.xcodeproj
```

Signing & Capabilities で自分のチームを選び、実機で実行してください（ARKit はシミュレータでは動作しません）。

撮影位置の計算や姿勢の変換は Swift Package の `CaptureKit` にあり、Linux でもテストできます。

```sh
swift test
```

## 構成

```text
Sources/CaptureKit/          プラットフォーム非依存のロジック
  CoverageMap.swift          撮影位置のリング・カバー率・次の指示
  CaptureTrigger.swift       移動速度の推定と自動シャッター判定
  CapturePlan.swift          被写体ごとの撮影プランと目安
  CaptureManifest.swift      manifest.json / COLMAP / transforms.json 書き出し
Sources/MaterialCollector/   iOS アプリ（SwiftUI + ARKit + RealityKit）
Tests/CaptureKitTests/       CaptureKit の単体テスト
```
